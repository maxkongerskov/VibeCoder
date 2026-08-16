# VibeCoder ↔ ZCode UX/UI Parity — Full Report & Implementation Plan

Generated 2026-08-16. Companion to `PARITY_WITH_ZCODE.md` (agent harness — done).
This doc covers **what the user sees and operates**: windows, chrome, chat surface,
tool/diff/plan rendering, permission UX, session management, settings, theme.

**Evidence** (in `docs/ui-parity-research/`, each with file:line citations):
- `zcode-shell.md` (428 L) · `zcode-chat.md` (247 L) · `zcode-settings.md` (335 L) — mined from the
  extracted ZCode 3.7.7 asar (`~/zcode-reverse/extracted/out/{renderer,main}`)
- `vibecoder-shell.md` (238 L) · `vibecoder-chat.md` (217 L) · `vibecoder-settings.md` (387 L) —
  read from live Swift sources in `App/`, cross-checked against `UI_DESIGN.md`
- `shots/*.png` + `shots-manifest.md` — live screenshots of both running apps (ZCode 3.7.7 signed in;
  VibeCoder 1.0.5 debug build)

Scoring: ✅ parity / VC stronger · 🟡 partial (work described) · ❌ missing.
Priorities: P0 = highest feel-impact, P1 next, P2 later, P3 = out-of-scope unless asked.

---

## Scorecard

