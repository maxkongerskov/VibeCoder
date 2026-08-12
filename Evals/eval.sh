#!/usr/bin/env bash
# VibeCoder / AgentOS eval harness — runs each task/, scores it, writes results JSON.
#
# Usage:
#   ./Evals/eval.sh [--model <id>] [--backend lmstudio|llama|mock|exo|ollama|custom] [--filter NNN]
#   ./Evals/eval.sh --strict --filter 000 --backend mock --model mock-worker --port 1234
#   ./Evals/eval.sh --baseline Evals/baseline.json --filter 000 ...
#   ./Evals/eval.sh --write-baseline Evals/baseline.json --filter 000 ...
#
# Ratchet flags (Wave B S7):
#   --strict              exit 1 if any task fails (or no tasks ran)
#   --baseline PATH       compare results to baseline.json; exit 1 on regression
#   --write-baseline PATH write a new baseline from this run (does not compare)
#
# Mock smoke (T0):
#   python3 Evals/support/scripted_mock_server.py --port 1234 --model-id mock-worker &
#   ./Evals/eval.sh --backend mock --model mock-worker --port 1234 --filter 000 --max-iter 5 --strict
#
# Each task in tasks/ must have:
#   prompt.txt  — the user message handed to eval-runner
#   oracle.sh   — exits 0 if the produced workdir satisfies the task, non-zero if not
#   seed/       — directory copied into the workdir before the run (may be empty)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVAL_ROOT="$ROOT/Evals"
TASK_ROOT="$EVAL_ROOT/tasks"
RESULTS_ROOT="$EVAL_ROOT/results"
COMPARE_PY="$EVAL_ROOT/support/compare_baseline.py"
# Headless product (replaces removed agentos CLI). Override with --bin or EVAL_RUNNER_BIN.
EVAL_RUNNER_BIN="${EVAL_RUNNER_BIN:-$ROOT/.build/release/eval-runner}"
# Back-compat alias for scripts that still export AGENTOS_BIN.
if [[ -n "${AGENTOS_BIN:-}" ]]; then
  EVAL_RUNNER_BIN="$AGENTOS_BIN"
fi

# --- args ---
BACKEND="llama"
MODEL=""
ORCH_BACKEND=""
ORCH_MODEL=""
ORCH_PORT=""
WORKER_PORT=""
FILTER=""
FILTER_EXACT=0
MAX_ITER=40
XCODE_MCP=0
STRICT=0
BASELINE_PATH=""
WRITE_BASELINE_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend) BACKEND="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --orchestrator-backend) ORCH_BACKEND="$2"; shift 2 ;;
    --orchestrator-model)   ORCH_MODEL="$2"; shift 2 ;;
    --orchestrator-port)    ORCH_PORT="$2"; shift 2 ;;
    --worker-port|--port)   WORKER_PORT="$2"; shift 2 ;;
    --filter)  FILTER="$2"; shift 2 ;;
    --filter-exact) FILTER_EXACT=1; shift ;;
    --max-iter) MAX_ITER="$2"; shift 2 ;;
    --bin)     EVAL_RUNNER_BIN="$2"; shift 2 ;;
    --xcode-mcp) XCODE_MCP=1; shift ;;
    --strict)  STRICT=1; shift ;;
    --baseline) BASELINE_PATH="$2"; shift 2 ;;
    --write-baseline) WRITE_BASELINE_PATH="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Task filter match (Wave C2):
