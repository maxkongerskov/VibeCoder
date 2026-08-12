#!/usr/bin/env bash
# capture-recommendations-evidence.sh — VibeCoder strict-review recommendations bundle.
# Derives the harness round dynamically; writes honesty anchors the verifier reads.
set -euo pipefail

SCRATCH="${SCRATCH:-/var/folders/d0/8rwktxv56vq3dtxj_m53mml40000gn/T/grok-goal-ea8c4eb29ece}"
REPO="${REPO:-/Users/maxkongerskov/Downloads/VibeCoder}"
GOAL_DIR="${GOAL_DIR:-/Users/maxkongerskov/.grok/sessions/%2FUsers%2Fmaxkongerskov/019f3956-5245-7691-9958-60d2ea525c90/goal}"
IMPL="${SCRATCH}/implementer"

mkdir -p "$IMPL" "$GOAL_DIR"

# Highest-numbered patch slot (includes empty harness placeholders for this round).
ROUND="$(ls "$SCRATCH"/goal-classifier-ea8c4eb29ece-*.patch 2>/dev/null \
  | sed 's/.*-\([0-9]*\)\.patch/\1/' | sort -n | tail -1)"
PATCH="$SCRATCH/goal-classifier-ea8c4eb29ece-${ROUND}.patch"
CHANGED="$GOAL_DIR/CHANGED_FILES.txt"
TOP_CHANGED="$SCRATCH/CHANGED_FILES"

echo "capture-recommendations-evidence: round=$ROUND patch=$PATCH"

cd "$REPO"

# Stage only in-scope paths (plan assumed scope) + this capture script.
git add \
  scripts/capture-recommendations-evidence.sh \
  Sources/AgentCore/Agent/ \
  Sources/AgentCore/Tools/ToolClassification.swift \
  Sources/AgentCore/Tools/ToolRegistry.swift \
  Sources/AgentCore/Settings/AppSettings.swift \
  Sources/Harness/ \
  Tests/AgentCoreTests/ \
  Tests/HarnessTests/

git diff HEAD >"$PATCH"
{
  git diff --name-only HEAD
  git diff --cached --name-only
} | sort -u >"$CHANGED"

git diff --stat HEAD >"$IMPL/changed-files.stat"
git status --short >"$IMPL/changed-files.list"
cp "$CHANGED" "$TOP_CHANGED"
cp "$CHANGED" "$IMPL/CHANGED_FILES"

# Verification plan steps — logs in implementer scratch.
swift test --filter EditVerify 2>&1 | tee "$IMPL/edit-verify-tests.log"
swift test --filter Stall 2>&1 | tee "$IMPL/stall-tests.log"
swift test --filter StreamAssembler 2>&1 | tee "$IMPL/stream-assembler-tests.log"
swift test 2>&1 | tee "$IMPL/swift-test.log"
wc -l Sources/AgentCore/Agent/AgentLoop.swift | tee "$IMPL/agent-loop-lines.txt"

# Preflight gate — exit 1 on any failure.
test -s "$PATCH" || { echo "FAIL: patch empty ($PATCH)"; exit 1; }
test -s "$CHANGED" || { echo "FAIL: CHANGED_FILES.txt empty ($CHANGED)"; exit 1; }
test -s "$TOP_CHANGED" || { echo "FAIL: top-level CHANGED_FILES empty ($TOP_CHANGED)"; exit 1; }
grep -q 'scripts/capture-recommendations-evidence.sh' "$CHANGED" || {
  echo "FAIL: capture script not listed in CHANGED_FILES.txt"; exit 1;
}
grep -qE 'App/|ModelsLandingView' "$CHANGED" && {
  echo "FAIL: out-of-scope paths in CHANGED_FILES.txt"; exit 1;
}
TRACE_COUNT="$(grep -c EDIT_VERIFY_TRACE "$IMPL/edit-verify-tests.log" || true)"
if [ "$TRACE_COUNT" -lt 2 ]; then
  echo "FAIL: expected >=2 EDIT_VERIFY_TRACE lines, got $TRACE_COUNT"
  exit 1
fi
if ! grep -E 'Executed [0-9]+ tests, with 0 failures' "$IMPL/swift-test.log" | tail -1 | grep -q '0 failures'; then
  echo "FAIL: swift-test.log does not report 0 failures"
  exit 1
fi
if rg -l HarnessPolicyForward Sources/Harness/ 2>/dev/null; then
  echo "FAIL: HarnessPolicyForward still referenced under Sources/Harness/"
  exit 1
fi
if rg 'shouldVerifyBeforeFinish|shouldVerifyEdits' Sources/AgentCore/Agent/AgentLoop.swift 2>/dev/null; then
  echo "FAIL: AgentLoop re-calls shouldVerify* on finish path"
  exit 1
fi

{
  echo "round=$ROUND"
  echo "patch=$PATCH"
  echo "patch_bytes=$(wc -c <"$PATCH" | tr -d ' ')"
  echo "changed_paths=$(wc -l <"$CHANGED" | tr -d ' ')"
  echo "goal_changed=$CHANGED"
  echo "top_changed=$TOP_CHANGED"
} >"$IMPL/capture-manifest.txt"

echo "OK: round=$ROUND patch=$(wc -c <"$PATCH" | tr -d ' ') changed=$(wc -l <"$CHANGED" | tr -d ' ')"