#!/usr/bin/env python3
"""A tiny HTTP proxy that only understands CONNECT, for tests/test-ca.sh.

    fake_connect_proxy.py PORT LOGFILE

Every request is logged as one line in LOGFILE: "CONNECT host:port", followed by " auth" when the
request carried a Proxy-Authorization header. Then the tunnel to host:port is made, like a real
proxy does for HTTPS. (A TLS-inspecting proxy would also open the tunnel and sign what is inside it
again; that part is the test's own server.) The port is bound before the first line is printed,
so a test can wait for "ready".
"""
import select
import socket
import socketserver
import sys

LOG = sys.argv[2]


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            data += chunk
        head = data.split(b"\r\n\r\n", 1)[0].decode("latin-1")
        lines = head.split("\r\n")
        parts = lines[0].split()
        if len(parts) < 2 or parts[0] != "CONNECT":
            self.request.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            return
        auth = any(line.lower().startswith("proxy-authorization:") for line in lines[1:])
        with open(LOG, "a", encoding="utf-8") as log:
            log.write("CONNECT " + parts[1] + (" auth" if auth else "") + "\n")
        host, _, port = parts[1].rpartition(":")
        try:
            upstream = socket.create_connection((host.strip("[]"), int(port)), timeout=10)
        except OSError:
            self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return
        self.request.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        sockets = [self.request, upstream]
        try:
            while True:
                readable, _, _ = select.select(sockets, [], [], 30)
                if not readable:
                    return
                for sock in readable:
                    buf = sock.recv(65536)
                    if not buf:
                        return
                    (upstream if sock is self.request else self.request).sendall(buf)
        finally:
            upstream.close()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(("127.0.0.1", int(sys.argv[1])), Handler) as server:
    print("ready", flush=True)
    server.serve_forever()