#  - exact: name == filter
#  - default: name == filter OR name starts with "filter-" (numeric prefix safe)
#    OR (len(filter) >= 3 AND substring match) for names like xcode-mcp
#  - --filter-exact: only name == filter
task_matches_filter() {
  local name="$1"
  local f="$2"
  [[ -z "$f" ]] && return 0
  if [[ $FILTER_EXACT -eq 1 ]]; then
    [[ "$name" == "$f" ]] && return 0
    return 1
  fi
  [[ "$name" == "$f" ]] && return 0
  [[ "$name" == "$f"-* ]] && return 0
  if [[ ${#f} -ge 3 && "$name" == *"$f"* ]]; then
    return 0
  fi
  return 1
}

if [[ $XCODE_MCP -eq 1 && -z "$FILTER" ]]; then
  FILTER="xcode-mcp"
fi

if [[ ! -x "$EVAL_RUNNER_BIN" ]]; then
  echo "eval-runner not found at $EVAL_RUNNER_BIN" >&2
  echo "building: swift build -c release --product eval-runner" >&2
  if ! (cd "$ROOT" && swift build -c release --product eval-runner); then
    echo "build failed" >&2
    exit 1
  fi
  EVAL_RUNNER_BIN="$ROOT/.build/release/eval-runner"
fi
if [[ ! -x "$EVAL_RUNNER_BIN" ]]; then
  echo "eval-runner binary missing after build: $EVAL_RUNNER_BIN" >&2
  exit 1
fi

mkdir -p "$RESULTS_ROOT"
STAMP="$(date +%Y-%m-%d-%H%M%S)"
SAFE_MODEL="$(echo "${MODEL:-default}" | tr '/:' '__')"
OUT="$RESULTS_ROOT/$STAMP-$BACKEND-$SAFE_MODEL.json"

# --- collect tasks ---
# Under `set -u`, an empty bash array is unbound when expanded as "${TASKS[@]}".
# Always keep at least a defined array; use length checks before iterating.
TASKS=()
shopt -s nullglob
for d in "$TASK_ROOT"/*/; do
  name="$(basename "$d")"
  if [[ -n "$FILTER" ]] && ! task_matches_filter "$name" "$FILTER"; then continue; fi
  if [[ $XCODE_MCP -eq 0 && "$name" == *"xcode-mcp"* ]]; then continue; fi
  TASKS+=("$name")
done
shopt -u nullglob

PASS=0
FAIL=0
SKIP=0
echo "[" > "$OUT"
FIRST=1

if [[ ${#TASKS[@]} -eq 0 ]]; then
  echo "warning: no tasks matched filter='${FILTER}' under $TASK_ROOT" >&2
fi

for task in ${TASKS[@]+"${TASKS[@]}"}; do
  TDIR="$TASK_ROOT/$task"
  PROMPT_FILE="$TDIR/prompt.txt"
  ORACLE="$TDIR/oracle.sh"
  if [[ ! -f "$PROMPT_FILE" || ! -x "$ORACLE" ]]; then
    echo "[$task] skip — missing prompt.txt or executable oracle.sh"
    SKIP=$((SKIP + 1))
    continue
  fi
  PROMPT="$(cat "$PROMPT_FILE")"
  WORKDIR="$(mktemp -d -t "agentos-eval-$task-XXXX")"
  if [[ -d "$TDIR/seed" ]]; then
    # copy seed contents (including hidden files) into workdir — fail loud
    # pipefail so a failed source tar is not masked by a successful empty extract
    if ! bash -c 'set -euo pipefail; (cd "$1" && tar cf - .) | (cd "$2" && tar xf -)' _ "$TDIR/seed" "$WORKDIR"; then
      echo "[$task] FAIL: seed/ copy into workdir failed" >&2
      STATUS="fail"; FAIL=$((FAIL + 1))
      if [[ $FIRST -eq 0 ]]; then echo "," >> "$OUT"; fi
      FIRST=0
      cat >> "$OUT" <<EOF
  {
    "task": "$task",
    "status": "fail",
    "duration_s": 0,
    "tool_calls": 0,
    "run_exit_code": 2,
    "workdir": "$WORKDIR",
    "error": "seed_copy_failed"
  }
EOF
      continue
    fi
  fi

  LOG="$WORKDIR/.agentos-eval.log"
  echo "[$task] running …"
  START=$(date +%s)

  RUN_ARGS=(run "$PROMPT" --backend "$BACKEND" --project "$WORKDIR" --max-iterations "$MAX_ITER")
  if [[ -n "$MODEL" ]]; then RUN_ARGS+=(--model "$MODEL"); fi
  if [[ -n "$ORCH_BACKEND" ]]; then RUN_ARGS+=(--orchestrator-backend "$ORCH_BACKEND"); fi
  if [[ -n "$ORCH_MODEL" ]]; then RUN_ARGS+=(--orchestrator-model "$ORCH_MODEL"); fi
  if [[ -n "$ORCH_PORT" ]]; then RUN_ARGS+=(--orchestrator-port "$ORCH_PORT"); fi
  if [[ -n "$WORKER_PORT" ]]; then RUN_ARGS+=(--port "$WORKER_PORT"); fi
  if [[ $XCODE_MCP -eq 1 ]]; then RUN_ARGS+=(--xcode-mcp); fi

  if "$EVAL_RUNNER_BIN" "${RUN_ARGS[@]}" > "$LOG" 2>&1
  then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
  END=$(date +%s)
  DUR=$((END - START))

  # Oracle decides pass/fail. RUN_RC is informational — a run that hit
  # the iteration cap can still pass if the artifact is correct.
  if "$ORACLE" "$WORKDIR" > "$WORKDIR/.oracle.log" 2>&1; then
    STATUS="pass"; PASS=$((PASS + 1))
  else
    STATUS="fail"; FAIL=$((FAIL + 1))
  fi

  # grep -c prints "0" on no match but exits 1; `|| echo 0` then yields
  # "0\n0" and corrupts JSON. Force a single integer.
  TOOL_CALLS=$(grep -c '^\[[✓✗] ' "$LOG" 2>/dev/null || true)
  TOOL_CALLS=${TOOL_CALLS:-0}

  echo "[$task] $STATUS  (${DUR}s, $TOOL_CALLS tool calls, workdir: $WORKDIR)"

  if [[ $FIRST -eq 0 ]]; then echo "," >> "$OUT"; fi
  FIRST=0
  cat >> "$OUT" <<EOF
  {
    "task": "$task",
    "status": "$STATUS",
    "duration_s": $DUR,
    "tool_calls": $TOOL_CALLS,
    "run_exit_code": $RUN_RC,
    "workdir": "$WORKDIR"
  }
EOF
done

echo "]" >> "$OUT"

TOTAL=$((PASS + FAIL))
echo ""
echo "=========================================="
echo " pass: $PASS / $TOTAL"
echo " fail: $FAIL"
echo " skip: $SKIP"
echo " results: $OUT"
echo "=========================================="

# --- ratchet / exit codes (Wave B S7) ---
EXIT_CODE=0

if [[ ! -f "$COMPARE_PY" ]]; then
  echo "warning: compare_baseline.py missing at $COMPARE_PY" >&2
  if [[ $STRICT -eq 1 && ( $FAIL -gt 0 || $TOTAL -eq 0 ) ]]; then
    echo "strict: fail=$FAIL total=$TOTAL (compare_baseline missing)" >&2
    exit 1
  fi
  if [[ -n "$BASELINE_PATH" && $TOTAL -eq 0 ]]; then
    echo "baseline: no tasks ran" >&2
    exit 1
  fi
  exit 0
fi

COMPARE_ARGS=(python3 "$COMPARE_PY" "$OUT" --backend "$BACKEND" --model "${MODEL:-default}")

if [[ -n "$WRITE_BASELINE_PATH" ]]; then
  if ! "${COMPARE_ARGS[@]}" --write-baseline "$WRITE_BASELINE_PATH" --require-all-pass; then
    echo "failed to write baseline" >&2
    exit 2
  fi
fi

if [[ $STRICT -eq 1 || -n "$BASELINE_PATH" ]]; then
  RATCHET_ARGS=("${COMPARE_ARGS[@]}")
  if [[ $STRICT -eq 1 ]]; then
    RATCHET_ARGS+=(--strict)
  fi
  if [[ -n "$BASELINE_PATH" ]]; then
    RATCHET_ARGS+=(--baseline "$BASELINE_PATH")
  fi
  if ! "${RATCHET_ARGS[@]}"; then
    EXIT_CODE=1
  fi
fi

exit "$EXIT_CODE"
