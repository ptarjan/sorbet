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
