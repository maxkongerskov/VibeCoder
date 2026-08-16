# VibeCoder chat / conversation surface (ground truth)

Read of Swift sources under `App/` + `Sources/AgentCore/` (16 Aug 2026).  
`UI_DESIGN.md` cited as **doc**; live UI as **code**. Drift is labeled **doc says X / code does Y**.

Live host: `App/Views/ChatView.swift` in `NavigationSplitView` detail (`App/Views/RootView.swift`). Sidebar is `App/Views/Sidebar/ZCodeSidebar.swift` (not `SidebarShell.swift`, which is leftover). Transcript + composer share a fluid column (`Theme.ChatLayout.contentWidth`, soft max 1040, gutters 24–96).

---

## 1. Conversation list

| Feature | VibeCoder behavior | UI detail | Evidence |
|---|---|---|---|
| Location | Left sidebar of main window, not a separate window | `ZCodeSidebar` in split column min 240 / ideal 280 / max 360 | `RootView.swift` 96–131 |
| Sidebar chrome | Workspace header (folder icon + name + path + chevron) → primary nav → Tasks section → footer | Workspace tap → Projects tab | `ZCodeSidebar.swift` 95–227, 351–394 |
| Primary nav | Chat, Projects, Models (count badge), Notes, Scheduled | 12–12.5pt rows; selected = `Theme.Palette.hover` fill, no accent leading bar | `SidebarShell.swift` 17–54; `ZCodeSidebar.swift` 305–343 |
| Tasks section | Disclosure “TASKS” + “+ New Task” (accent) | Collapses via `@AppStorage("sidebarRecentsCollapsed")` | `ZCodeSidebar.swift` 118–141 |
| Empty list | Centered caption **“No tasks yet”** (12pt tertiary) | **doc says** “No conversations yet. ⌘N to start one.” / **code** is “No tasks yet” with no ⌘N hint | `ZCodeSidebar.swift` 150–158; `UI_DESIGN.md` §4.6 |
| New task | Immediately creates + selects a conversation; switches to Chat | Toolbar `square.and.pencil` also creates (⌘N on File menu, not toolbar shortcut) | `RootView.swift` 103–106, 134–144, 353–356 |
| Zero conversations in pane | `NewTaskLandingViewV2`: outline mark, **“Start a new task”**, **“Click the button below to begin. Your new task will appear in Recents.”**, circular +, Return hint | Sidebar New Task does **not** land here — it creates first | `NewTaskLandingViewV2.swift` 52–67; `RootView.swift` 533–548 |
| Row contents | Status slot (6pt) + title (1 line) + preview (1 line, 72 chars + “…”) + relative time | Title empty → **“Untitled”**. Preview = last visible assistant (chrome-stripped) else last user | `ZCodeSidebar.swift` 398–618, 623–638 |
| Relative time | `now` / `Nm` / `Nh` / `yday` / `Nd` / `MMM d` | Top-right 10pt tertiary | `ZCodeSidebar.swift` 640–649 |
| Status badge | Running = 6pt green glow dot; error = warning triangle; idle = empty 6pt | Running from `ChatViewModel.isRunning`; error if `statusLine` contains `"error"` | `ZCodeSidebar.swift` 514–536, 566–582; `RootView.swift` 122–127 |
| Selection | Tap selects ID; if not on a workspace tab, switches to Chat | Selected / hover = rounded 8pt `hover` fill. **doc says** `accent.subtle` + 3pt accent leading bar / **code** is hover fill, no leading bar | `ZCodeSidebar.swift` 401–434, 557–618; `UI_DESIGN.md` §3.11 |
| Time groups (unpinned) | Today, Yesterday, Past 7 days, Past 30 days, Older | Pinned in separate “Pinned” disclosure | `ZCodeSidebar.swift` 160–184, 720–750 |
| Context menu | Move to project · Pin/Unpin · Rename · Archive · Delete · Move down | No Duplicate / Fork / Search / Export in list | `ZCodeSidebar.swift` 438–465 |
| Rename | Inline TextField (Return commit, Esc cancel, focus-loss commit, select-all) | Header title uses a **sheet** instead (`RenameConversationSheet`) | `ZCodeSidebar.swift` 406–418, 660–708; `RenameConversationSheet.swift` 17–50 |
| Delete | Context menu Delete; footer **“Delete all”** → alert **“Delete all tasks?”** / **Delete All** | Selected-delete reselects first non-archived | `ZCodeSidebar.swift` 199–214; `ConversationCoordinator.swift` 112–122 |
| Archive | Sets `archived`; row hidden from sidebar; selection jumps to next visible | No archive list in sidebar | `ConversationCoordinator.swift` 154–163 |
| Pin | Toggles `pinned`; pinned group above time groups | Move-down cannot cross pin partition | `ConversationCoordinator.swift` 145–173 |
| Unloadable JSON | Banner **“N conversation(s) couldn't be loaded”** + **Show in Finder** | Opens Finder on bad files | `ZCodeSidebar.swift` 232–267 |
| Search / fork in list | **No** sidebar search. Fork = `/fork` or header **Duplicate** (title + ` (copy)`) | `ConversationSearch` is agent tool (`read_session_context`), not a list UI | `ConversationSearch.swift` 1–13; `ChatViewModel.swift` 2227–2232 |
| Header extras | Title popover: Rename, Duplicate, Export as Markdown, Copy as Markdown, Remote control…, Isolate work in git worktree (checkmark), Delete | Header is title only (`slimChrome`); **doc** header has model chip + project + safe toggle | `ChatTitleDropdown.swift` 27–64; `ChatHeaderView.swift` 57–80, 105–178; `UI_DESIGN.md` §4.2 |

