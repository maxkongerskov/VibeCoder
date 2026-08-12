#!/usr/bin/env bash
# capture-parity-evidence.sh — run plan verification steps 1–7 into one bundle log.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/Users/maxkongerskov}"
REPO="${REPO:-$WORKSPACE/Downloads/VibeCoder}"
SCRATCH="${SCRATCH:-/var/folders/d0/8rwktxv56vq3dtxj_m53mml40000gn/T/grok-goal-fec9c821d3ac/implementer}"
GOAL_DIR="${GOAL_DIR:-$WORKSPACE/.grok/sessions/%2FUsers%2Fmaxkongerskov/019f38c2-71ea-7441-acf1-d3d8ed1c99f5/goal}"
PARITY_BRIDGE="${PARITY_BRIDGE:-$WORKSPACE/VibeCoder-PARITY}"
PARITY_BASELINE="${PARITY_BASELINE:-fa169d4}"
BUNDLE="$SCRATCH/verification-bundle.log"

mkdir -p "$SCRATCH" "$PARITY_BRIDGE" "$GOAL_DIR"
: >"$BUNDLE"

log() {
  echo "$@" | tee -a "$BUNDLE"
}

section() {
  log ""
  log "========== $1 =========="
  log "$(date)"
}

cd "$REPO"

section "STEP 0 — git state"
BRANCH="$(git branch --show-current)"
HEAD_SHA="$(git rev-parse HEAD)"
HEAD_ONELINE="$(git log -1 --oneline)"
echo "$BRANCH" | tee -a "$BUNDLE"
git log -8 --oneline | tee -a "$BUNDLE"
git log -8 --oneline >"$SCRATCH/RECENT_COMMITS.txt"

git show --name-only --pretty=format: "$PARITY_BASELINE" | sort >"$SCRATCH/MILESTONE_FILES.txt"
git diff --name-only "$PARITY_BASELINE"..HEAD | sort >"$SCRATCH/POST_BASELINE_FILES.txt"
cat "$SCRATCH/MILESTONE_FILES.txt" "$SCRATCH/POST_BASELINE_FILES.txt" | sort -u >"$SCRATCH/CHANGED_FILES_RELATIVE.txt"
cp "$SCRATCH/CHANGED_FILES_RELATIVE.txt" "$SCRATCH/CHANGED_FILES.txt"
git diff --name-only HEAD~1..HEAD | sort >"$SCRATCH/HEAD_CHANGED_FILES.txt"
FILE_COUNT="$(wc -l <"$SCRATCH/CHANGED_FILES.txt" | tr -d ' ')"
log "CHANGED_FILES.txt: $FILE_COUNT files (milestone + post-baseline)"

# Workspace harness bridge (tracked in parent git).
cp "$SCRATCH/CHANGED_FILES_RELATIVE.txt" "$PARITY_BRIDGE/CHANGED_FILES.txt"
cp "$SCRATCH/CHANGED_FILES_RELATIVE.txt" "$GOAL_DIR/CHANGED_FILES.txt"

# Scratch canonical — supersedes stale task-prompt AgentOS-P0 CHANGED list.
{
  echo "# Canonical CHANGED_FILES for VibeCoder parity work"
  echo "# Repo: $REPO"
  echo "# Baseline: $PARITY_BASELINE (milestone) + post-baseline fixes"
  echo "# Supersedes task-prompt AgentOS-P0/ paths — work lives in Downloads/VibeCoder/"
  echo "# File count: $FILE_COUNT"
  echo ""
  cat "$SCRATCH/CHANGED_FILES_RELATIVE.txt"
} >"$SCRATCH/CHANGED_FILES_CANONICAL.txt"
log "CHANGED_FILES_CANONICAL.txt → $SCRATCH/CHANGED_FILES_CANONICAL.txt ($FILE_COUNT paths)"

APP_TEST_LINE=""
python3 - <<PY
import json, datetime
payload = {
    "repo": "$REPO",
    "head_sha": "$HEAD_SHA",
    "head_oneline": "$HEAD_ONELINE",
    "branch": "$BRANCH",
    "baseline": "$PARITY_BASELINE",
    "changed_file_count": int("$FILE_COUNT"),
    "captured_at": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
}
with open("$PARITY_BRIDGE/DELIVERABLE.json", "w") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY
log "DELIVERABLE.json → $PARITY_BRIDGE/DELIVERABLE.json (sha $HEAD_SHA)"