| # | Surface | ZCode | VibeCoder | Status |
|---|---------|-------|-----------|--------|
| 1 | Window layout | 3 regions: sidebar / chat + bottom terminal / right side pane; hidden titlebar, no status bar | 3 regions: sidebar / chat + bottom terminal / right inspector; hidden titlebar; File/View menu accelerators | 🟡 browser/whiteboard/split still out |
| 2 | Sidebar | Tasks/Projects tabs, in-sidebar search, automations/skills/file-tree entries, colored groups | Workspace header + 5 text-nav rows + Tasks list (pin, time buckets); **no search** | 🟡 (U2) |
| 3 | Composer | Lexical; `@` files, `$` skills, `#` sessions; queue-while-running w/ Steer·reorder; Compress btn; history 30 | TextField(axis:.vertical); `@` files/folders/symbols only; **interjection** instead of queue; history ✓ | 🟡 (U2) |
| 4 | Message rendering | Streamdown + **Shiki** syntax, mermaid, KaTeX; user bubble right / assistant flat; hover copy·edit·like·**Fork** | Own line scanner, **no syntax highlighting**; same bubble layout ✓; copy only; fork via `/fork` | 🟡 (U1 + P2) |
| 5 | Tool-call rendering | Per-family verbs, **Explore** grouping of read-only runs, status pills, expand I/O; SubAgent **Open in side pane** | `Verb · Status` + Tools grouping; edit cards w/ inline diffs (**stronger**); task rows **Open in side pane** (U4) | ✅ near-parity (label pass P2) |
| 6 | Diff / patch / undo | Turn-end "N files changed +/−" card → per-file Review (unified patch viewer) → **Undo via checkpoints**; no per-hunk | Pre-apply PatchReviewSheet: per-file Accept/Reject, Apply selected (unique); worktree review sheet; `/rewind` exists but **no turn-end card, no Undo button** | 🟡 complementary — combine (U1) |
| 7 | Plan mode | In-flow approval: "Exit plan mode and start implementation."; Plans status panel | Floating sticky planner + **Approve & Run / Stay in Plan** (stronger) | ✅ VC stronger |
| 8 | Permission prompts | Allow / Always allow / **Allow for session** / **Always allow in this project** / Deny / Always deny; Tab·arrows·Enter; prefix chips | Once / Always / Never / Deny sheet (Esc=deny); no session scope, no keyboard nav, no prefix chips | 🟡 (U1) |
| 9 | Commands & palette | ~20 slash + `$skill` triggers; sectioned command palette (~30 cmds); **Find in task** ⌘F | 30+ slash ✓; palette only **12 items**, no arrow-key selection, **no in-chat search** | 🟡 (U1 palette / U2 find) |
| 10 | Session management | Pin/archive/rename/**per-message fork**/split view/colored groups/unread markers | Pin/archive/rename/fork (whole history) / move-to-project; no groups/unread/split | 🟡 (U2 search; P2 rest) |
| 11 | Interrupts & queue | Stop (Esc); queued messages held, **Steer** = inject now; pause/resume after stop | Stop (Esc) ✓; mid-turn **interjection** (VC semantics); no visible queue UI | 🟡 (U2) |
| 12 | Status surfaces | Collapsible capsule: Git, Changes, Branch, Commit/Push, Goal, Plans, Todos, Terminals, Agents | Context meter + hover breakdown ✓ (close), goal banner, plan card, notice cards; **no git/branch capsule** | 🟡 (P2) |
| 13 | Terminal & side pane | Bottom xterm dock + right pane tabs: Browser / Review / Code viewer / Whiteboard / Subagents | Bottom PTY dock + inspector **Files / Changes / Subagents** (live directory + Open in side pane). No browser / whiteboard | 🟡 U3+U4 (browser = P3) |
| 14 | Settings | 14 sections in 2-pane: hooks **editor**, skills **manager**, subagent forms, commands editor, MCP (stdio/SSE/import), automations | 14 tabs: hooks editor, **skills manager**, **subagents manager** (U4); MCP richer (HTTP/stdio/OAuth); unique builtin-tool toggles / grants / context | 🟡 commands editor still P2 |
| 15 | Models & backends | Cloud provider catalog (GLM/Kimi/DeepSeek/Qwen…), per-model context/output limits, reasoning levels from catalog | 7 local-backend panes (LM Studio/EXO/oMLX/Ollama/Unsloth/Custom/Local API), engine strip, live model picker | ✅ different posture (local-first) — keep |
| 16 | Theme & identity | `system`/`zai-dark`/`zai-light`; neutrals #161616/#202020/#2b2b2b, white primary | System/Light/Dark + font scale; dark #161616/#222222/#2B2B2B (**near-identical neutrals**), orange accent `#E48B46`, SF fonts | 🟡 identity decision (open) |
| 17 | Onboarding / account | Welcome + OAuth + migration import wizard (Claude Code/Codex/etc.) | Retired by design; empty states guide model connection | ✅ different posture (local app) — keep |
| 18 | Remote / mobile | SSH/WSL/Docker workspaces (new windows), phone remote QR | **RemoteControlSheet QR** ✓ (parity!), no SSH workspaces | ✅ mobile parity; 🟡 SSH = P3 |

