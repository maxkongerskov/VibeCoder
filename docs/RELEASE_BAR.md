# Daily-driver bar (VibeCoder)

What **99%** means for a **BYO OpenAI-compatible HTTP** local agent. Not a hobby demo.

Ada owns this file. Lin/Pixel/Rigel raise the numbers with **evidence**, not vibes. Do not claim 99% without the proof column filled.

**Today (2026-08-22): not 99% daily-driver.** F4 is live in-app Unsloth first chat (Reed, this Mac; “Hey”) — filled cells still ≠ 99%. GitHub unpushed. GHA `SKIP_APP_TESTS=1`. A1/A2 and Connection Test still not live.

---

## Max-approved decisions (do not reopen this cut)

| Date | Decision |
|------|----------|
| 2026-08-20 | **BYO HTTP forever (v1):** LM Studio / oMLX / Ollama / Unsloth Studio / EXO / custom `/v1`. No mlx-swift. No bundled llama.cpp. MIT. No Sparkle. No Sentry. No license key. |
| 2026-08-20 | **Local API:** default = loopback proxy `tools: []`. Opt-in = bounded AgentLoop (cap 8) on the **bound project** — not schemas-only, not in-app worktree/review/MCP. |
| 2026-08-20 | **Remote control OFF** — not password-gated, not shipping. |
| 2026-08-20 | **Worktree default:** binding a **git** project enables isolation. Escape hatch: edit main tree. Merge/discard stay **user-driven**. |
| 2026-08-20 | **Non-goals:** mlx, llama restore, ZCode leftover chrome (mermaid / queue Edit / `node_repl`), SQLite session rewrite, onboarding wizard, App Sandbox entitlements. |

---

## 99% — explicit meaning

A daily-driver is 99% when **all** of the following are true **and** Rigel has written evidence (command + result, or eval id + pass). Partial UI is not enough. Filled cells below are **not** that bar yet — F4 live Unsloth first chat ≠ 99%; 012/013 still mock.

### First-run

| # | Bar | Evidence |
|---|-----|----------|
| F1 | Cold launch, **no** wizard, lands on main UI | **Unit, not launched:** `VibeCoderApp` force-sets `hasCompletedOnboarding`. `WorkspaceChatRouting` wait→seed→showChat — `MenuChromeUITests.testWorkspaceRouting*` (characterization, not XCUI; GHA `SKIP_APP_TESTS=1`). Historical class 10/10 (2026-08-20) is stale — Cluster nav tests now sit in this class (e72a114). No screenshot. |
| F2 | Server **down** → empty chat tells the user to start a local server (all live HTTP backends named, including Unsloth) and Send is not a silent no-op | **Unit:** `SettingsDiscoverabilityCopyTests.testEmptyChatCopyListsUnslothOnNoBackend` (LM Studio/Ollama/oMLX/Unsloth) + `testComposerSendDisabledUntilModelUnlessRunning` pass. `BugHuntViewModelsTests.testEnsureFirstConversationWaitsForStoreThenSeedsOnce` pass. App not launched. |
| F3 | Server **up**, no model → pick a model (composer chip / Connection Test) | **Copy only:** same EmptyChatCopy test → title `"Pick a model to start"`. No live server. |
| F4 | Server up + model selected → first user turn streams tokens | **Live in-app first chat (2026-08-22), Unsloth Studio.** One user turn “Hey”; tokens in the Mac app window. Witness: Reed (tech lead) during Max’s session. **Not** mock-worker 012/013, **not** eval-runner, **not** CLI. 012/013 stay mock scripted cells (A1/A2 only). B1 Connection Test still not live. F4 alone is not 99%. |

### Local backends