---

## 2. Composer / input bar

| Feature | VibeCoder behavior | UI detail | Evidence |
|---|---|---|---|
| Host | `MentionAwareComposer` → `InputBarViewV2` | Fluid card, 18pt radius, `subtle` fill + shadow; drop-target hairline | `ChatView.swift` 325–344; `InputBarViewV2.swift` 387–563 |
| Input control | SwiftUI `TextField(..., axis: .vertical)` — **not** `TextEditor` | **doc says** TextEditor, min 56 / max 200 / placeholder “Ask the agent…” / **code** TextField, min editor 36 / max 100 / max 6 lines, card min 76 | `InputBarViewV2.swift` 395–407; `Theme.swift` 183–200; `UI_DESIGN.md` §3.10 |
| Placeholder | Idle: **“Ask for follow-up changes”**. Running: **“Keep typing to queue a follow-up…”**. No “Pick a model to start.” in the field | Empty-chat guidance is the hero, not the field | `InputBarViewV2.swift` 395–397; `ChatView.swift` 476–495; `UI_DESIGN.md` §5.3 |
| Keys | Return send; Shift+Return newline; ↑/↓ prompt history (or slash/mention nav); Esc clears slash draft | History is persisted across conversations | `InputBarViewV2.swift` 409–448, 342–377 |
| Send (idle) | 32pt circle, `arrow.up`; accent fill if draft non-empty, else muted + disabled | Help: “Send message”; a11y **Send** | `InputBarViewV2.swift` 818–836 |
| Stop (running) | Red circle `stop.fill` (a11y **Stop**, Esc shortcut, help “Stop generation”) | If draft also non-empty: extra accent **Send interjection** circle | `InputBarViewV2.swift` 778–816 |
| Attach | `plus` 26×26 → NSOpenPanel **“Attach files or folders”** / **Attach**; drag-drop on card | Chips are one-shot (`ContextAttachment`); images for vision | `InputBarViewV2.swift` 463–472, 635–701 |
| @ mentions | Token `@` after start/whitespace; searches files (≤8), folders (≤6), symbols if query ≥2 chars (≤6); max 14 | Popup header **“@ context — ↑/↓ Enter pin · Esc dismiss”**; rows: icon, name, kind badge (file/folder/symbol), subtitle path | `MentionSearchCoordinator.swift` 92–214; `MentionAwareComposer.swift` 233–325 |
| Mention result | Enter/click **pins** (`StickyContextPin` re-injected every turn) + file/symbol also one-shot attach; strips `@token` | Sticky chip: pin + icon + name + ×; one-shot: doc + name + size + × | `MentionAwareComposer.swift` 165–224, 303–327 |
| Slash autocomplete | `/` draft → upward menu of commands (name + arg hint + description); Enter/Tab insert | 30+ commands: `/new` `/clear` `/compact` `/fork` `/rewind` `/undo` `/export` `/model` `/effort` `/plan` `/approve-plan` `/stay-plan` `/goal` `/remember` `/skill` `/settings` … | `InputBarViewV2.swift` 565–629; `SlashCommandService.swift` 57–218 |
| Execution mode | Chip + upward popup **“Agent mode”**, not segmented chips | Disabled while running; ⇧Tab cycles Plan → Ask → Auto → Full | `ExecutionModeChip.swift` 25–91; `ChatView.swift` 243–248 |
| Four modes | Chip short: **Plan / Ask / Auto / Full**. Menu: **Plan mode** / **Ask before changes** / **Edit automatically** / **Full access** + descriptions | Icons: `doc.text.magnifyingglass` / `shield.lefthalf.filled` / `pencil.and.ruler` / `bolt.fill`. Quiet secondary; accent only while menu open (**not** per-mode fills — code comment vs `accentHint`) | `ExecutionMode.swift` 26–84, 176–198; `ExecutionModeChip.swift` 13–47 |
| Mode semantics (UI-visible) | Plan = read-only + plan prompt; Ask = Safe Mode + patch-review sheet; Auto = edits auto, shell/MCP still approved; Full = fewer confirmations | Plan/Ask enable Safe Mode; only Ask enables patch review | `ExecutionMode.swift` 98–136 |
| **doc Plan / Safe Mode** | **doc** `[⌘ Plan] [⌘ Safe Mode]` under editor / **code** Plan is first execution-mode row; Safe Mode is not a composer toggle (mapped from mode) | Header Safe/Headless pills exist in `ChatHeaderView` state but slim header does not show them | `UI_DESIGN.md` §3.10; `ChatHeaderView.swift` 57–80 |
| Web search | Globe icon toggle; accent when on | Binds `settings.toolEnabled["web_search"]` | `InputBarViewV2.swift` 156–165, 714–733 |
| Chat vs Agent | Capsule **Chat** (`bubble.left.and.bubble.right`) or **Agent** (`wrench.and.screwdriver`) | Chat = `rawMode` (no harness; web + read_file only) | `InputBarViewV2.swift` 167–174, 736–773 |
| Context meter | Mini 28×5 capsule + `12.3k / 128k · 10%` (or **compact**) | Hover → upward `ContextBreakdownHoverCard` (used/window, categories, tokens until auto-compact). Color: accent / yellow >60% budget / orange >85% | `InputBarViewV2.swift` 184–298; `ContextBreakdownSheet.swift` 12–24 |
| Thinking | Shown only if `ThinkingCapability` from model-id scan | Chip: `brain.head.profile` + **Off/Low/Medium/High/Max** + chevron; popup uses capability’s levels only | `ThinkingEffortPicker.swift` 25–107; `ThinkingCapability.swift` 29–57 |
| Model picker | Trailing chip: pretty name or **“No model”** / **“Select model”** + chevron | Upward searchable menu: Active · backend, other live backends, **Recognized catalog (not loaded)**; Load/Unload when supported | `ModelPickerButton.swift` 60–187, 190–267 |
| ModelSelectorViewModel | Probes backends, dedupes, MLX load state, tools-unsupported cache | **Not** the visible chip (that is `ModelPickerButton` + `AppViewModel.selectedModelID`) | `ModelSelectorViewModel.swift` 60–210 |
| Two-model | If orchestration on: read-only pill `orch → worker` instead of picker | Pending bubble can show same caption | `InputBarViewV2.swift` 119–137, 505–509 |
| Plan/Safe in composer | **doc** left toggles + primary Send ↑ / **code** left = + · mode · web · Chat/Agent · meter; right = think · model · send/stop | Send is circular icon, not labeled “Send ↑” | `InputBarViewV2.swift` 461–517; `UI_DESIGN.md` §3.10 |

