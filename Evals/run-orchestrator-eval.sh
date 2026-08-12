#!/usr/bin/env bash
# Two-model orchestrator eval — worker-only baseline vs orchestrator+worker.
#
# Usage:
#   ./Evals/run-orchestrator-eval.sh worker-only [--filter 001] [--backend llama]
#   ./Evals/run-orchestrator-eval.sh orchestrator-worker \
#       [--orchestrator-backend lmstudio] [--orchestrator-model <id>] \
#       [--backend llama] [--model <id>] [--filter 001]
#
# orchestrator-worker starts mock OpenAI backends when real servers are absent.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVAL_SH="$ROOT/Evals/eval.sh"
MOCK_PY="$ROOT/Evals/support/mock_openai_server.py"
CONDITION="${1:-worker-only}"
shift || true

MOCK_PIDS=()
cleanup() {
  for pid in ${MOCK_PIDS[@]+"${MOCK_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

start_mock() {
  local port="$1"
  local model_id="$2"
  python3 "$MOCK_PY" --port "$port" --model-id "$model_id" >/dev/null 2>&1 &
  MOCK_PIDS+=("$!")
  for _ in $(seq 1 20); do
    if curl -sf "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  echo "[orchestrator-eval] mock server failed to start on :$port" >&2
  return 1
}

case "$CONDITION" in
  worker-only)
    echo "[orchestrator-eval] condition=worker-only (single-model baseline)"
    # Do not exec — keep this shell so traps still fire if we later add mocks.
    "$EVAL_SH" "$@"
    exit $?
    ;;
  orchestrator-worker)
    echo "[orchestrator-eval] condition=orchestrator-worker (plan → execute)"
    ORCH_BACKEND="${ORCHESTRATOR_BACKEND:-lmstudio}"
    ORCH_MODEL="${ORCHESTRATOR_MODEL:-mock-orchestrator}"
    WORKER_BACKEND="${WORKER_BACKEND:-lmstudio}"
    WORKER_MODEL="${WORKER_MODEL:-mock-worker}"
    ORCH_PORT="${ORCHESTRATOR_PORT:-1234}"
    WORKER_PORT="${WORKER_PORT:-1235}"
    EXTRA=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --orchestrator-backend) ORCH_BACKEND="$2"; shift 2 ;;
        --orchestrator-model)   ORCH_MODEL="$2"; shift 2 ;;
        --backend)              WORKER_BACKEND="$2"; shift 2 ;;
        --model)                WORKER_MODEL="$2"; shift 2 ;;
        *) EXTRA+=("$1"); shift ;;
      esac
    done
    echo "[orchestrator-eval] starting mock orchestrator backend on :$ORCH_PORT"
    start_mock "$ORCH_PORT" "$ORCH_MODEL" || exit 1
    echo "[orchestrator-eval] starting mock worker backend on :$WORKER_PORT"
    start_mock "$WORKER_PORT" "$WORKER_MODEL" || exit 1
    echo "[orchestrator-eval] orchestrator=$ORCH_BACKEND model=$ORCH_MODEL"
    echo "[orchestrator-eval] worker=$WORKER_BACKEND model=$WORKER_MODEL"
    echo "[orchestrator-eval] note: eval-runner ignores orchestrator flags (single-model)"
    RUN_ARGS=(
      --orchestrator-backend "$ORCH_BACKEND"
      --orchestrator-model "$ORCH_MODEL"
      --backend "$WORKER_BACKEND"
      --model "$WORKER_MODEL"
      --orchestrator-port "$ORCH_PORT"
      --worker-port "$WORKER_PORT"
    )
    # Must not exec: cleanup trap must kill MOCK_PIDS on exit.
    set +e
    "$EVAL_SH" "${RUN_ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
    RC=$?
    set -e
    exit "$RC"
    ;;
  *)
    echo "unknown condition: $CONDITION (use worker-only or orchestrator-worker)" >&2
    exit 1
    ;;
esac