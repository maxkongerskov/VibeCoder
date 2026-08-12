#!/usr/bin/env python3
"""Responds to MCP initialize, then ignores later requests (timeout tests)."""
import json
import sys

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    req_id = req.get("id")
    method = req.get("method")

    if method == "initialize" and req_id is not None:
        resp = {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"protocolVersion": "2024-11-05", "capabilities": {}},
        }
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()