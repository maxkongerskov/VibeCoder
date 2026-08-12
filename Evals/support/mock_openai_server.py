#!/usr/bin/env python3
"""Minimal OpenAI-compat mock for eval smoke tests.

Serves /v1/models, /api/v0/models, /health, and /v1/chat/completions (SSE).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

DEFAULT_MODEL_ID = os.environ.get("MOCK_MODEL_ID", "mock-orchestrator")


PLAN_TEXT = (
    "1. Read HelloWorld.swift\n"
    "2. Change the greeting string to Hello, AgentOS!\n"
    "3. Verify with `swift build`\n"
)


class Handler(BaseHTTPRequestHandler):
    model_id = DEFAULT_MODEL_ID
    def _send_json(self, code: int, payload: dict) -> None:
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
            self._send_json(200, {"status": "ok"})
            return
        if self.path.startswith("/api/v0/models"):
            self._send_json(200, {
                "data": [{"id": self.model_id, "state": "loaded"}]
            })
            return
        if "/models" in self.path:
            self._send_json(200, {
                "object": "list",
                "data": [{"id": self.model_id, "object": "model"}],
            })
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if not self.path.endswith("/chat/completions"):
            self._send_json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(length)
        chunk = json.dumps({
            "choices": [{
                "delta": {"content": PLAN_TEXT},
                "finish_reason": None,
            }]
        })
        done = json.dumps({
            "choices": [{"delta": {}, "finish_reason": "stop"}]
        })
        self._send_sse([chunk, done])

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(f"[mock-openai] {self.address_string()} {fmt % args}\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=1234)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID)
    args = parser.parse_args()
    Handler.model_id = args.model_id
    server = HTTPServer((args.host, args.port), Handler)
    sys.stderr.write(f"[mock-openai] listening on http://{args.host}:{args.port}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()