---

## 3. Message rendering

| Feature | VibeCoder behavior | UI detail | Evidence |
|---|---|---|---|
| User | Right-aligned pill, wrap cap **560pt**, leading gutter 96 | Fill `Theme.Palette.bubbleUser` (6% black/white), 16pt radius, 14/10 pad, plain `Text` (no markdown), selection on | `MessageBubbleViewV2.swift` 60–96, 280–311; `Theme.swift` 50–52 |
| **doc user bubble** | **doc** max 75% width, `accent.subtle`, 12pt pad, 12pt radius / **code** 560pt, neutral 6% fill, 16pt radius | | `UI_DESIGN.md` §3.5 |
| Assistant | Left, full column, **no bubble** | Chronological run: thought → tools → prose per iteration; consecutive assistant messages grouped into one turn | `MessageBubbleViewV2.swift` 99–207; `ChatView.swift` 505–578 |
| Markdown engine | Custom line scanner + `AttributedString(markdown: .inlineOnlyPreservingWhitespace)` | **No** third-party Markdown lib. Blocks: h1–6, p, fenced code, ul/ol, tables, blockquote, hr. Inline: bold/italic/links/code | `MarkdownTextView.swift` 1–19, 41–175 |
| Code blocks | Header: LANG + **Copy** / **Copied**; body horizontally scrollable mono `Text` | **No syntax highlighting** in chat code blocks | `CodeBlockView.swift` 21–79 |
| Diff highlighter | `DiffSyntaxHighlighter`: +/- colors + crude Swift keywords/strings | Used by `ArtifactDiffView`, **not** by chat `CodeBlockView` or patch-review rows | `ArtifactDiffView.swift` 23–80 |
| Copy | Hover-visible **Copy** chip under user (trailing) and final assistant answer (leading) | Writes NSPasteboard; 1.4s “Copied” | `MessageBubbleViewV2.swift` 84–88, 264–275, 348–386 |
| Streaming | `PendingAssistantBubble` while `isRunning`; last persisted assistant twin hidden | Order: live **Working for Ns** (ShimmerText) → optional orch caption → reasoning → activity/edits → streamed answer | `ChatView.swift` 581–615, 626–631, 763–765; `PendingAssistantBubble.swift` 148–180 |
| Idle waiting | Default **“Thinking…”**; optional playful phrase cycle 4.2s if `playfulWaitingLabels` and no tools | `ShimmerText` on thinking/working labels | `PendingAssistantBubble.swift` 70–107; `ShimmerText.swift` 10–40 |
| Reasoning | `ReasoningBlockView`: brain + **Thinking · Ns** / **Thought for Ns** / **Thought** | Streaming expands; after tools/answer `preferCollapsed`. Body = 2pt rail + 12.5pt secondary selectable text (not markdown) | `ReasoningBlockView.swift` 63–144 |
| Work duration | Header **Working for …** / **Worked for …** + hairline | Seconds until 60s then whole minutes (`WorkDurationFormat`) | `WorkingHeader.swift` 17–38 |
| Empty transcript | `EmptyChatBrandHero` outline mark + title/subtitle | Titles: **“Connect a model server”** / **“Pick a model to start”** / **“What are we working on?”** + loopback “Detected on this Mac” / **Use** / **Open Connection settings** | `ChatView.swift` 419–495, 716–741; `BrandMarkOutline.swift` 30–101 |
| **doc empty** | **doc** only “What are we working on?” 24pt, no buttons / **code** 20pt semibold + subtitle + detect/settings | | `UI_DESIGN.md` §5.2 |
| Stick-to-bottom | Pin follows stream; trackpad up detaches; new user turn re-pins | User last → scroll to **top** of pill | `ChatView.swift` 25–28, 793–854 |
| Model chrome | `cleanModelChrome` strips think tags / channel noise | Sidebar preview uses same strip | `MessageBubbleViewV2.swift` 214–228 |
| Two-model handoff | Collapsed **“Orchestrator plan · handed to worker”** under that user message | Expandable brief | `ChatView.swift` 665–669, 1048–1105 |