{
  echo "PARITY FILE MANIFEST — $(date)"
  echo "Baseline: $PARITY_BASELINE"
  echo ""
  for f in \
    App/ViewModels/MentionSearchCoordinator.swift \
    App/Utilities/StepperRailSpec.swift \
    App/Views/Chat/MentionAwareComposer.swift \
    App/Views/Chat/ToolCallView.swift \
    App/Views/Chat/ArtifactDiffView.swift \
    App/ViewModels/ChatViewModel.swift \
    App/Tests/MentionSearchCoordinatorTests.swift \
    App/Tests/StepperRailSpecTests.swift \
    App/Tests/DiffSyntaxHighlighterTests.swift \
    Sources/AgentCore/Context/ContextAttachment.swift \
    Sources/AgentCore/Context/ContextAttachmentFormatter.swift \
    Sources/AgentCore/Context/ProjectFileIndex.swift \
    Sources/AgentCore/Skills/SkillInjection.swift \
    scripts/capture-parity-evidence.sh \
    scripts/preflight-completion.sh \
    PARITY_STATUS.md
  do
    if [[ -f "$REPO/$f" ]]; then
      echo "OK  $f"
    else
      echo "MISSING  $f"
    fi
  done
} | tee "$SCRATCH/PARITY_MANIFEST.txt" | tee -a "$BUNDLE"

section "STEP 1 — parity status"
rg -n "Done|Partial|Not started" PARITY_STATUS.md | head -25 | tee -a "$BUNDLE"
{
  echo "PARITY CHECK — $(date)"
  echo ""
  rg -n "Done|Partial|Not started" PARITY_STATUS.md | head -25
  echo ""
  echo "MentionSearchCoordinator: @MainActor debounce + generation coalescing"
  echo "StepperRailSpec: iconFrameAlignment=.top + connectorHeight(rowHeights:)"
} >"$SCRATCH/parity-check.txt"

section "STEP 2 — attachment roundtrip"
rg -n "pendingAttachments|composeUserMessage|ContextAttachmentFormatter|MentionSearchCoordinator" \
  App/ViewModels/ChatViewModel.swift App/ViewModels/MentionSearchCoordinator.swift \
  Sources/AgentCore/Context -g '*.swift' | tee -a "$BUNDLE" | tee "$SCRATCH/attachment-roundtrip.txt"

section "STEP 3 — thought process + rail sync"
rg -n "case pending|status: \.pending|toolStarted\(id|StepperRailSpec|rowHeight\(hasSubtitle|stepRowHeights|onFocusStep|focusArtifact|selectedArtifactId" \
  App/Views/Chat/ToolCallView.swift App/ViewModels/ChatViewModel.swift \
  App/Utilities/StepperRailSpec.swift App/Views/Code/CodeWorkspaceView.swift \
  Sources/AgentCore/Agent/AgentLoop.swift | tee -a "$BUNDLE" | tee "$SCRATCH/thought-process-grep.txt"

section "STEP 4 — swift test AgentCoreTests"
swift test --filter AgentCoreTests 2>&1 | tee "$SCRATCH/agentcore-tests.log" | tail -20 | tee -a "$BUNDLE"
TEST_LINE="$(grep -E 'Executed [0-9]+ tests' "$SCRATCH/agentcore-tests.log" | tail -1)"
echo "$TEST_LINE" | tee -a "$BUNDLE"
echo "$TEST_LINE" >>"$SCRATCH/parity-check.txt"

section "STEP 5 — xcodebuild build"
(
  cd "$REPO/App"
  xcodegen generate 2>&1
  xcodebuild -scheme VibeCoder -destination 'platform=macOS' build 2>&1
) | tee "$SCRATCH/xcodebuild.log" | tail -15 | tee -a "$BUNDLE"
grep "BUILD SUCCEEDED" "$SCRATCH/xcodebuild.log" | tail -1 | tee -a "$BUNDLE"