| # | Bar | Evidence |
|---|-----|----------|
| B1 | Settings → Connection → Test succeeds against at least **LM Studio or Ollama** on loopback | **PASS in source (Ada 2026-08-20), not live.** `testLMStudio` / `testOllama` call `LMStudioBackend` / `OllamaBackend.listModels()` then `ingestConnectionTestModels`; `.success(modelCount:)` or `.failure(error)`. No LM Studio/Ollama on this machine. |
| B2 | Model list is the **server’s** list, not a fake catalog | **PASS in source.** `refreshModels` / Test set `availableModels` from `backend.listModels()` (LM Studio native `/api/v1/models` then `/v1`; Ollama `/api/ps` then `/v1/models`). Not `ModelCatalog`. |
| B3 | Unsloth / oMLX / EXO: honest skip if the server is absent; no crash; no “bundled engine” copy | **PASS in source.** `testUnsloth` / `testOMLX` catch → `.failure`; EXO `connect()` catch → `"Can't connect to EXO at host:port — …"`; `refreshModels` catch → `availableModels = []` + `modelListError`. Connection chips are HTTP only (no mlx/llama pane). |
| B4 | Custom `/v1` accepts a user URL; remote URL is **allowed** and must not be marketed as “nothing leaves your Mac” | LEGAL already says this |

### Agent loop (in-app chat)

| # | Bar | Evidence |
|---|-----|----------|
| A1 | One turn: model → tool call → tool result → model continues | **Mock-worker 012 (3487777), not live-backend / not in-app.** First-chat is **F4**, not A1/A2. In-tree `Evals/support/scripts/012-write-file.json`; Nash `ci-pr.sh` (T0 then 012). Artifact `Evals/results/2026-08-20-091027-mock-mock-worker.json` (1 `write_file`). Historical `SKIP_UNIT=1 SKIP_APP_TESTS=1` local `ci-pr.sh` is eval-only — does not prove the SwiftUI turn. |
| A2 | `edit_file` / `apply_patch` changes a file the user can open | **Mock-worker 013 (3487777), not live-backend / not in-app.** First-chat is **F4**, not A1/A2. In-tree `Evals/support/scripts/013-apply-patch.json`; Nash `ci-pr.sh`. Artifact `Evals/results/2026-08-20-091614-mock-mock-worker.json` (2 tools: `read_file`+`apply_patch`). Historical `SKIP_APP_TESTS=1` local runs are eval-only. |
| A3 | `verifyEdits` default on: BuildGuard skip (no build system) or pass/fail inject, no hang | **PASS (Ada 2026-08-20).** `AppSettings.verifyEdits` default true; `AgentRunBootstrap` passes it through. Skip: `BuildGuardVerifyEditsTests.testVerifyNoBuildSystemInEmptyDir`. Fail inject: `AgentLoopFixesTests.testBuildGuardFailureProducesSingleTranscriptMessage` (broken Package.swift → one user-role BuildGuard reminder). Wire-only not in transcript. No live xcodebuild hang test. |
| A4 | Cancel (⌘.) returns a persistable partial turn (no dangling `tool_calls`) | **PASS-with-unit (Ada 2026-08-20, same bar as F4).** `AgentLoopCancelPersistTests.testCancelMidToolPersistsPairedTranscript`: cancel while a mutator hangs; `ConversationStore.save` then `load`; `toolCallPairingIsValid`; no unclosed ids; hang + leftover `list_directory` both have tool results. Same store as ChatViewModel. Not in-app ⌘. |
| A5 | Safe/Ask/Plan modes still fail closed (no YOLO-by-default) | existing executionMode default `.build` |

### Worktree isolation (contract: ARCHITECTURE §11.2)

