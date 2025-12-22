# Building Bazel Projects with Authenticated Proxy

This document explains how to build Bazel projects when behind an authenticated HTTP proxy, without using a distdir.

## Problem

Bazel's Java HTTP downloader does not properly handle authenticated proxies. Even when `HTTPS_PROXY` is set with credentials in the URL format (`http://user:pass@host:port`), Bazel fails with "401 Unauthorized" or "407 Proxy Authentication Required" errors.

**Root Cause:** Java 8u111+ disabled Basic authentication for HTTPS tunneling by default (`jdk.http.auth.tunneling.disabledSchemes=Basic`), and Bazel's HTTP client doesn't properly use `java.net.Authenticator` for proxy credentials.

## Solution

Use a local forwarding proxy that handles authentication to the upstream proxy. This approach:
1. Starts a Python-based proxy on `localhost:18888`
2. The local proxy adds `Proxy-Authorization` headers when forwarding to the upstream proxy
3. Bazel connects to the local proxy without authentication

## Quick Start

```bash
# 1. Copy the example config to .bazelrc.local
cp .bazelrc.local.example .bazelrc.local

# 2. Use the proxy wrapper script
./tools/proxy-bazel build //main:sorbet
```

## Manual Setup

### Step 1: Configure `.bazelrc.local`

Create `.bazelrc.local` with these settings:

```
# Enable proxy authentication for HTTPS tunneling
startup --host_jvm_args=-Djdk.http.auth.tunneling.disabledSchemes=
startup --host_jvm_args=-Djdk.http.auth.proxying.disabledSchemes=

# Use system CA certificates
startup --host_jvm_args=-Djavax.net.ssl.trustStoreType=JKS
startup --host_jvm_args=-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts
startup --host_jvm_args=-Djavax.net.ssl.trustStorePassword=changeit
```

### Step 2: Start the Auth Proxy

```bash
# Start the forwarding proxy
UPSTREAM_PROXY="$HTTPS_PROXY" python3 .proxy-agent/auth_proxy.py &
```

### Step 3: Run Bazel with Local Proxy

```bash
# Set environment to use local proxy
export HTTPS_PROXY=http://127.0.0.1:18888
export HTTP_PROXY=http://127.0.0.1:18888
export https_proxy=http://127.0.0.1:18888
export http_proxy=http://127.0.0.1:18888

# Run Bazel
./bazel build //main:sorbet
```

## Key JVM Properties Explained

| Property | Purpose |
|----------|---------|
| `jdk.http.auth.tunneling.disabledSchemes=` | Enables Basic auth for HTTPS tunneling (disabled by default since Java 8u111) |
| `jdk.http.auth.proxying.disabledSchemes=` | Enables Basic auth for HTTP proxy connections |
| `javax.net.ssl.trustStore` | Points to the Java keystore with CA certificates |
| `javax.net.ssl.trustStorePassword` | Password for the keystore (default: "changeit") |

## Troubleshooting

### "401 Unauthorized" or "407 Proxy Authentication Required"

- Ensure the auth proxy is running: `lsof -i :18888`
- Verify UPSTREAM_PROXY contains credentials: `echo $HTTPS_PROXY | grep @`
- Check proxy logs: `cat /tmp/proxy.log`

### "PKIX path building failed" (SSL Certificate Error)

- Verify cacerts exists: `ls -la /etc/ssl/certs/java/cacerts`
- If on macOS, use: `/Library/Java/JavaVirtualMachines/*/Contents/Home/lib/security/cacerts`

### Proxy Not Starting

- Check if port 18888 is in use: `lsof -i :18888`
- Kill existing proxy: `pkill -f auth_proxy.py`

---

## Source Code

### File: `.proxy-agent/auth_proxy.py`

