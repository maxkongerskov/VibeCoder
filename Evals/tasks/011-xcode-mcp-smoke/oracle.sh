#!/usr/bin/env bash
# Oracle for 011-xcode-mcp-smoke.
# Pass if the agent log shows the expected Xcode MCP tool chain.
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
LOG="$WORK/.agentos-eval.log"

if [[ ! -f "$LOG" ]]; then
  echo "FAIL: missing eval log at $LOG"
  exit 1
fi

for tool in XcodeListWindows XcodeRead BuildProject; do
  if ! grep -q "$tool" "$LOG"; then
    echo "FAIL: log never shows MCP tool $tool"
    exit 1
  fi
done

if grep -q 'xcode_build' "$LOG"; then
  echo "FAIL: agent used superseded builtin xcode_build"
  exit 1
fi

if grep -qE '\[✗ BuildProject\]' "$LOG"; then
  echo "FAIL: BuildProject returned an error"
  exit 1
fi

echo "PASS"
exit 0