| # | Bar | Evidence |
|---|-----|----------|
| W1 | Bind a **git** folder → conversation gets `worktreeBranch`; mutations land in `<project>-agentcore-<id>` | **Pass (2026-08-20):** `W13PathWorktreeGitTests.testBindGitProjectEnablesWorktreeAndConfinesCommit`. `WorktreeService.bindProjectEnablingWorktree` + `ConversationCoordinator.applyDefaultWorktree`. |
| W2 | Main checkout files at HEAD are **unchanged** until the user merges | **Pass (2026-08-20):** `W13PathWorktreeGitTests.testWorktreeMutationDoesNotDirtyMain` — `write_file` lands in worktree; main has no file; `git status --porcelain` in main has no marker. Not a user-repo eval. |
| W3 | Bind a **non-git** folder → no worktree, bind still succeeds, user-visible reason, edits go to `projectRoot` | **PASS (Ada 2026-08-20).** Bind succeeds, `worktreeBranch` nil (`testBindNonGitFolderDoesNotTrapAndLeavesWorktreeOff`). `WorktreeBindResult.userVisibleReason` = `notAGitRepo`. `ConversationCoordinator.applyDefaultWorktree` sets `host.worktreeError`. ChatView `.alert("Worktree error")`. |
| W4 | Dirty main tree does **not** block create; worktree is `HEAD`, uncommitted main files stay in main | **PASS (Ada 2026-08-20).** `testDirtyMainDoesNotBlockWorktreeCreate`: untracked `uncommitted-main.txt` + modified `README.md` in main → bind `.enabled`; untracked absent from worktree; worktree README is HEAD (`readme`); main README stays `readme dirty`; porcelain still lists both. |
| W5 | Merge / discard are **explicit user actions**. No auto-merge. | **Code + sheet tests (e72a114):** `WorktreeCoordinator.merge/discard` only; chrome copy `WorktreeChromeCopy.editMain` tested. `WorktreeReviewSheetTests` = characterization of Merge/Discard/Continue (not XCUI). GHA `SKIP_APP_TESTS=1` — not a CI gate. |
| W6 | Escape hatch “Edit main tree” persists for that conversation; later sends must **not** recreate the worktree | **Pass (clear branch):** `testDisableWorktreeModeClearsBranchWithoutDiscard`. Later-send must-not-recreate **not** re-run as a send loop. |
| W7 | `git_commit` / `create_pull_request` run in the **worktree cwd / branch** when isolation is on — never silently commit the main checkout | **Pass:** bind+commit test + `GitWorkflowCommitPRTests.testCreatePullRequestPushDefaultsFalse`. |

### Persist

| # | Bar | Evidence |
|---|-----|----------|
| P1 | Conversations survive quit/relaunch (`~/Library/Application Support/VibeCoder/conversations/`) | **PASS (Ada 2026-08-20).** `ConversationStore.save` atomic JSON under App Support `conversations/`. Round-trip: `BugHuntMemoryConversationTests` (`testConversationStoreSaveLoadRoundTrip`, unknown-role load, corrupt file listed not dropped). Relaunch path is `refreshConversations` → `listDirectory`. Not a live ⌘Q. |
| P2 | Cancelled turn is on disk | **PASS; residual closed (Ada 2026-08-20).** Cancel/finish save via `persistConversationSnapshot` (do/catch + `Diagnostics.error`; idle `statusLine` = `"Couldn't save conversation."`). `testChatViewModelSaveFailureSetsStatusLine`. No `try? ConversationStore.save` in ChatViewModel. |
| P3 | Kill-during-turn: last snapshot or honest “not saved”; no corrupt JSON | **PASS with residual.** Saves are `.atomic`; torn write cannot replace a good file. Process kill mid-turn keeps the **last completed save** (no mid-stream checkpoint). Corrupt JSON: `listDirectory` → `unloadable` (`testListReportsCorruptFileAlongsideHealthyConversation`). No in-app “not saved” banner. |
| P4 | Sticky pins / `sessionReadPaths` survive reload | existing tests; don’t regress |

### Local API / remote

