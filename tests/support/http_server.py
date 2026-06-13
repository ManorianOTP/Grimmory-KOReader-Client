#!/usr/bin/env python3
"""
Tiny HTTP fixture server for BookLore KOReader Client tests.
Takes a JSON routing spec via argv[1], binds 127.0.0.1:0,
prints PID on stdout line 1, port on line 2, then serves requests.
The Lua side reads PID + port and kills the process on stop().
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CANNED_DIR = os.path.join(os.path.dirname(__file__), "canned_responses")


def load_spec(spec_list):
    routes = []
    for entry in spec_list:
        # Lua dkjson encodes an empty table as [] rather than {}; coerce
        # to dict so handler header iteration is safe.
        headers = entry.get("headers", {})
        if not isinstance(headers, dict):
            headers = {}
        routes.append({
            "method":  entry.get("method", "GET").upper(),
            "path":    entry["path"],
            "status":  entry.get("status", 200),
            "headers": headers,
            "body":    _resolve_body(entry),
            "repeat":  entry.get("repeat_", entry.get("repeat", None)),
            "served":  0,
        })
    return routes


def _resolve_body(entry):
    if "body_file" in entry:
        # Relative paths resolve against the canned-responses dir; absolute
        # paths let specs serve fixtures they generate at test time (e.g. the
        # Tailscale install tarball built in the per-test tmp dir).
        path = entry["body_file"]
        if not os.path.isabs(path):
            path = os.path.join(CANNED_DIR, path)
        with open(path, "rb") as f:
            return f.read()
    body = entry.get("body", "")
    if isinstance(body, str):
        return body.encode()
    return body


class FixtureHandler(BaseHTTPRequestHandler):
    routes = []
    lock = threading.Lock()
    received = []

    def log_message(self, fmt, *args):
        pass

    def _match_route(self):
        with self.lock:
            for route in self.routes:
                if route["method"] == self.command and route["path"] == self.path.split("?")[0]:
                    if route["repeat"] is not None and route["served"] >= route["repeat"]:
                        continue
                    route["served"] += 1
                    return route
        return None

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length > 0:
            return self.rfile.read(length)
        return b""

    def do_GET(self):  self._handle()
    def do_POST(self): self._handle()
    def do_PUT(self):  self._handle()
    def do_DELETE(self): self._handle()

    def _handle(self):
        body = self._read_body()
        with self.lock:
            self.received.append({
                "method": self.command,
                "path": self.path.split("?")[0],
                "body": body,
            })
        route = self._match_route()
        if route is None:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"No matching route")
            return
        self.send_response(route["status"])
        body = route["body"]
        headers_lower = {k.lower() for k in route["headers"]}
        for k, v in route["headers"].items():
            self.send_header(k, v)
        if "content-length" not in headers_lower:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    spec_list = json.loads(sys.argv[1])
    routes = load_spec(spec_list)
    FixtureHandler.routes = routes
    FixtureHandler.received = []

    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    port = server.server_address[1]
    sys.stdout.write(str(os.getpid()) + "\n")
    sys.stdout.write(str(port) + "\n")
    sys.stdout.flush()

    server.serve_forever()


if __name__ == "__main__":
    main()
