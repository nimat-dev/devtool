#!/usr/bin/env python3
"""Minimal fake Kubernetes API server for tests/e2e-import.sh.

usage: fake_apiserver.py PORT CERT KEY

Answers just enough over TLS for `kubectl get --raw /version`, kubectx and kubens.
"""
import http.server
import json
import ssl
import sys

NAMESPACES = ("default", "kube-public", "kube-system")


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/version":
            self._send(200, {"major": "1", "minor": "31", "gitVersion": "v1.31.4-fake",
                             "platform": "linux/amd64"})
        elif path == "/api/v1/namespaces":
            self._send(200, {"kind": "NamespaceList", "apiVersion": "v1", "metadata": {},
                             "items": [{"metadata": {"name": n}} for n in NAMESPACES]})
        elif path.startswith("/api/v1/namespaces/"):
            self._send(200, {"kind": "Namespace", "apiVersion": "v1",
                             "metadata": {"name": path.rsplit("/", 1)[1]}})
        else:
            self._send(404, {"kind": "Status", "apiVersion": "v1", "status": "Failure",
                             "code": 404})

    def log_message(self, *args):  # keep the test output quiet
        pass


def main():
    port, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