---

## 4. Tool-call rendering

| Feature | VibeCoder behavior | UI detail | Evidence |
|---|---|---|---|
| Live path | Partition: edit tools → `InlineEditCardView`; rest → `ZCodeActivityStack` | `ToolCallView` / `ThoughtProcessBlock` / `StepperRailSpec` compiled but **unused** in transcript | `MessageBubbleViewV2.swift` 231–252; `InlineEditCardView.swift` 177–218; `ToolCallView.swift` 1084–1087 |
| **doc ToolStub** | **doc** `→ toolName  args≤60` accent arrow / **code** `Verb · Status` activity rows (13pt) | Status: Queued… / ArtifactLabel / Failed / “1 file” etc. | `UI_DESIGN.md` §3.6; `ZCodeActivityLineView.swift` 41–77, 207–253 |
| Grouping | Consecutive non-edit tools collapse under **“Tools · {summary}”** | Auto-expand while running/streaming; history collapsed; chevron right/down | `ZCodeActivityLineView.swift` 285–396 |
| Collapsed summary | Running: `N · M running`. Failures: `N · M failed`. Else semantic verbs or `N completed` | | `ZCodeActivityLineView.swift` 399–416 |
| Expand I/O | Input/Output mono; 600/800 char cap + **Show full I/O** | `list_directory` → `DirectoryListingTableView` | `ZCodeActivityLineView.swift` 87–114 |
| Subagent (`task`) | `[shippingbox] SubAgent  {type}  ·  {desc}` (type uses `subagentType` color) | Running: mini ProgressView + **Kill** | `ZCodeActivityLineView.swift` 127–180 |
| Edit cards | Path · status/Undone · +N −M · chevron; expand → `CodeDiffBlock` | Auto-open if running or has removals. Undo when `hunk_id` present | `InlineEditCardView.swift` 15–122 |
| Inline diffs | Tinted rows, 3pt accent bar, `+`/`−`, Show N more lines (cap 40 in chat) | **No** Tree-sitter / `DiffSyntaxHighlighter` here | `CodeDiffViews.swift` 12–76 |
| Shell in unused ToolCallView | Terminal `$` command + `exit N` badge + 12-line OutputBlock | Not on live activity rows (those show raw I/O) | `ToolCallView.swift` 112–123, 285–393 |
| Errors | Activity status **Failed**; edit card `xmark.circle.fill` + error label | Stack header counts failures | `ZCodeActivityLineView.swift` 56–58, 47–54 |
| In-chat terminal | **No** interactive terminal. Background **shell** jobs: banner **Background shell** + command + **Kill** | Subagents are in-transcript, not banner | `GoalStatusBanner.swift` 94–158 |
| Stepper rail | Geometry helper only; comment: ThoughtProcessBlock superseded | | `StepperRailSpec.swift` 1–34 |