```python
#!/usr/bin/env python3
"""HTTPS tunnel proxy that authenticates to upstream proxy."""
import socket
import threading
import base64
import os
import select
import sys

https_proxy = os.environ.get('UPSTREAM_PROXY', '')
if not https_proxy:
    print("UPSTREAM_PROXY not set", file=sys.stderr)
    sys.exit(1)

proxy_url = https_proxy
if proxy_url.startswith('http://'):
    proxy_url = proxy_url[7:]
elif proxy_url.startswith('https://'):
    proxy_url = proxy_url[8:]

user_pass_host = proxy_url.rsplit('@', 1)
if len(user_pass_host) == 2:
    user_pass = user_pass_host[0]
    host_port = user_pass_host[1]
    user, password = user_pass.split(':', 1)
else:
    host_port = user_pass_host[0]
    user, password = None, None

upstream_host, upstream_port = host_port.split(':')
upstream_port = int(upstream_port)

auth_string = f"{user}:{password}"
auth_b64 = base64.b64encode(auth_string.encode()).decode()

LOCAL_PORT = 18888

def read_http_headers(sock):
    data = b''
    while b'\r\n\r\n' not in data:
        chunk = sock.recv(4096)
        if not chunk:
            return None
        data += chunk
    return data

def forward_data(source, dest, stop_event):
    source.setblocking(False)
    try:
        while not stop_event.is_set():
            try:
                ready, _, _ = select.select([source], [], [], 0.5)
                if ready:
                    data = source.recv(32768)
                    if not data:
                        break
                    dest.sendall(data)
            except:
                break
    except:
        pass
    finally:
        stop_event.set()

def handle_client(client_sock, client_addr):
    upstream_sock = None
    try:
        request_data = read_http_headers(client_sock)
        if not request_data:
            return

        request_text = request_data.decode('utf-8', errors='ignore')
        lines = request_text.split('\r\n')
        request_line = lines[0]
        parts = request_line.split(' ')
        if len(parts) < 2:
            return

        method = parts[0].upper()
        target = parts[1]

        upstream_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        upstream_sock.settimeout(30)
        upstream_sock.connect((upstream_host, upstream_port))

        if method == 'CONNECT':
            upstream_request = f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nProxy-Authorization: Basic {auth_b64}\r\nProxy-Connection: Keep-Alive\r\n\r\n"
            upstream_sock.sendall(upstream_request.encode())
            upstream_response = read_http_headers(upstream_sock)
            if not upstream_response:
                client_sock.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                return

            response_text = upstream_response.decode('utf-8', errors='ignore')
            if '200' not in response_text.split('\r\n')[0]:
                client_sock.sendall(upstream_response)
                return

            client_sock.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")

            stop_event = threading.Event()
            t1 = threading.Thread(target=forward_data, args=(client_sock, upstream_sock, stop_event))
            t2 = threading.Thread(target=forward_data, args=(upstream_sock, client_sock, stop_event))
            t1.start()
            t2.start()
            t1.join()
            t2.join()
        else:
            new_request = f"{request_line}\r\nProxy-Authorization: Basic {auth_b64}\r\n"
            for line in lines[1:]:
                if not line.lower().startswith('proxy-authorization:'):
                    new_request += line + '\r\n'
            upstream_sock.sendall(new_request.encode())
            while True:
                data = upstream_sock.recv(32768)
                if not data:
                    break
                client_sock.sendall(data)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
    finally:
        try:
            if upstream_sock:
                upstream_sock.close()
        except:
            pass
        try:
            client_sock.close()
        except:
            pass

def main():
    print(f"Auth Tunnel: localhost:{LOCAL_PORT} -> {upstream_host}:{upstream_port}", file=sys.stderr)
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('127.0.0.1', LOCAL_PORT))
    server.listen(100)
    while True:
        try:
            client_sock, addr = server.accept()
            t = threading.Thread(target=handle_client, args=(client_sock, addr))
            t.daemon = True
            t.start()
        except KeyboardInterrupt:
            break

if __name__ == '__main__':
    main()
```

### File: `tools/proxy-bazel`

