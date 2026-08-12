#!/usr/bin/env bash
# T0 smoke: harness is alive if eval-runner completed a headless turn.
# Passes under the prose-only mock (no tool calls required).
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
LOG="${WORK}/.agentos-eval.log"

if [[ ! -f "$LOG" ]]; then
  echo "FAIL: missing eval log at $LOG"
  exit 1
fi

# eval-runner emits this on LoopEvent.finished (stdout+stderr both in log).
if ! grep -q '\[eval-runner\] finished:' "$LOG"; then
  echo "FAIL: no [eval-runner] finished: line in log"
  tail -30 "$LOG" 2>/dev/null || true
  exit 1
fi

# Hard failure of the runner itself (bad args, crash) — not iteration-cap.
if grep -q 'eval-runner error:' "$LOG"; then
  echo "FAIL: eval-runner reported an error"
  grep 'eval-runner error:' "$LOG" | head -5
  exit 1
fi

echo "PASS"
exit 0