---

## 5. Diff / patch review

| Feature | VibeCoder behavior | UI detail | Evidence |
|---|---|---|---|
| Trigger | Ask mode (`ExecutionMode.build`) + `apply_patch` → `PatchReviewCoordinator.pendingBatch` sheet | Esc/dismiss = reject all (fail-closed) | `ChatView.swift` 160–174, 986–1043; `ExecutionMode.swift` 117–126 |
| Sheet | Title **“Review patch”**; **Reject all** / **Accept all** | Status: `N files · M hunks (read-only) · K of N files decided` | `PatchReviewSheetV2.swift` 1–19, 217–270 |
| Decision grain | **Per file** Accept/Reject (toggle back to pending) | **doc** per-hunk Accept/Reject + ⌘A/⌘R / Y/N / **code** file-level only; hunks display-only | `PatchReviewSheetV2.swift` 5–19, 357–369; `UI_DESIGN.md` §3.8, §4.4 |
| Hunk view | Header `@@ … @@` on `accentSubtle`; unified +/−/context tints 10% | Mono 12pt; no line numbers; no syntax highlight (**code comment:** deferred v1.1) | `PatchReviewSheetV2.swift` 385–440 |
| Apply | **Apply selected** (disabled if 0 accepted) + optional **Always allow folder** | Footer: **Cancel**; “N files will be applied” | `PatchReviewSheetV2.swift` 468–504 |
| Always allow folder | Remembers common directory via `RememberedGrants` then applies | | `ChatView.swift` 1021–1040 |
| Size | min 760×540 | **doc** 880×640 | `PatchReviewSheetV2.swift` 207; `UI_DESIGN.md` §4.4 |
| Worktree review | Header worktree toggle **on** → enable; **off tap** → sheet of `git status`/`diff` | 720×600; **Worktree review** + branch mono; Expand/Collapse all | `ChatView.swift` 396–410; `WorktreeReviewSheet.swift` 140–218 |
| Worktree files | Kind icon + path + new/deleted/modified pill + +N −M; expand inline diff | Same +/− tints, no syntax highlight | `WorktreeReviewSheet.swift` 252–394 |
| Worktree actions | Commit field **“Commit message…”**; **Continue** (dismiss); **Discard** (confirm); **Merge into main** (⌘↩, confirm) | **doc** Discard / Continue working / Merge into main | `WorktreeReviewSheet.swift` 396–474; `UI_DESIGN.md` §4.5 |
| Worktree errors | Alert **“Worktree error”** / OK | | `ChatView.swift` 142–159 |

