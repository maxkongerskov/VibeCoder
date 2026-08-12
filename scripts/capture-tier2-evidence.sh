#!/usr/bin/env bash
# capture-tier2-evidence.sh — Tier 2 phases 1-2 verification bundle.
# Dual-repo contract:
#   • Product paths → goal/CHANGED_FILES.txt + scratch/CHANGED_FILES_PRODUCT.txt
#   • Workspace harness → VibeCoder-PARITY/CHANGED_FILES.txt (bridge files only)
set -euo pipefail

SCRATCH="${SCRATCH:-/var/folders/d0/8rwktxv56vq3dtxj_m53mml40000gn/T/grok-goal-c8b35623cd5a/implementer}"
REPO="${REPO:-/Users/maxkongerskov/Downloads/VibeCoder}"
WORKSPACE="${WORKSPACE:-/Users/maxkongerskov}"
GOAL_DIR="${GOAL_DIR:-/Users/maxkongerskov/.grok/sessions/%2FUsers%2Fmaxkongerskov/019f38c2-71ea-7441-acf1-d3d8ed1c99f5/goal}"
PARITY_BRIDGE="${PARITY_BRIDGE:-$WORKSPACE/VibeCoder-PARITY}"
TIER2_BASELINE="${TIER2_BASELINE:-0d6ed55}"
FEATURE_COMMIT="${FEATURE_COMMIT:-24412b2}"

mkdir -p "$SCRATCH" "$PARITY_BRIDGE" "$GOAL_DIR"

log() { echo "$@" | tee -a "$SCRATCH/tier2-verification-bundle.log"; }

: >"$SCRATCH/tier2-verification-bundle.log"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
HEAD_ONELINE="$(git -C "$REPO" log -1 --oneline)"
log "TIER 2 VERIFICATION — $(date)"
log "VibeCoder: $REPO @ $HEAD_SHA ($HEAD_ONELINE)"
log "Feature commit: $FEATURE_COMMIT"
log "Tier-2 baseline: $TIER2_BASELINE"

cd "$REPO"

# --- Product change manifests (VibeCoder repo; not workspace-tracked) ---
git -C "$REPO" show --name-only --pretty=format: HEAD | sort >"$SCRATCH/HEAD_CHANGED_FILES.txt"
git -C "$REPO" show --name-only --pretty=format: "$FEATURE_COMMIT" | sort >"$SCRATCH/FEATURE_COMMIT_FILES.txt"
git -C "$REPO" diff --name-only "$TIER2_BASELINE"..HEAD | sort >"$SCRATCH/CHANGED_FILES_PRODUCT.txt"
cp "$SCRATCH/CHANGED_FILES_PRODUCT.txt" "$GOAL_DIR/CHANGED_FILES.txt"

HEAD_COUNT="$(wc -l <"$SCRATCH/HEAD_CHANGED_FILES.txt" | tr -d ' ')"
FEATURE_COUNT="$(wc -l <"$SCRATCH/FEATURE_COMMIT_FILES.txt" | tr -d ' ')"
PRODUCT_COUNT="$(wc -l <"$SCRATCH/CHANGED_FILES_PRODUCT.txt" | tr -d ' ')"

# --- Workspace harness bridge (what parent git patch actually tracks) ---
cat >"$PARITY_BRIDGE/CHANGED_FILES.txt" <<EOF
VibeCoder-PARITY/CHANGED_FILES.txt
VibeCoder-PARITY/DELIVERABLE.json
EOF
HARNESS_COUNT=2

{
  echo "CHANGES SUMMARY — $(date)"
  echo ""
  echo "VibeCoder HEAD: $HEAD_SHA ($HEAD_ONELINE)"
  echo "Feature commit: $FEATURE_COMMIT ($FEATURE_COUNT product files)"
  echo "HEAD-only delta: $HEAD_COUNT files (see HEAD_CHANGED_FILES.txt)"
  echo "Cumulative Tier-2 product delta ($TIER2_BASELINE..HEAD): $PRODUCT_COUNT files"
  echo ""
  echo "=== HEAD_CHANGED_FILES ($HEAD_COUNT) ==="
  cat "$SCRATCH/HEAD_CHANGED_FILES.txt"
  echo ""
  echo "=== FEATURE_COMMIT_FILES ($FEATURE_COUNT) @ $FEATURE_COMMIT ==="
  cat "$SCRATCH/FEATURE_COMMIT_FILES.txt"
  echo ""
  echo "=== CHANGED_FILES_PRODUCT ($PRODUCT_COUNT) ==="
  cat "$SCRATCH/CHANGED_FILES_PRODUCT.txt"
  echo ""
  echo "=== WORKSPACE HARNESS ($HARNESS_COUNT bridge files) ==="
  cat "$PARITY_BRIDGE/CHANGED_FILES.txt"
} >"$SCRATCH/CHANGES_FILE.txt"

# Step 1 — PARITY_STATUS
{
  echo "PARITY TIER 2 CHECK — $(date)"
  rg -n "Command palette|Parallel read-only|Integrated file tree" PARITY_STATUS.md
} | tee "$SCRATCH/parity-tier2-check.txt" | tee -a "$SCRATCH/tier2-verification-bundle.log"

