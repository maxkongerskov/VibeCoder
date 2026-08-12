#!/usr/bin/env bash
# preflight-completion.sh — gate before update_goal(completed: true)
set -euo pipefail

WORKSPACE="${WORKSPACE:-/Users/maxkongerskov}"
REPO="${REPO:-$WORKSPACE/Downloads/VibeCoder}"
SCRATCH="${SCRATCH:-/var/folders/d0/8rwktxv56vq3dtxj_m53mml40000gn/T/grok-goal-fec9c821d3ac/implementer}"
GOAL_DIR="${GOAL_DIR:-$WORKSPACE/.grok/sessions/%2FUsers%2Fmaxkongerskov/019f38c2-71ea-7441-acf1-d3d8ed1c99f5/goal}"
PARITY_BRIDGE="${PARITY_BRIDGE:-$WORKSPACE/VibeCoder-PARITY}"
BUNDLE="$SCRATCH/verification-bundle.log"

fail() { echo "PREFLIGHT FAIL: $*" >&2; exit 1; }

[[ -f "$PARITY_BRIDGE/DELIVERABLE.json" ]] || fail "missing $PARITY_BRIDGE/DELIVERABLE.json"
[[ -f "$PARITY_BRIDGE/CHANGED_FILES.txt" ]] || fail "missing $PARITY_BRIDGE/CHANGED_FILES.txt"
[[ -f "$GOAL_DIR/COMPLETION.md" ]] || fail "missing $GOAL_DIR/COMPLETION.md"
[[ -f "$SCRATCH/PARITY_MANIFEST.txt" ]] || fail "missing $SCRATCH/PARITY_MANIFEST.txt — run capture-parity-evidence.sh first"
[[ -f "$BUNDLE" ]] || fail "missing $BUNDLE — run capture-parity-evidence.sh first"

HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
DELIVERABLE_SHA="$(python3 -c "import json; print(json.load(open('$PARITY_BRIDGE/DELIVERABLE.json'))['head_sha'])")"
[[ "$HEAD_SHA" == "$DELIVERABLE_SHA" ]] || fail "DELIVERABLE head_sha $DELIVERABLE_SHA != VibeCoder HEAD $HEAD_SHA"

grep -q "Executed 284 tests" "$BUNDLE" || fail "bundle missing 'Executed 284 tests'"
grep -q "BUILD SUCCEEDED" "$BUNDLE" || fail "bundle missing BUILD SUCCEEDED"
grep -q "TEST SUCCEEDED" "$BUNDLE" || fail "bundle missing TEST SUCCEEDED"

if grep -q "^MISSING" "$SCRATCH/PARITY_MANIFEST.txt"; then
  grep "^MISSING" "$SCRATCH/PARITY_MANIFEST.txt" >&2
  fail "PARITY_MANIFEST has MISSING entries"
fi

if grep -q "282" "$GOAL_DIR/COMPLETION.md"; then
  fail "COMPLETION.md still references stale 282 test count"
fi

FILE_COUNT="$(wc -l <"$PARITY_BRIDGE/CHANGED_FILES.txt" | tr -d ' ')"
[[ "$FILE_COUNT" -ge 100 ]] || fail "CHANGED_FILES.txt too small ($FILE_COUNT lines)"

diff -q "$GOAL_DIR/CHANGED_FILES.txt" "$PARITY_BRIDGE/CHANGED_FILES.txt" \
  || fail "goal/CHANGED_FILES.txt != VibeCoder-PARITY/CHANGED_FILES.txt"

[[ -f "$SCRATCH/CHANGED_FILES_CANONICAL.txt" ]] \
  || fail "missing $SCRATCH/CHANGED_FILES_CANONICAL.txt — run capture-parity-evidence.sh first"

CANON_COUNT="$(tail -n +7 "$SCRATCH/CHANGED_FILES_CANONICAL.txt" | grep -c . || true)"
[[ "$CANON_COUNT" -eq "$FILE_COUNT" ]] \
  || fail "CHANGED_FILES_CANONICAL path count $CANON_COUNT != bridge $FILE_COUNT"

check_paths() {
  local label="$1" paths="$2"
  if echo "$paths" | grep -q "AgentOS-P0"; then
    fail "$label still references AgentOS-P0 in path lines"
  fi
  if echo "$paths" | grep -q "StepperRailLayout"; then
    fail "$label still references legacy StepperRailLayout name"
  fi
}

check_paths "goal/CHANGED_FILES.txt" "$(cat "$GOAL_DIR/CHANGED_FILES.txt")"
check_paths "VibeCoder-PARITY/CHANGED_FILES.txt" "$(cat "$PARITY_BRIDGE/CHANGED_FILES.txt")"
check_paths "CHANGED_FILES_CANONICAL.txt" "$(tail -n +7 "$SCRATCH/CHANGED_FILES_CANONICAL.txt")"

grep -q "StepperRailSpecTests.swift" "$PARITY_BRIDGE/CHANGED_FILES.txt" \
  || fail "CHANGED_FILES missing StepperRailSpecTests.swift"

echo "PREFLIGHT OK"
echo "  VibeCoder HEAD: $HEAD_SHA"
echo "  CHANGED_FILES: $FILE_COUNT paths"
echo "  Authoritative: $GOAL_DIR/COMPLETION.md + $PARITY_BRIDGE/DELIVERABLE.json"