---

## 6. Plan mode

| Feature | VibeCoder behavior | UI detail | Evidence |
|---|---|---|---|
| Surface | Floating top-trailing card (max 320, min 200), not in-transcript PlanCard | ✕ hides until plan identity (goal+todo statuses) changes | `ChatView.swift` 356–391; `StickyPlannerView.swift` 27–115 |
| Card body | `PlanCardView`: STEPS/COMPLETE + 70pt progress + `done/total` + goal + todo rows | Icons: pending circle, in-progress spinner (or dotted if interactive), done check, failed x, skipped minus | `PlanCardView.swift` 16–173 |
| **doc PlanCard** | **doc** disclosure “Plan” + step count, pulse in-progress / **code** floating overlay; in-progress is spinner, not pulsing row | | `UI_DESIGN.md` §3.7 |
| Live when | Plan has todos AND (running OR not complete OR needs approval) | Hydrated from `PlanStore` + transcript `create_plan`/`update_todo` | `ChatViewModel.swift` 459–507 |
| Approval chrome | Shown when `executionMode == .plan` && todos nonempty && !running | Copy: **“Review checklist, then Approve to implement (Ask mode) or Stay in Plan.”** Buttons **Stay in Plan** / **Approve & Run** | `StickyPlannerView.swift` 147–174; `ChatViewModel.swift` 458–463 |
| Approve | Sets mode **Ask** (`build`), sends implement prompt with goal+steps, expects review sheets | Status: **“Plan approved — continuing in Ask mode…”** | `ChatViewModel.swift` 534–566 |
| Stay | Forces Plan mode; **“Staying in Plan mode — revise the plan or Approve when ready.”** | No auto-run | `ChatViewModel.swift` 569–574 |
| Toggle todos | Only while approval chrome shown; done↔pending, result “Reviewed” | | `ChatViewModel.swift` 509–531 |
| Slash | `/plan` enter Plan; `/approve-plan` / `/approve`; `/stay-plan` / `/reject-plan`; `/view-plan` | | `SlashCommandService.swift` 136–155 |

---

## 7. Permission & user-question prompts