# Step 2 — command palette grep
{
  rg -n "CommandPalette|commandPaletteRequested|keyboardShortcut.*k|showingModelPicker|ModelPickerSheet|toggleRail|safeModeOn|showingSettings" \
    App/VibeCoderApp.swift App/Views/RootView.swift App/Views/CommandPalette/
  rg -n "parallelReadOnlyToolNames|git_diff|git_status" Sources/AgentCore/Agent/ChatLoop.swift
} | tee "$SCRATCH/command-palette-grep.txt" | tee -a "$SCRATCH/tier2-verification-bundle.log"

# Step 3 — AgentCore tests
swift test --filter AgentCoreTests 2>&1 | tee "$SCRATCH/agentcore-tests.log" | tail -5 | tee -a "$SCRATCH/tier2-verification-bundle.log"
AGENTCORE_LINE="$(grep -E 'Executed [0-9]+ tests' "$SCRATCH/agentcore-tests.log" | tail -1)"
echo "$AGENTCORE_LINE" | tee -a "$SCRATCH/tier2-verification-bundle.log"

# Step 4 — file tree grep
{
  rg -n "ProjectFileTreeView|previewProjectFile|fileTreeVisible|listAllFilesAsync" \
    App/Views/Code App/ViewModels/ChatViewModel.swift \
    Sources/AgentCore/Context/ProjectFileIndex.swift
} | tee "$SCRATCH/file-tree-grep.txt" | tee -a "$SCRATCH/tier2-verification-bundle.log"

# Step 5 — xcodebuild
(
  cd App
  xcodegen generate 2>&1
  xcodebuild -scheme VibeCoder -destination 'platform=macOS' build 2>&1
) | tee "$SCRATCH/xcodebuild.log" | tail -5 | tee -a "$SCRATCH/tier2-verification-bundle.log"
grep "BUILD SUCCEEDED" "$SCRATCH/xcodebuild.log" | tail -1 | tee -a "$SCRATCH/tier2-verification-bundle.log"

# Step 6 — App XCTests executed
(
  cd App
  xcodebuild -scheme VibeCoder -destination 'platform=macOS' test \
    -only-testing:AgentOSTests/CommandPaletteFilterTests \
    -only-testing:AgentOSTests/ProjectFileTreeBuilderTests 2>&1
) | tee "$SCRATCH/xcodebuild-app-tests.log" | tail -15 | tee -a "$SCRATCH/tier2-verification-bundle.log"
grep "TEST SUCCEEDED" "$SCRATCH/xcodebuild-app-tests.log" | tail -1 | tee -a "$SCRATCH/tier2-verification-bundle.log"
APP_TEST_LINE="$(grep -E 'Executed [0-9]+ tests' "$SCRATCH/xcodebuild-app-tests.log" | tail -1)"

{
  echo "Tier 2 tests executed — $(date)"
  echo "AgentCore: $AGENTCORE_LINE"
  echo "App XCTests: $APP_TEST_LINE"
  echo "Suites: CommandPaletteFilterTests, ProjectFileTreeBuilderTests"
  echo "AgentCore parallel: ChatLoopParallelToolsTests (swift test --filter AgentCoreTests)"
  echo ""
  echo "Commit attribution:"
  echo "  feature $FEATURE_COMMIT → $FEATURE_COUNT product files"
  echo "  HEAD $HEAD_SHA → $HEAD_COUNT product files"
  echo "  cumulative → $PRODUCT_COUNT product files"
  echo "  workspace harness → $HARNESS_COUNT bridge files"
} | tee "$SCRATCH/tier2-tests-note.txt" | tee -a "$SCRATCH/tier2-verification-bundle.log"

python3 - <<PY
import json, datetime
payload = {
    "repo": "$REPO",
    "head_sha": "$HEAD_SHA",
    "head_oneline": "$HEAD_ONELINE",
    "goal": "tier2-phase-1-2",
    "head_commit_file_count": int("$HEAD_COUNT"),
    "feature_commit_sha": "$FEATURE_COMMIT",
    "feature_commit_file_count": int("$FEATURE_COUNT"),
    "tier2_product_file_count": int("$PRODUCT_COUNT"),
    "tier2_baseline": "$TIER2_BASELINE",
    "workspace_bridge_files": [
        "VibeCoder-PARITY/CHANGED_FILES.txt",
        "VibeCoder-PARITY/DELIVERABLE.json",
    ],
    "workspace_bridge_file_count": int("$HARNESS_COUNT"),
    "captured_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "agentcore_tests": """$AGENTCORE_LINE""".strip(),
    "app_xctests": """$APP_TEST_LINE""".strip(),
    "build": "BUILD SUCCEEDED",
    "product_manifest": "goal/CHANGED_FILES.txt",
}
with open("$PARITY_BRIDGE/DELIVERABLE.json", "w") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY

log "Product manifest: $PRODUCT_COUNT paths → goal/CHANGED_FILES.txt"
log "Harness bridge: $HARNESS_COUNT paths → VibeCoder-PARITY/CHANGED_FILES.txt"
log "HEAD delta: $HEAD_COUNT | Feature commit: $FEATURE_COUNT"
log "DONE — bundle: $SCRATCH/tier2-verification-bundle.log"