| # | Bar | Evidence |
|---|-----|----------|
| L1 | Default: `POST /v1/chat/completions` with `tools: []` (proxy) | **PASS (Lin/Ada 2026-08-20).** `ServeToolsPolicy.resolve(false) == .proxyOnly`. `testLocalAPIDefaultChatCompletionsSendsEmptyTools` live loopback POST → `lastToolsCount() == 0`. `testLocalAPICompletionToolsDefaultEmpty`. Opt-in is AgentLoop (`testLocalAPIOptInAgentLoopSendsToolsOnInnerRequest` inner `lastToolsCount > 0`), not schemas on the proxy helper. |
| L2 | Opt-in + no usable project → 400 | **PASS (Rigel 2026-08-21).** `swift test --filter testLocalAPIOptInWithoutUsableProjectReturns400` → **1/1**. Loopback `POST /v1/chat/completions` with `agentToolsEnabled: true` and no bound project → HTTP **400**, body contains `Agent loop requires a project folder`. Unit/loopback POST, **not** in-app. |
| L3 | Remote control port does **not** accept LAN/phone sessions | **PASS (Ada 2026-08-20).** `RemoteControlServer.isEnabled == false`; `start()` throws `.disabled`, no listener/token/URL (`testRemoteControlStartDoesNotBindListener`, `testStartRefusesAndDoesNotBindOrPublishURL`). Leftover `RemoteControlSheet.swift` **deleted** (b7db51f); `ClusterPaneUITests.testRemoteControlSheetIsGone` (characterization, not XCUI; GHA `SKIP_APP_TESTS=1`). |

### Proof pack (Rigel owns the folder)

Write results under `docs/orchestration/` or `Evals/results/` with date. Empty cells are not 99%. Filled cells are also not 99% if the evidence is mock-worker, unit, or skipped App tests.

---

## Non-goals (this bar)

- In-process MLX, mlx-swift, bundled llama.cpp / GGUF runner
- Onboarding wizard, license/trial, Sparkle, Sentry
- App Sandbox entitlement redesign
- SQLite session store
- ZCode chrome leftovers: mermaid, KaTeX, queue **Edit**, `node_repl`, in-app browser/whiteboard
- Growing `ChatViewModel.swift` (2836 lines) or `AgentLoop.swift` (~2110) except to **move code out**
- Making Local API full in-app parity (worktrees, review sheets, MCP)

---

## Worktree default — contract for Lin

**When it fires** (create or reuse via `WorktreeService.createOrReuseWorktree`):

1. `ConversationCoordinator.newConversation(in:)`
2. `ConversationCoordinator.moveConversationToProject` when the new project is non-nil
3. `ConversationListViewModel.newConversation(..., projectRoot:)`
4. Duplicate of a conversation that has a `projectRoot` → default worktree rule (`ConversationCoordinator.duplicateConversation` → `applyDefaultWorktree`). Fresh `agentcore/<copyId>`; does not share the source branch. Dead `ConversationListViewModel.duplicate` removed.
5. Scheduled task with a `projectFolder` that is a git repo (headless still isolates)

**Do not fire** on: every `send`, conversation reload, Local API agent-loop (stays bound-project + PathConfinement), or a conversation whose user chose **Edit main tree**.

**Not a git repo:** bind `projectRoot` anyway. Do **not** throw past the bind. Surface `WorktreeError.notAGitRepo` once. `worktreeBranch` stays nil. Tools use `projectRoot`.

**Dirty main tree:** do **not** require a clean index. `git worktree add … HEAD` from a dirty repo is allowed. The sibling worktree is a clean checkout of **HEAD**. Uncommitted files stay in the main tree and are **not** copied into the worktree. Merge later may conflict — that is the user’s problem at merge time, not create time.

**Path already occupied:** keep today’s fail-closed (`exists but is not a worktree of this project`). Do not delete foreign directories.

**Reuse:** same conversation id → same `<project>-agentcore-<shortid>` / `agentcore/<shortid>` (already implemented).

**Merge / discard:** only `WorktreeCoordinator.mergeWorktree` / `discardWorktree` (user). Never auto-merge on turn end, quit, or bind.

