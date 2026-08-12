#!/usr/bin/env bash
# Fast local/CI-friendly *curated* unit gate (PA10 → PC8 → P6).
#
# Runs a short list of AgentCore XCTest filters — no mock server, no
# eval-runner, no real model. Exits non-zero if any filter fails.
#
# THIS IS NOT THE FULL SUITE.
#   • Fast loop:     ./scripts/eval-gate.sh
#   • PR confidence: ./scripts/ci-pr.sh   (full `swift test` + mock T0)
#   • Unit only PR:  SKIP_EVAL=1 ./scripts/ci-pr.sh
#
# Usage (repo root):
#   ./scripts/eval-gate.sh
#   GATE_FAIL_FAST=1 ./scripts/eval-gate.sh   # stop on first failure
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Curated smoke filters — keep this list short enough for a tight loop.
# Authoritative for the fast gate. Full suite lives only in ci-pr / `swift test`.
#
# Phase A: pairing, goals, hooks v1, SafeBash, skills, interjections
# Phase B: hooks v2, LSP, permissions, seatbelt, serve headless, task bg, allowlist
# Phase C (small sample only — P6): stop-hook cancel path + interjection live wire
#          (memory/scheduler bulk suites stay in full PR suite to keep this fast)
FILTERS=(
  # --- Phase A / foundation ---
  InterjectionBufferTests
  GoalLifecycleTests
  HookDispatcherV1Tests
  SafeBashTests
  SkillDiscoveryTests
  ToolCallPairingTests
  # --- Phase B platform ---
  HookDispatcherV2Tests
  LSPBridgeTests
  PermissionRulesTests
  SafeBashSeatbeltTests
  ServeHeadlessHonestyTests
  TaskToolBackgroundTests
  AgentDefinitionAllowlistTests
  # --- Phase C sample (keep tiny) ---
  AgentLoopStopHookPC5Tests
  PC6InterjectionLiveWireTests
)

FAIL_FAST="${GATE_FAIL_FAST:-0}"

echo "==> [eval-gate] curated unit smoke (${#FILTERS[@]} filters)"
echo "    not a full suite — use ./scripts/ci-pr.sh for PR (full swift test + T0)"
echo "==> [eval-gate] swift build --build-tests"
swift build --build-tests

failed=0
passed=0
gate_start=$SECONDS
for f in "${FILTERS[@]}"; do
  echo "==> [eval-gate] swift test --filter $f"
  t0=$SECONDS
  if ! swift test --filter "$f" --skip-build; then
    echo "✗ [eval-gate] FAILED: $f ($((SECONDS - t0))s)" >&2
    failed=1
    if [[ "$FAIL_FAST" == "1" ]]; then
      echo "✗ eval-gate aborted (GATE_FAIL_FAST=1) after failure" >&2
      exit 1
    fi
  else
    echo "✓ [eval-gate] passed: $f ($((SECONDS - t0))s)"
    passed=$((passed + 1))
  fi
done

elapsed=$((SECONDS - gate_start))
if [[ "$failed" -ne 0 ]]; then
  echo "✗ eval-gate failed — $passed/${#FILTERS[@]} filters passed in ${elapsed}s" >&2
  exit 1
fi

echo "✓ eval-gate passed (${#FILTERS[@]} filters, ${elapsed}s)"
exit 0