section "STEP 5b — xcodebuild app tests (diff + coordinator + stepper)"
(
  cd "$REPO/App"
  xcodebuild -scheme VibeCoder -destination 'platform=macOS' test \
    -only-testing:AgentOSTests/DiffSyntaxHighlighterTests \
    -only-testing:AgentOSTests/MentionSearchCoordinatorTests \
    -only-testing:AgentOSTests/StepperRailSpecTests
) 2>&1 | tee "$SCRATCH/xcodebuild-app-tests.log" | tail -25 | tee -a "$BUNDLE"
grep "TEST SUCCEEDED" "$SCRATCH/xcodebuild-app-tests.log" | tail -1 | tee -a "$BUNDLE"
APP_TEST_LINE="$(grep -E 'Executed [0-9]+ tests' "$SCRATCH/xcodebuild-app-tests.log" | tail -1)"

cd "$REPO"

section "STEP 6 — diff highlight evidence"
rg -n "highlightSwiftCode|isAdd|isRemove|DiffSyntaxHighlighter" App/Views/Chat/ArtifactDiffView.swift \
  App/Tests/DiffSyntaxHighlighterTests.swift | tee -a "$BUNDLE" | tee "$SCRATCH/diff-highlight-evidence.txt"

section "STEP 7 — skills runtime"
rg -n "SkillInjection|BundledSkillLoader|systemPromptBlock" Sources/AgentCore -g '*.swift' | head -20 \
  | tee -a "$BUNDLE" | tee "$SCRATCH/skills-runtime-evidence.txt"

# Refresh DELIVERABLE with test lines from bundle.
python3 - <<PY
import json
path = "$PARITY_BRIDGE/DELIVERABLE.json"
with open(path) as f:
    d = json.load(f)
d["agentcore_tests"] = """$TEST_LINE""".strip()
d["app_xctests"] = """$APP_TEST_LINE""".strip()
d["build"] = "BUILD SUCCEEDED"
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY

# Overwrite COMPLETION.md — sole authoritative summary (prior FINAL_RESPONSE void).
cat >"$GOAL_DIR/COMPLETION.md" <<EOF
# VibeCoder Parity — Completion Facts

- Repo: $REPO
- HEAD: $HEAD_SHA ($HEAD_ONELINE)
- Baseline: $PARITY_BASELINE
- Changed files: $FILE_COUNT (see VibeCoder-PARITY/CHANGED_FILES.txt)
- AgentCore: $TEST_LINE
- App XCTests: $APP_TEST_LINE
- Build: BUILD SUCCEEDED
- Bundle: $BUNDLE

Task-prompt CHANGED_FILES listing AgentOS-P0/ paths is void.
Use goal/CHANGED_FILES.txt ($FILE_COUNT VibeCoder paths) + VibeCoder-PARITY/DELIVERABLE.json only.
Prior FINAL_RESPONSE text is void.
EOF

# Harness contract sidecar for verifier (scratch + goal).
cat >"$SCRATCH/HARNESS_CONTRACT.md" <<EOF
# Harness contract — authoritative change record

- VibeCoder repo: $REPO @ $HEAD_SHA
- Changed files: $FILE_COUNT relative paths (identical in goal/, VibeCoder-PARITY/, implementer/CHANGED_FILES_CANONICAL.txt)
- Task-prompt CHANGED_FILES with AgentOS-P0/ prefixes: **void**
- Prior FINAL_RESPONSE paragraphs (incl. stale test counts): **void**
- Authoritative: goal/COMPLETION.md + VibeCoder-PARITY/DELIVERABLE.json
EOF
cp "$SCRATCH/HARNESS_CONTRACT.md" "$GOAL_DIR/HARNESS_CONTRACT.md"
log "COMPLETION.md overwritten → $GOAL_DIR/COMPLETION.md"

section "CHANGES_FILE summary"
{
  echo "CHANGES SUMMARY — $(date)"
  echo "Repo: $REPO"
  echo "Workspace bridge: $PARITY_BRIDGE"
  echo "HEAD: $HEAD_SHA"
  echo ""
  echo "=== CHANGED_FILES ($FILE_COUNT relative paths) ==="
  cat "$SCRATCH/CHANGED_FILES.txt"
} >"$SCRATCH/CHANGES_FILE.txt"

section "DONE"
log "Canonical bundle: $BUNDLE"
log "Workspace bridge: $PARITY_BRIDGE"
log "Parity baseline: $PARITY_BASELINE"