**Escape hatch:** user action “Edit main tree” (Pixel) → `worktreeBranch = nil`, do **not** discard the sibling folder unless they also Discard. Persist nil. Subsequent binds of a *different* project re-evaluate the default.

**git_commit / create_pull_request:** `ToolContext.workingDirectory` must be the worktree when `worktreeRootURL != nil`. Refuse or no-op with an honest error if invoked against the main checkout while isolation is on.

**Call-site freeze:** implement in `WorktreeCoordinator` + bind methods. Do **not** append this policy into `AgentLoop` or `ChatViewModel` beyond setting `conversation.worktreeBranch` the way `enableWorktree` already does.

---

## Extraction map (do not grow these files)

| File | Lines (2026-08-22) | Allowed this cut | Later extract |
|------|--------------------|------------------|---------------|
| `App/ViewModels/ChatViewModel.swift` | 2836 (was ~3596) | UI wiring only if Pixel must; **no** new loop policy | persist, slash commands, queue **already extracted** (`ChatViewModel+SlashCommands`, persist/queue out). Do not list as undone. Stream coalesce if still in-file. |
| `Sources/AgentCore/Agent/AgentLoop.swift` | ~2110 | **no** default-worktree logic; **do not grow** | already has `AgentRunBootstrap` — keep using it |
| `Sources/AgentCore/Agent/ChatLoop.swift` | ~1019 | no | leave |

New worktree default belongs in `WorktreeCoordinator` / `ConversationCoordinator` bind paths. Pixel’s first-run hero belongs in `ChatView` empty state + `LoopbackServerProbe`.

---

## Confidence rule

Ada/Lin/Pixel/Rigel/Churro each report:

```
CONFIDENCE: N%
EVIDENCE: …
BLOCKERS: …
NEXT_ASSIGNMENT: …
```

**99%** requires F1–F4, A1–A4, W1–W7, P1–P3, L1–L3 with artifacts that prove the bar. **Filled cells ≠ 99%.** Current honest status (2026-08-22): **not 99% daily-driver.** F4 live Unsloth first chat witnessed by Reed (Mac app window, one turn “Hey”) — **not** 012/013, **not** eval-runner, **not** CLI. GitHub still unpushed. GHA `SKIP_APP_TESTS=1` (local WARN unless `APP_TESTS_STRICT=1`) — App tests **do not gate merge**. B1 Connection Test and A1/A2 still unit/mock, not live. 012/013 remain mock-worker. Residuals that still block 99%: App tests not a merge gate; no live Connection Test; A1/A2 not live HTTP/in-app; no ⌘Q or SIGKILL; no mid-stream persist checkpoint. EXO Cluster pane mounted (b7db51f: read-only `/state` + pin Model ID); not unmounted / not a partial topology UI. `RemoteControlSheet` leftover deleted. `ConversationListViewModel.duplicate` removed (zero callers; it forced `worktreeBranch: nil`).

### Five-way (2026-08-21) — historical, not today’s score

Everyone wrote 99% that day because required cells were filled. **That rule overclaimed.** Do not copy these numbers forward as current confidence.

| Who | CONFIDENCE (then) | Note |
|-----|-------------------|------|
| Ada | 99% | Required cells filled; L2 named test is scorecard honesty not a product gate |
| Lin | 99% | W/L/A3–A5/P; landed `testLocalAPIOptInWithoutUsableProjectReturns400` |
| Pixel | 99% | F1–F3, W5/W6 chrome; live window residual. W5 sheet = `WorktreeReviewSheetTests` (not XCUI; not a GHA gate) |
| Rigel | 99% | Re-ran L2 **1/1**; rewrote L2 evidence cell |
| Turnip | 99% | Re-ran L2 **1/1** (0.014s); five-way collected |

Untracked duplicate mock result dumps stay untracked. Do not mix CLI/app code. Do not push (P4 = Max).
