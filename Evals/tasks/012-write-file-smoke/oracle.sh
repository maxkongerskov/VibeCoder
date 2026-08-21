#!/usr/bin/env bash
# A1 smoke: scripted mock must have executed write_file so hello.txt exists.
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
FILE="$WORK/hello.txt"
LOG="$WORK/.agentos-eval.log"

if [[ ! -f "$FILE" ]]; then
  echo "FAIL: hello.txt missing (write_file did not run or was denied)"
  tail -40 "$LOG" 2>/dev/null || true
  exit 1
fi
if ! grep -q 'A1-proof' "$FILE"; then
  echo "FAIL: hello.txt does not contain A1-proof"
  cat "$FILE"
  exit 1
fi
if [[ -f "$LOG" ]] && ! grep -q 'write_file' "$LOG"; then
  echo "FAIL: eval log has no write_file marker"
  exit 1
fi
echo "PASS"
exit 0
