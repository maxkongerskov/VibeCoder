#!/usr/bin/env bash
# A2 smoke: scripted mock must apply_patch so hello.swift changes in place.
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
FILE="$WORK/hello.swift"
LOG="$WORK/.agentos-eval.log"

if [[ ! -f "$FILE" ]]; then
  echo "FAIL: hello.swift missing"
  tail -40 "$LOG" 2>/dev/null || true
  exit 1
fi
if ! grep -q 'print("hello, world")' "$FILE"; then
  echo "FAIL: hello.swift was not patched to hello, world"
  cat "$FILE"
  exit 1
fi
if grep -q 'print("hello")' "$FILE"; then
  echo "FAIL: original print(\"hello\") still present (apply_patch did not replace)"
  cat "$FILE"
  exit 1
fi
if [[ -f "$LOG" ]] && ! grep -q 'apply_patch' "$LOG"; then
  echo "FAIL: eval log has no apply_patch marker"
  exit 1
fi
echo "PASS"
exit 0