| Feature | VibeCoder behavior | UI detail | Evidence |
|---|---|---|---|
| Shell / MCP / task | Modal **sheet** (`ShellApprovalSheetMount`) | Titles: **Allow shell command?** / **Dangerous command** / **Allow MCP tool?** / **Allow subagent?** / **Allow {tool}?** | `ShellApprovalSheet.swift` 20–33; `ChatView.swift` 175–177, 962–975 |
| Body | `reason` + scrollable mono `detail` (command) | Dangerous: warning icon + **“Dangerous commands are never remembered — Always acts as Once.”** | `ShellApprovalSheet.swift` 35–73 |
| Buttons | Primary **Once** / **Always**; secondary **Never** / **Deny** | Always/Never disabled for dangerous. Dismiss/Esc → deny + drain | `ShellApprovalSheet.swift` 75–128 |
| Once vs Always | Once = this call; Always/Never persist for project (help: “remember for this project”) | Ask/Auto still prompt execute tools; Full fewer prompts | `ShellApprovalSheet.swift` 87–117 |
| `ask_user` | **Inline card above composer** (not alert) | Question 16pt; option capsules; field **“Type your answer…”** / **“Or type a custom answer…”** + send circle | `QuestionCardView.swift` 9–125; `ChatView.swift` 311–316 |
| Queue | FIFO; badge **“N more question(s) waiting”** | Empty submit not used as dismiss-for-others | `UserQuestionCoordinator.swift` 20–72 |
| Permissions sheet | `PermissionsSheetView` (Safe/Headless + allow-lists) exists | **Not mounted** by slim `ChatHeaderView` (orphan compiled view) | `PermissionsSheetView.swift` 16–66; `ChatHeaderView.swift` 74–80 |

---

## 8. Status surfaces

| Feature | VibeCoder behavior | UI detail | Evidence |
|---|---|---|---|
| Context | Composer meter + hover breakdown (window vs auto-compact budget) | Header context chip **hidden** (`slimChrome`) | `InputBarViewV2.swift` 218–250; `ChatHeaderView.swift` 57–59 |
| Working | Transcript `WorkingHeader` + reasoning/tools | `EngineLoadBar` is **0-height placeholder** | `PendingAssistantBubble.swift` 21–30, 148–153 |
| Docked bars | `ProcessingStatusBar` / `ZCodeStatusBar` compiled (model · mode · tokens · status · **Steering**) | **Not** in `ChatView` body. Comment: redundant vs transcript | `ChatView.swift` 305–320; `ZCodeStatusBar.swift` 12–76 |
| `statusLine` | Still updated (hooks, interjection, export, plan, cancel) | `humanStatus` hides “Iteration N…” → **“Working…”**; cap → **“Stopped — turn limit reached”** | `ChatStatusSurfacesTests.swift` 14–57; `ChatViewModel.swift` 1142–1144 |
| Goal | Top banner from `goalStatusText` + description | Icons/colors from copy (stall / premature / paused) | `GoalStatusBanner.swift` 13–89; `ChatView.swift` 284–291 |
| Notices | `TranscriptNoticeCard` in transcript (compaction, goal, bg job, build verify) | Dismiss × | `GoalStatusBanner.swift` 198–262 |
| Model load error | Red banner under header, dismiss × | | `ChatView.swift` 259–282 |
| Cost | **No** token-cost / $ display in chat UI | Duration is wall-clock Working/Thought only | `WorkingHeader.swift`; `ReasoningBlockView.swift` 48–61 |

---

## 9. Interrupts

| Feature | VibeCoder behavior | UI detail | Evidence |
|---|---|---|---|
| Stop | Red stop in composer; also `.cancelAgentRequested` on selected chat | `cancel()` sets **“Cancelling…”**, clears interjections, deny-drains approvals, rejectAll patch, `runTask?.cancel()` | `InputBarViewV2.swift` 791–802; `ChatViewModel.swift` 1138–1157; `RootView.swift` 308–311 |
| After stop | `TurnEndedByUserLabel` under assistant (`userStopped` notice) | | `ChatView.swift` 767–775; `GoalStatusBanner.swift` 267–286 |
| Mid-turn send | **Interjection**, not a queued next user turn | Status: **“Interjection sent — applied on next step.”** / **“N interjections pending…”** | `ChatViewModel.swift` 607–658 |
| **doc queue** | **doc** “queue next message” while running / **code** placeholder says queue; send applies as mid-turn steer via `InterjectionBuffer` | Composer stays editable | `UI_DESIGN.md` §5.3; `InputBarViewV2.swift` 396, 778–815 |
| Cancel drop | Interjections discarded so they do not hit the next turn | | `ChatViewModel.swift` 1145–1152, 1191–1199 |

