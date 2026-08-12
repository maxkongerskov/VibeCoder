#!/usr/bin/env python3
"""Fake llama-server for bootstrap/spawn verification."""
from __future__ import annotations

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def parse_port(argv: list[str]) -> int:
    for i, arg in enumerate(argv):
        if arg == "--port" and i + 1 < len(argv):
            return int(argv[i + 1])
    return 8765


class Handler(BaseHTTPRequestHandler):
    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_sse(self, chunks: list[str]) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(f"data: {chunk}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")

    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/health"):
            self._json(200, {"status": "ok"})
            return
        if "/models" in self.path:
            self._json(200, {"data": [{"id": "fake-llama-model"}]})
            return
        self._json(200, {"ok": True})

    def do_POST(self) -> None:  # noqa: N802
        if not self.path.endswith("/chat/completions"):
            self._json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(length)
        chunk = json.dumps({
            "choices": [{
                "delta": {"content": "hi"},
                "finish_reason": None,
            }]
        })
        done = json.dumps({
            "choices": [{"delta": {}, "finish_reason": "stop"}]
        })
        self._send_sse([chunk, done])

    def log_message(self, *args) -> None:
        pass


def main() -> None:
    port = parse_port(sys.argv)
    server = HTTPServer(("127.0.0.1", port), Handler)
    sys.stderr.write(f"[fake-llama-server] ready on :{port}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()