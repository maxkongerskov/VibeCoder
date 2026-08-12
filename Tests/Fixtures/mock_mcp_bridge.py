#!/usr/bin/env python3
"""Minimal MCP stdio bridge for unit tests — responds to initialize + tools/list."""
import json
import sys

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    req_id = req.get("id")
    method = req.get("method")

    if method == "initialize":
        resp = {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"protocolVersion": "2024-11-05", "capabilities": {}},
        }
    elif method == "tools/list":
        resp = {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": []},
        }
    elif method == "tools/call" and req.get("params", {}).get("name") == "XcodeListWindows":
        resp = {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "structuredContent": {
                    "message": "* tabIdentifier: windowtab1, workspacePath: /tmp/Test.xcodeproj"
                }
            },
        }
    elif req_id is not None:
        resp = {"jsonrpc": "2.0", "id": req_id, "result": {}}
    else:
        continue

    sys.stdout.write(json.dumps(resp) + "\n")
    sys.stdout.flush()