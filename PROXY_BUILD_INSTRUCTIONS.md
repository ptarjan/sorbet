# Building Bazel Projects with Authenticated Proxy

This document explains how to build Bazel projects when behind an authenticated HTTP proxy, without using a distdir.

## Problem

Bazel's Java HTTP downloader does not properly handle authenticated proxies. Even when `HTTPS_PROXY` is set with credentials in the URL format (`http://user:pass@host:port`), Bazel fails with "401 Unauthorized" or "407 Proxy Authentication Required" errors.

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

## Files

- `.proxy-agent/auth_proxy.py` - Python forwarding proxy that handles authentication
- `.bazelrc.local.example` - Example Bazel configuration
- `tools/proxy-bazel` - Wrapper script that automates the proxy setup

## Sources

- [Bazel Issue #14675: Authenticated HTTPS proxy config](https://github.com/bazelbuild/bazel/issues/14675)
- [Bazel Issue #601: Work behind a proxy](https://github.com/bazelbuild/bazel/issues/601)
- [Java 8u111 Basic auth changes](https://support.atlassian.com/atlassian-knowledge-base/kb/basic-authentication-fails-for-outgoing-proxy-in-java-8u111/)