---

## 10. Conversation management extras

| Feature | VibeCoder behavior | UI detail | Evidence |
|---|---|---|---|
| Export | Title **Export as Markdown** or `/export` or notification | `NSSavePanel` title **“Export conversation as Markdown”**; suggested `{title}.md` | `ChatView.swift` 935–955; `ConversationMarkdownExport.swift` 90–98 |
| Copy markdown | Title **Copy as Markdown**; clipboard + status byte count | Renderer: `# title`, export meta, `## User/Assistant/Tool`, reasoning, streaming | `ChatView.swift` 927–933; `ConversationMarkdownExport.swift` 18–87 |
| Conversation search UI | **None** in sidebar or chat. ⌘K is **“Search commands…”** only | Agent-side `ConversationSearch` / `read_session_context` | `CommandPaletteView.swift` 32; `ConversationSearch.swift` 1–13 |
| Fork | `/fork` → `duplicateConversation` (history kept, title ` (copy)`, no worktree) | Header **Duplicate** same path | `ChatViewModel.swift` 2227–2232; `ConversationListViewModel.swift` 127–157 |
| Empty states | Sidebar: **No tasks yet**. Chat: hero titles above. New-task landing when no convos | **doc** Geist 24pt “What are we working on?” only | `ZCodeSidebar.swift` 150–157; `ChatView.swift` 476–495 |
| Typography / color vs doc | **doc** Geist Sans/Mono + Azure `#2563EB` / **code** `.system` fonts; dark canvas `#161616`; Theme comment: orange Full-access accent | | `UI_DESIGN.md` §2.1–2.3; `Theme.swift` 1–38; `MarkdownTextView.swift` 17–18 |

---

## Dead / leftover chat chrome (compiled, not in live tree)

| Piece | Status | Evidence |
|---|---|---|
| `ToolCallView` / `ThoughtProcessBlock` / `StepperRailSpec` | Unused by transcript | `ToolCallView.swift` 1084+ |
| `ProcessingStatusBar`, `ZCodeStatusBar`, `ChatView.statusPill` | Defined; not composed | `ChatView.swift` 318–320, 459–474 |
| `PermissionsSheetView` | No presenter | grep: only self + pbxproj |
| `SidebarShell` | Replaced by `ZCodeSidebar` | `RootView.swift` 90–97 |
| `ModelSelectorViewModel` | Backend probe VM; chip is `ModelPickerButton` | `ModelSelectorViewModel.swift` 1–10 |

---

## Highest-impact doc/code drifts (chat only)

1. **InputBar** — TextField not TextEditor; placeholder “Ask for follow-up changes” not “Ask the agent…”; Plan/Safe row replaced by 4-mode chip + Chat/Agent + web + think + model.  
2. **User bubble** — Neutral 6% pill, 560pt, 16pt radius — not 75% `accent.subtle` 12pt.  
3. **Tools** — Grouped `Verb · Status` + edit cards, not ToolStub + disclosure result cards with tool-call IDs.  
4. **Plan** — Floating overlay + Approve & Run / Stay in Plan, not inline PlanCard.  
5. **Patch** — File Accept/Reject + Apply selected, not per-hunk Y/N.  
6. **Status** — In-transcript Working/Thought; docked iteration status line not mounted.  
7. **Running send** — Interjection, not next-turn queue.  
8. **List** — “Tasks” rows (title + 1-line preview + time + pin/archive), empty “No tasks yet”, no snippet-2-line / accent bar from §3.11.