```bash
#!/bin/bash
#
# proxy-bazel
# ===========
# A wrapper script that runs Bazel with authenticated proxy support.
#
# This script:
# 1. Starts a local forwarding proxy that authenticates to the upstream proxy
# 2. Runs Bazel with the local proxy settings
# 3. Cleans up the proxy on exit
#
# Usage:
#   ./tools/proxy-bazel build //main:sorbet
#   ./tools/proxy-bazel test //...
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROXY_SCRIPT="$REPO_ROOT/.proxy-agent/auth_proxy.py"
PROXY_PORT=18888
PROXY_PID=""

# Get the upstream proxy URL from environment
UPSTREAM_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"

if [ -z "$UPSTREAM_PROXY" ]; then
    echo "No HTTPS_PROXY set, running bazel directly..." >&2
    exec "$REPO_ROOT/bazel" "$@"
fi

# Check if the proxy URL contains authentication credentials
if [[ "$UPSTREAM_PROXY" != *"@"* ]]; then
    echo "HTTPS_PROXY doesn't contain credentials, running bazel directly..." >&2
    exec "$REPO_ROOT/bazel" "$@"
fi

# Function to cleanup on exit
cleanup() {
    if [ -n "$PROXY_PID" ] && ps -p "$PROXY_PID" > /dev/null 2>&1; then
        kill "$PROXY_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Check if proxy is already running on the port
if lsof -i ":$PROXY_PORT" > /dev/null 2>&1; then
    echo "Auth proxy already running on port $PROXY_PORT" >&2
else
    # Start the auth proxy
    echo "Starting auth proxy on port $PROXY_PORT..." >&2
    UPSTREAM_PROXY="$UPSTREAM_PROXY" python3 "$PROXY_SCRIPT" &
    PROXY_PID=$!
    sleep 2

    if ! ps -p "$PROXY_PID" > /dev/null 2>&1; then
        echo "Failed to start auth proxy" >&2
        exit 1
    fi
fi

# Run bazel with the local proxy
export HTTPS_PROXY="http://127.0.0.1:$PROXY_PORT"
export HTTP_PROXY="http://127.0.0.1:$PROXY_PORT"
export https_proxy="http://127.0.0.1:$PROXY_PORT"
export http_proxy="http://127.0.0.1:$PROXY_PORT"

exec "$REPO_ROOT/bazel" "$@"
```

### File: `.bazelrc.local.example`

```
# Example .bazelrc.local for Proxy Configuration
# ===============================================
#
# Copy this file to .bazelrc.local and customize as needed.
#
# This configuration enables Bazel to work with authenticated proxies.
#
# To use:
# 1. Copy this file to .bazelrc.local
# 2. Start the auth proxy: UPSTREAM_PROXY="$HTTPS_PROXY" python3 .proxy-agent/auth_proxy.py &
# 3. Run bazel with local proxy: HTTPS_PROXY=http://127.0.0.1:18888 ./bazel build ...
#
# Or use the wrapper script: ./tools/proxy-bazel build ...

# Enable proxy authentication for HTTPS tunneling (critical for authenticated proxies)
# This allows Basic authentication through proxy tunnels, which Java disables by default
startup --host_jvm_args=-Djdk.http.auth.tunneling.disabledSchemes=
startup --host_jvm_args=-Djdk.http.auth.proxying.disabledSchemes=

# Use system CA certificates for SSL validation
# Adjust the path if your cacerts is in a different location
startup --host_jvm_args=-Djavax.net.ssl.trustStoreType=JKS
startup --host_jvm_args=-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts
startup --host_jvm_args=-Djavax.net.ssl.trustStorePassword=changeit
```

### File: `.proxy-agent/.gitignore`

```
# Ignore Java agent files (not used in final solution)
*.class
*.jar
*.java
MANIFEST.MF
```

---

## Sources

- [Bazel Issue #14675: Authenticated HTTPS proxy config](https://github.com/bazelbuild/bazel/issues/14675)
- [Bazel Issue #601: Work behind a proxy](https://github.com/bazelbuild/bazel/issues/601)
- [Java 8u111 Basic auth changes](https://support.atlassian.com/atlassian-knowledge-base/kb/basic-authentication-fails-for-outgoing-proxy-in-java-8u111/)