**Where VibeCoder already wins (keep, don't regress):** pre-apply patch review with per-file
decisions; worktree isolation UI (review/commit/discard/merge); two-model orchestrator pill;
Safe Mode allow-lists + durable grants UI; per-builtin-tool enable toggles (ZCode has none);
Markdown conversation export (ZCode only exports logs); context meter with live breakdown;
Memory editor (MEMORY/DECISIONS, stronger than ZCode's viewer); Notes surface.

---

## 1. Window layout & chrome — 🟡

**ZCode**: default 1200×800; hidden titlebar (traffic lights inset); flex row of
**sidebar / center stack [chat + bottom terminal] / right side pane**; collapsible capsule status
panel; no OS-level footer. Menus: ZCode/File/Edit/View/Window/Help with real accelerators
(⌘N, ⌘O, ⌘W, zoom). Shortcuts: ⌘K/⌘⇧P palette · ⌘F find-in-task · ⌘B sidebar · **⌘J terminal** ·
**⌥⌘B side pane** · ⌘[ ⌘] nav back/fwd · **⌘⇧[ ⌘⇧]** prev/next task.

**VibeCoder**: min 960×620, no default size; hidden titlebar ✓; **only** NavigationSplitView
(sidebar + detail); toolbar has a single New-conversation button; menus: File(⌘N)/Settings ⌘,
/View palette ⌘K + Stop Agent ⌘. (+3 DEBUG items). No panel toggles, no task nav shortcuts.

**Gaps**: side pane (U3), terminal dock (U3), menu/shortcut pass incl. ⌘⇧[ ], prev/next task (P2).

## 2. Sidebar — 🟡

**ZCode**: Tasks / Projects tab switch; "Search tasks…"; pinned/recent, archive state,
statuses (Running/Restoring/Ready/Done/Failed), +/− deltas on rows, "Awaiting approval" tag;
grouped lists with 7 colors; per-row: pin/rename/archive/delete/split-pane/trajectory;
footer profile = theme·locale·zoom·usage (cloud) · export logs.

**VibeCoder**: workspace header (folder + name + path) → Chat/Projects/Models(badge)/Notes/Scheduled
text rows → TASKS section: +New Task, pinned + time buckets (Today…Older), rows = status dot +
title + 72-char preview + relative time; context menu: move-to-project/pin/rename/archive/delete/
move-down; footer: Delete all + Settings. **No search field, no groups, no status tags beyond dot.**

**Gaps (U2)**: in-sidebar search. **P2**: groups + colors, awaiting-approval tag, unread markers.

## 3. Composer — 🟡 (U2)

| Capability | ZCode | VibeCoder |
|---|---|---|
| `@` context picker | files (workspace search), sessions, whiteboards, plugins | files ≤8 / folders ≤6 / symbols ≤6 → **pins sticky context** (stronger: sticky vs one-shot) |
| `$` skills trigger | yes | **no** |
| `#` session insert | yes | no (ReadSessionContext exists in harness — UI trigger missing) |
| Send while running | **Queue message**: held list, drag-reorder, per-item Steer/Run now/Edit/Remove; pause on stop + Continue | **Interjection** applied mid-turn; no queue UI (placeholder even says "queue") |
| Context usage | toolbar "{used} of {total}" + breakdown popover + **Compress** (sends /compact) | meter capsule + hover breakdown ✓; no one-click Compress button |
| Prompt history | 30, ↑/↓ | ✓ persisted, ↑/↓ |
| Attachments | file picker + paste images (20 MB) + drag; ≤8, upload progress chips | NSOpenPanel files/folders + drop; one-shot chips |
| Prompt enhance | "Enhance prompt" button (model call) | no (P3) |
| Mode / model / effort chips | ✓ GLM modes + Ctrl+M menu, thought level, locked while running | ✓ 4-mode chip (⇧Tab), model picker, thinking effort — near-parity |

**Plan**: U2 `queue` agent implements queue-with-Steer (Steer = existing interjection path);
U2 `mentions` agent adds `$skill` / `#session` triggers; Compress button + image-paste attach
ride along (composer-local).

## 4. Message rendering — 🟡 (U1 + P2)

**ZCode**: Streamdown markdown, **Shiki** code highlighting (many themes), mermaid diagrams,
KaTeX math; code blocks: language + wrap toggle + copy; tables copyable as md/csv/tsv;
images w/ gallery + preview; hover: user Copy/Edit (edit = re-prompt with "reset chat+files"),
assistant Copy/Like/Dislike/**Fork** (+timestamp); long replies show preview + "View full";
reasoning: animated "Thinking…" → "Thought for Ns" collapsible; centered timeline dividers
for compact/fork/model-change/goal events.

**VibeCoder**: custom line-scanner markdown (h1-6, lists, tables, code, blockquote, hr; inline
bold/italic/link/code) — **no syntax highlighting in chat code blocks** (only the diff
highlighter exists); no mermaid/math; user pill right (560pt, neutral fill), assistant flat ✓
same layout as ZCode; copy chips only; reasoning block w/ "Thought for Ns" ✓ near-parity;
Working/Worked duration header ✓.

**Plan**: U1 `hl` agent adds a keyword-based syntax highlighter (Swift/Py/JS-TS/JSON/YAML/Bash/
Go/Rust/C… ~15 langs, no new deps — same spirit as `DiffSyntaxHighlighter`). **P2**: per-message
Fork button (checkpoint-sliced fork — harness has checkpoints), like/dislike (skip: no backend),
mermaid/KaTeX → P3.

## 5. Tool-call rendering — ✅ near-parity (P2 polish)

Structurally the two are already close: both group consecutive read-only runs into one
expandable row (ZCode "Explore" w/ N search / N file buckets; VC "Tools · {summary}" with
running/failed counts), both show expandable mono I/O with truncation + "Show full",
both render subagent cards (VC adds Kill; ZCode adds "Open in side pane"), both surface
dedicated edit/file rows.

**VC is stronger**: inline edit cards with +/- diff, per-card Undo (hunk), auto-open on change.
**Polish (P2)**: adopt ZCode's per-family verb copy for shell (Ran/Running), read, write;
"Explore"-style bucket counters on the collapsed group.

## 6. Diff / patch / undo — 🟡 combine both (U1)

**ZCode**: after each turn, a **"N file(s) changed +a −d"** card; per-file **Review** opens the
unified-patch code viewer; header **Undo** dialog ("Safe / Unsafe / Ignored" classification)
rewinds via checkpoints; Reapply/Undone badges. No per-hunk accept/reject.

**VibeCoder**: Ask-mode `apply_patch` opens **PatchReviewSheet pre-apply** (per-file Accept/
Reject, Apply selected, Always-allow-folder) — ZCode has nothing like it; worktree review
sheet (commit/discard/merge); `/rewind` slash exists but there is **no turn-end summary card
and no visible Undo affordance**.

**Plan (U1 `turnend`)**: add ZCode-style turn-end change summary card below each assistant
turn (aggregate the edit results already in the transcript: paths, +/−) with per-file Review
(reuse existing diff views) and an **Undo** action posting the existing rewind request. Keeps
VC's pre-apply sheet as-is — the two flows are complementary (approve before / undo after).

## 7. Plan mode — ✅ VC stronger

VC's floating sticky planner (STEPS/COMPLETE progress, todo rows, **Approve & Run / Stay in
Plan**, toggle todos while pending approval) exceeds ZCode's single Approve elicitation.
No action; optional P2: copy alignment ("Approve & Run" ≈ "Exit plan mode and start
implementation") — skip.

## 8. Permission prompts — 🟡 (U1 `permsheet`)

**ZCode**: "Permission required" card with **six** mapped actions: Allow · Always allow ·
Allow for session · Always allow in this project · Deny · Always deny; descriptions per scope;
**Tab/arrows select + Enter confirm**; command-prefix shown as mono chips ("Command prefix" /
"Exact command only"); "Request from subagent: {type}" origin line; AskUserQuestion auto-continues
after 5 min (setting).

**VibeCoder**: modal `ShellApprovalSheet`: reason + mono command; **Once / Always / Never / Deny**;
dangerous commands force Once (good — keep); Esc = deny + drain; "Always" persists per project.
No session-scoped grant, no keyboard navigation on the sheet, no prefix chips, subagent origin
not shown (harness has it — UI doesn't surface).

**Plan (U1)**: add **Allow for session** (new in-memory `SessionGrantStore` scoped to the
conversation) alongside existing project-scope; Tab/arrow + Enter selection; prefix chip;
origin line for subagent requests.

## 9. Commands & palette — 🟡 (U1 `palette`, U2 `chatsearch`)

**ZCode**: 20+ agent slash commands (incl. `/expert /workflow(s) /rewind /init /goal`), custom
markdown commands with `$ARGUMENTS`, sectioned command palette (Suggested/Chat/Navigation/
Panels/Configure/App, ~30 commands incl. panel toggles, theme switch), ⌘F **Find in task**
with message/file-change scopes.

**VibeCoder**: 30+ slash commands ✓ (harness already has custom `.md` command support from
parity work); ⌘K palette with **12 hard-coded items**, no arrow-key/section UI, no panel
toggles; **no in-chat search anywhere** (agent-side ConversationSearch only).

**Plan**: U1 `palette`: add working entries (theme toggle, prev/next task, export conversation,
open Notes/Models/Scheduled, new project, stop agent) — ~10 items. U2 `chatsearch`: ⌘F find
in current task (messages scope, prev/next highlight) + menu + palette entry. P2: file-changes
scope for find; per-message fork button.

## 10. Session management — 🟡 (U2 / P2)

Parity today: pin, archive, rename, delete, relative time, statuses.
**Missing vs ZCode**: per-message **Fork** (P2 — checkpoint-sliced; harness has checkpoints),
colored task **groups**, unread markers, split-pane tasks (P3 — needs layout work),
"View model trajectory" (VC has opt-in ModelIORecorder from harness work — surface in row
menu, P2), auto-archive setting (P3).

## 11. Interrupts & queue — 🟡 (U2 `queue`)

Covered in §3. VC's interjection is a feature; the plan keeps it as **Steer** inside a
ZCode-style visible queue (reorder / remove / run-now), with pause-on-stop + Continue.

## 12. Status surfaces — 🟡 (P2)

**ZCode**: collapsible status capsule (Git tools, Changes, Branch, Commit/Push, Goal, Plans,
Todos with fold, Terminals, Agents running/stop) + context usage breakdown.
**VibeCoder**: goal banner ✓, plan card ✓, transcript notice cards ✓, context meter + hover
breakdown ✓. Missing: git/branch/changes capsule and todos-in-status (todos show in plan
card only when present). P2 `statuscapsule` agent after U3.

## 13. Terminal & side pane — ❌ (U3, biggest structural gap)

**ZCode**: bottom xterm terminal dock (⌘J; real PTY, font settings) + independent right
side pane with tabs: **Browser** (in-app webview), **Review/Diff**, **Code viewer**,
**Terminal**, **Whiteboard**, **Repo wiki**, **Subagents** (live fan-out panel), Open file
searcher. Tabs addable/closable, pane resize/restore.

**VibeCoder**: nothing equivalent — background shell jobs show a banner in-transcript only;
no inspector column. `ProjectFileTreeBuilder` exists but is test-only (unused by views).

**Plan U3**: `sidepane` agent — macOS 14 `.inspector`: tabs v1 = **Files** (wire the existing
`ProjectFileTreeBuilder`) + **Changes** (reused diff views); ⌥⌘B toggle. Then `terminal` agent
— bottom dock with a PTY (forkpty + ANSI-aware NSTextView, single terminal per project cwd,
⌘J). In-app browser → P3 (WKWebView wrap is easy but low value vs ZCode's cloud positioning).

## 14. Settings — 🟡 (U1 hooks, U2 managers)

ZCode 14 sections vs VC 11 tabs. The gaps that matter for agent UX:

| ZCode section | VibeCoder today | Plan |
|---|---|---|
| Hooks (7 events, matcher/command/args/timeout/background form) | **file-only**, no editor | **U1** `hooks-ui`: full editor UI over `.vibecoder/hooks.json` (new HooksConfigStore) |
| Skills manager (list/filter/enable/import, per-skill diagnostics) | no UI (tool toggle only) | **U2** `settings-managers`: list from discovery API, enable + import/copy into project & user roots |
| Subagents (user/built-in/plugin; form: prompt, model, color, tools, maxTurns) | no UI (`.md` agents supported in harness incl. new profile frontmatter) | **U2**: list + editor writing `.md` agent files (harness parses them) |
| Commands (.md command form: name/prompt/description/arg hint + import) | custom `.md` commands work in harness; no UI | P2 (same store pattern as subagents) |
| MCP import from other tools / remote sync | richer form (HTTP/stdio/OAuth/timeouts) already; no import | P3 |
| Automations (scheduled + idle-time off-peak) | Scheduled tab ✓ (near-parity for scheduled; off-peak = cloud, skip) | keep |
| Browser / Indexing / Usage stats / plugin marketplace | n/a (local app) | P3 |

VC-only to keep: Tools tab (builtin toggles + grants), Context tab, Memory editor, Privacy
export/import.

## 15. Theme & visual identity — open decision

Dark neutrals are already near-identical (ZCode #161616/#202020/#2b2b2b vs VC
#161616/#222222/#2B2B2B). The real differences: **accent** (ZCode white-primary + terminal
blue; VC orange `#E48B46`) and **type** (ZCode system/Inter-ish; VC SF). Note:
`UI_DESIGN.md` specifies **Azure `#2563EB` + Geist** — the shipped app deliberately diverged
(orange "sampled from ZCode" per Theme.swift comment; Geist registration is a no-op).

**Open decision (user)**: keep the orange/SF identity (recommended — shipped in 1.0.x,
distinct from ZCode) and update `UI_DESIGN.md` to match code; or retheme toward the doc.

## 16. Doc drift (finding)

`UI_DESIGN.md` is stale in ~20 places (5-tab settings vs 11; per-hunk patch review vs
file-level; Plan/Safe composer toggles vs 4-mode chip; onboarding/license — retired; icon-tab
sidebar vs text-nav; 1280×800 default — never set). The code is the better source of truth
and users see it. Optional U1 task: rewrite `UI_DESIGN.md` to match shipped UI (agent owns
that file only).

---

# Implementation plan

Same orchestration contract as harness parity: parent sequences waves; children get
**exclusive file ownership**; hub files (below) have exactly **one owner per wave**.
Wave notes go to `docs/ui-parity-wip/<id>.md`. New tests: UI work → new files in `App/Tests/`
(named `<Topic>UITests.swift`); AgentCore work → `Parity<Topic>Tests.swift`.
Don't edit `Package.swift`, `App/project.yml`, or another wave's owned files.

**Hub files (1 owner per wave):** `ChatViewModel.swift` · `RootView.swift` ·
`AppViewModel.swift` · `InputBarViewV2.swift` · `ChatView.swift` · `SettingsViewV2.swift` ·
`ZCodeSidebar.swift`.

## Wave U1 — transcript & settings feel (5 parallel agents) — ✅ DONE 2026-08-16

- [x] `hl` — **Syntax highlighting.** Shipped as pure tokenizer
  `Sources/AgentCore/Diagnostics/CodeHighlighter.swift` (13 languages + aliases, single-pass)
  + `CodeBlockView.swift` rendering via Theme tokens. 12/12 tests. *Note:* ZCode's code-block
  Wrap toggle not added (P2).
- [x] `turnend` — **Turn-end change summary + Undo.** `AgentCore/Conversation/TurnChangeSummary.swift`
  (pure aggregator) + `TurnChangeSummaryView.swift` card in ChatView for completed turns;
  per-file inline Review (`CodeDiffBlock`); header **Undo** → `.turnRewindRequested` →
  existing `handleRewind()` (parent-wired observer in ChatViewModel). 7/7 tests.
  *Notes:* delete rows have no reconstructed hunks ("No diff preview"); ZCode's Safe/Unsafe
  classification dialog + Reapply badge not implemented (P2).
- [x] `permsheet` — **Permission prompt parity.** **Allow for this session** (new in-memory
  `SessionGrantStore`, conversation-keyed), Tab/←→+Enter selection, "Applies to:" prefix chip,
  kbd hint footer. Dangerous shell commands: Session also disabled (safety deviation from ZCode).
  Parent glue applied: coordinator binds `activeConversationID` on selection + clears grants
  on delete. *Open (P2):* subagent origin line — needs `originTag`/`conversationID` on
  `ShellApprovalRequest` (snippets in `docs/ui-parity-wip/permsheet.md`).
- [x] `palette` — **Command palette expansion.** 20 commands, CHAT/SAFETY/MODEL/APP section
  headers, ↑/↓ wrap-around selection + Enter-on-focused (hover sets focus), kbd hints on rows.
  Parent glue applied: `newProjectSheetRequested` notification so "New Project" opens the sheet.
- [x] `hooks-ui` — **Hooks editor in Settings.** Agent-group tab (12th); form for all 7 events
  over the exact `HookDispatcher` schema (matcher/command/args/timeout/background/enabled);
  disabled rows parked in `disabledHooks` (dispatcher runs only enabled). *Note:* user scope
  is display-only — dispatcher reads project/worktree dirs only; home-dir read snippet held in
  `docs/ui-parity-wip/hooks-ui.md` (P2 behavior change).
- [x] `docfix` — **UI_DESIGN.md rewritten** (699 lines) to the shipped 1.0.5 identity:
  orange accent + SF Pro/SF Mono, real screens (ZCodeSidebar, InputBarViewV2, 11→12-tab
  settings), U1 additions recorded in amendments log.

**U1 verification:** `swift test --filter Parity` 176/176 (all prior + new suites); full app
`xcodebuild` clean; App test suite 172/172 via xcodebuild (incl. ShellApprovalCoordinator,
CommandPaletteFilter). Live UI pass on the new build: palette opens ⌘K with CHAT/SAFETY/APP
sections + new items ("Theme: …", "Open Models") — screenshots in `ui-parity-research/shots/u1-*`;
row click executes (New Conversation created a task); Settings shows 12 tabs; Hooks tab renders
(scope radios, disabled-Add "No project open" state, ZCode footer copy). **Not verified live:**
a full agent turn (code-block highlighting, change-card render, session-grant sheet) — synthetic
keyboard input stopped reaching the second app instance; all three have unit coverage
(`ParityCodeHighlighter`/`ParityTurnChangeSummary`/`ParitySessionGrantStore`) and are flagged for
a first-run check.

**U2 verification:** `swift test --filter Parity` 176/176; `xcodebuild` Debug BUILD SUCCEEDED
(`/tmp/vc-u2/dd-final`); App suite **217/217** (172 prior + 45 new: queue 15, mentions 17,
find 7, sidebar 6). Parent glue: palette `find-in-task` → `.findInTaskRequested`; Find in Task
moved to Edit (⌘F) so AppKit does not swallow a View-menu Find. Live on the Debug build
(pid separate from `/Applications`): **Search tasks…** field + **Compress** chip render
(`docs/ui-parity-research/shots/u2-shell.png`). **Not verified live:** queue-while-running
(needs a real turn), `$`/`#` pickers, Find overlay interaction — same synthetic-input
limit as U1 with two VibeCoder copies; those surfaces are unit-covered.

## Wave U2 — session & composer mechanics (4 parallel agents) — ✅ DONE 2026-08-16

- [x] `queue` — **Queue while running.** Send while running enqueues (visible
  `ComposerQueueBar`: reorder / remove / **Steer** = InterjectionBuffer / **Run now**).
  Stop pauses the queue + **Continue**. Successful `finishRun` flushes the next item.
  Compress chip next to the context meter posts `/compact`. 15/15 tests.
- [x] `mentions` — **$skills / #sessions.** `$` skill picker (`SkillDiscovery`) and
  `#` session picker (conversation list) pin as sticky chips; `@` unchanged (emails still
  ignored). Skill/session compose via `pinHeaderText` (envelope / `read_session_context`).
  17/17 new tests; existing `@` suites still green.
- [x] `chatsearch` — **Find in task (⌘F).** Overlay on current-task messages (one hit per
  message), prev/next, count, highlight + scroll. View menu + palette `find-in-task`.
  File-changes scope held P2. 7/7 tests.
- [x] `sidebar` — **Search tasks…** in `ZCodeSidebar`: title+preview filter, clear, empty
  “No matching tasks”. 6/6 tests.

## Wave U3 — panels & chrome (3 parallel agents; RootView parent-glued) — ✅ DONE 2026-08-16

Fanned out in parallel: children owned **new files only** (statuscapsule also owned
`ChatView`). Parent glued `RootView` / `VibeCoderApp` / palette.

1. [x] `sidepane` — **Right inspector.** `.inspector` + `vibecoderInspectorPanel()`.
    Tabs **Files** (`ProjectFileIndex` + `FileTreeNode`, Reveal in Finder) and **Changes**
    (`TurnChangeSummary` + optional `CodeDiffBlock`). ⌥⌘B + palette `toggle-side-pane`.
    12/12 tests.
2. [x] `terminal` — **Bottom PTY dock.** `forkpty` login shell, minimal ANSI `NSTextView`,
    one session per cwd, Kill ≠ agent cancel. ⌘J + palette `toggle-terminal`. 9/9 tests.
3. [x] `statuscapsule` — Collapsible strip under the header: branch · dirty · turn files ·
    plan todos. Hidden when no project / not a repo. 7/7 tests.

**U3 verification:** `swift test --filter Parity` 176/176; `xcodebuild` Debug BUILD SUCCEEDED
(`/tmp/vc-u3/dd-final`); App suite **245/245** (217 U2 + 28 new). Live Debug window: inspector
Files empty-state + live zsh dock (`docs/ui-parity-research/shots/u3-shell.png`). Capsule
correctly hidden on an unbound conversation. Prefs reset after the shot so the
`/Applications` copy does not inherit open panels.

## Wave U4 — subagent pane + leftover chrome (3 parallel agents) — ✅ DONE 2026-08-16

User gap: U3 inspector had Files + Changes only; ZCode's right pane is how you
**view live/ended subagents**. Menus and Settings managers were also still missing.

1. [x] `subagents-pane` — Inspector tab **Subagents**: Running / Ended directory,
   statuses, prompt + output tail (`Latest N / M`), Kill, chat-card **Open in side pane**.
   Merges transcript `task` tools + `BackgroundJobManager`. 14/14 tests.
2. [x] `menus-chrome` — File **Open Workspace…** ⌘O / **Close Window** ⌘W;
   View **Toggle Sidebar** ⌘B / prev-next task ⌘⇧[ ⌘⇧]; header icons for
   side pane + terminal. View items merged into the system View menu (not a
   second View menu). 7/7 tests.
3. [x] `settings-managers` — Settings **Skills** (discover / enable via
   `disable-model-invocation`) and **Subagents** (user + workspace `.md` +
   read-only built-ins). 10/10 tests.

**U4 verification:** `swift test --filter Parity` 176/176; App suite **291/291**;
Debug BUILD SUCCEEDED (`/tmp/vc-u4/dd-final`). Live Debug: inspector Subagents
empty-state (`docs/ui-parity-research/shots/u4-inspector-subagents.png`);
Settings Subagents lists general-purpose / explore / plan
(`u4-settings-subagents.png`). File/View menus confirmed via Accessibility.
Prefs reset; `/Applications/VibeCoder.app` left running.

## P2 backlog (not committed)

Per-message Fork button (checkpoint-sliced) · tool-row verb copy pass ("Explore" buckets) ·
Find file-changes scope · task groups + colors + unread markers · model-trajectory row menu ·
custom-commands settings UI (`.md` form) · status capsule todos fold · model context/output
limit editor in Model & Backend tab · View zoom in/out/actual (ZCode has it; we don't).

## P3 — out of scope unless requested

In-app browser pane · mermaid/KaTeX rendering · prompt-enhance button · SSH/WSL workspaces ·
plugin marketplace UI · off-peak/idle-time tasks (cloud) · usage-stats panes (no billing in VC)
· i18n zh-CN · like/dislike feedback.

---

## Verification bar (matches harness waves)

`swift build` clean; new UI test files pass; `App/Tests` suite green (xcodebuild or
swift test where runnable); then **browser-free UI check**: run the app, exercise each new
surface (queue during a real turn, permission sheet keyboard nav, find-in-task, hooks editor
round-trip to JSON, sidepane/terminal toggle) and report what couldn't be verified.
