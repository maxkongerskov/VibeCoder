#!/usr/bin/env python3
"""Scripted OpenAI-compat mock for deterministic T0/T4 evals.

Unlike mock_openai_server.py (static prose plan), this server plays a FIFO
list of scripted turns. Each turn is either:
  - {"type": "text", "content": "..."}
  - {"type": "tool_calls", "calls": [{"id": "c1", "name": "write_file", "arguments": {...}}]}

After the script is exhausted, further requests return a short "done" text stop.

Default script (built-in for T0): single prose turn — enough for 000-harness-alive.

Usage:
  python3 Evals/support/scripted_mock_server.py --port 1234 --model-id mock-worker
  python3 Evals/support/scripted_mock_server.py --port 1234 --script path.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

DEFAULT_MODEL_ID = os.environ.get("MOCK_MODEL_ID", "mock-worker")

# Built-in T0 script: one assistant prose completion, no tools.
DEFAULT_SCRIPT: list[dict[str, Any]] = [
    {"type": "text", "content": "Received. Harness smoke OK."},
]


class ScriptState:
    def __init__(self, turns: list[dict[str, Any]], model_id: str) -> None:
        self._lock = threading.Lock()
        self._turns = list(turns)
        self._index = 0
        self.model_id = model_id
        self.request_count = 0

    def next_turn(self) -> dict[str, Any]:
        with self._lock:
            self.request_count += 1
            if self._index < len(self._turns):
                turn = self._turns[self._index]
                self._index += 1
                return turn
            return {"type": "text", "content": "Script exhausted; stopping."}


STATE: ScriptState | None = None


def _sse_text(content: str) -> list[str]:
    chunk = json.dumps({
        "choices": [{
            "index": 0,
            "delta": {"role": "assistant", "content": content},
            "finish_reason": None,
        }]
    })
    done = json.dumps({
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]
    })
    return [chunk, done]


def _sse_tool_calls(calls: list[dict[str, Any]]) -> list[str]:
    """Emit OpenAI-style streaming tool_calls then finish_reason tool_calls."""
    chunks: list[str] = []
    # Role preamble
    chunks.append(json.dumps({
        "choices": [{
            "index": 0,
            "delta": {"role": "assistant", "content": None},
            "finish_reason": None,
        }]
    }))
    for i, call in enumerate(calls):
        cid = call.get("id") or f"call_{i}"
        name = call.get("name") or "unknown"
        args = call.get("arguments", {})
        if isinstance(args, dict):
            args_s = json.dumps(args)
        else:
            args_s = str(args)
        # Name first
        chunks.append(json.dumps({
            "choices": [{
                "index": 0,
                "delta": {
                    "tool_calls": [{
                        "index": i,
                        "id": cid,
                        "type": "function",
                        "function": {"name": name, "arguments": ""},
                    }]
                },
                "finish_reason": None,
            }]
        }))
        # Args
        chunks.append(json.dumps({
            "choices": [{
                "index": 0,
                "delta": {
                    "tool_calls": [{
                        "index": i,
                        "function": {"arguments": args_s},
                    }]
                },
                "finish_reason": None,
            }]
        }))
    chunks.append(json.dumps({
        "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]
    }))
    return chunks


class Handler(BaseHTTPRequestHandler):
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
        assert STATE is not None
        if self.path.startswith("/health"):
            self._send_json(200, {
                "status": "ok",
                "requests": STATE.request_count,
            })
            return
        if self.path.startswith("/api/v0/models") or "/models" in self.path:
            self._send_json(200, {
                "object": "list",
                "data": [{"id": STATE.model_id, "object": "model", "state": "loaded"}],
            })
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        assert STATE is not None
        if not self.path.endswith("/chat/completions"):
            self._send_json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(length)
        turn = STATE.next_turn()
        if turn.get("type") == "tool_calls":
            calls = turn.get("calls") or []
            self._send_sse(_sse_tool_calls(list(calls)))
        else:
            content = str(turn.get("content") or "")
            self._send_sse(_sse_text(content))

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(f"[scripted-mock] {self.address_string()} {fmt % args}\n")


def load_script(path: Path | None) -> list[dict[str, Any]]:
    if path is None:
        return list(DEFAULT_SCRIPT)
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, dict) and "turns" in data:
        turns = data["turns"]
    else:
        turns = data
    if not isinstance(turns, list):
        raise SystemExit("script must be a list or {\"turns\": [...]}")
    return turns


def main() -> None:
    global STATE
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=1234)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID)
    parser.add_argument("--script", type=Path, default=None,
                        help="JSON file of turns (or {\"turns\": [...]})")
    args = parser.parse_args()
    turns = load_script(args.script)
    STATE = ScriptState(turns, args.model_id)
    server = HTTPServer((args.host, args.port), Handler)
    sys.stderr.write(
        f"[scripted-mock] listening on http://{args.host}:{args.port} "
        f"turns={len(turns)} model={args.model_id}\n"
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
