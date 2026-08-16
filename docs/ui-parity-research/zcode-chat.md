# ZCode 3.7.7 — Chat / conversation surface

Source: Electron + React 19 renderer `extracted/out/renderer/` (v3.7.7). Primary UI bundle `assets/styles-OqUHW1P0.js` (~4.5 MB / 1077 lines minified). English strings from `assets/IntlProvider-C321H7m8.js` (EN object starts at `"common.loading":\`Loading\``). Agent slash catalog from `zcode.pretty.js`. ZCode Agent (internal `glm`) is the default desktop provider.

Evidence paths are relative to `/Users/maxkongerskov/zcode-reverse/`. Inferences marked **(inferred)**.

---

## 1. Composer / input bar

| Feature | ZCode behavior | UI detail | Evidence |
|---|---|---|---|
| Editor | Lexical rich-text (`namespace: ChatInput`), not a `<textarea>` | `min-h-10 max-h-40 overflow-y-auto`; markdown extracted on submit | `styles-OqUHW1P0.js:305` `EYe` / `vKe` |
| Dock | Bottom composer dock | `data-v4-composer-dock="true"`; form `rounded-2xl border border-input-border bg-input p-3` | `styles-OqUHW1P0.js:280,305` |
| Placeholder (empty task) | `Ask ZCode anything, @ to add context, / for commands or capabilities` | Compact/mobile: `Ask ZCode anything…` | `IntlProvider` `chat.placeholder.newTask` / `newTaskMobile`; picker `$Ye` at `styles-OqUHW1P0.js:307` |
| Placeholder (follow-up idle) | `Ask for follow-up changes` | After history exists | `chat.placeholder.followUpAsk` |
| Placeholder (follow-up running) | `Keep typing to queue follow-up changes` | While task processing | `chat.placeholder.followUpQueue` |
| Placeholder (boot) | `Initializing task...` | | `chat.placeholder.loading` |
| Empty-state greeting | Time-of-day greetings above composer | e.g. “Morning, how can I help?”; workspace picker “Start a new task in {workspace}” | `chat.empty.*` |
| Enter | **Enter submits** when `enterSubmits` (default `true`) | Ignored if Shift / Ctrl / Meta / composing / disabled | `_Ye` `registerCommand(sF)` `styles-OqUHW1P0.js:303` |
| Shift+Enter | Newline | Lexical `KEY_ENTER` with `shiftKey:true` inserts line break | `styles-OqUHW1P0.js:294,303` |
| Send button | Icon-only, brand fill, `data-testid` `chat-send-button` | Tooltip title = Send/Queue; **shortcut `Enter`** | `styles-OqUHW1P0.js:305` |
| Send label | `Send` | Aria/sr-only | `chat.send` |
| Stop button | Ghost `icon-lg` next to send **while running** | Tooltip **shortcut `Esc`**; label `Stop` | `styles-OqUHW1P0.js:305`; `chat.stop` / `chat.stop.short` |
| Esc | Composer `onKeyDown`: if stop handler `z` set and not disabled, **preventDefault + stop** | Same Esc used by slash/mention pickers to dismiss | `styles-OqUHW1P0.js:305` `Te`; slash/mention `KEY_ESCAPE` at `:301` |
| Queue vs send | If input routing `kt==='enqueue'`, button label becomes **Queue message** | Description: queued draft auto-sends after current response | `styles-OqUHW1P0.js:339`; `chat.queue.enqueue` |
| Attachments | Hidden `<input type=file multiple>` + “Add attachment” action | Also paste images; drop files | `styles-OqUHW1P0.js:339`; `chat.attachments.add.description` |
| Attach limits | **Max 8** attachments; inline images **20 MB** (`ZV=20*1024*1024`); clipboard-text threshold **5 KB** (`IYe=5*1024`) | Oversize error `OversizedInlineImageAttachmentError`; i18n `{sizeMb}` | `styles-OqUHW1P0.js:305`; `chat.attachments.maxFiles` / `maxFileSize` |
| Attachment chips | Filename + upload states | Waiting for session / queued / Uploading N% / Finishing / complete / failed + Retry | `chat.attachments.upload.*` |
| Pasted text | Saved as attachment “Pasted text · {n} lines” | Filename `pasted-text-YYYYMMDD-HHMMSS.txt` | `styles-OqUHW1P0.js:307`; `chat.attachments.clipboardText` |
| @ mention | Trigger `@` opens portal picker | Categories: **plugins, files, sessions, whiteboards**; `$` = skills; `#` = sessions | `OJe` `styles-OqUHW1P0.js:301`; `chat.mention.*` |
| File mention | Search workspace files; drop workspace file/folder | Overlay: “Drop to mention this file or folder” | `chat.composer.workspaceFileDragHint` |
| / slash | Trigger `/` portal “Commands and capabilities” | Sections: **Commands** (`/name`), **Skills** (`$name`), **Agents** | `SJe` `styles-OqUHW1P0.js:301` |
| Composer + menu | “Add context” plus buttons | Hints: “Use @ to add context”, “Use / for commands or capabilities”, “Insert # session” | `chat.composer.actionMenu` / `insert*Shortcut` |
| Prompt history | Up/Down at empty start recalls last **30** prompts | `localStorage` key `zcode-chat-prompt-history:` | `styles-OqUHW1P0.js:305,307` |
| Prompt enhance | Separate control “Enhance prompt” | Click again cancels; uses selected model | `chat.promptEnhance.*` |
| Model selector | Toolbar dropdown “Choose model” | Search `Search models...`; Manage models; locked while task running | `chat.toolbar.model.*`; `styles-OqUHW1P0.js:339` |
| Mode switcher | Toolbar “Switch mode” (default provider **glm**) | Default current value **`build`** if unset; shortcut **`M`** (`Bre('M')`) | `$rt` `styles-OqUHW1P0.js:339`; `mode.label.glm.*` |
| GLM mode names | `default` Default; `build` **Ask before changes**; `edit` **Edit automatically**; `plan` **Plan mode**; `yolo` **Full access** | Descriptions: ask before file changes / edit automatically / plan before editing / fewer confirmations | `mode.label.glm.*` / `mode.description.glm.*` |
| Other-agent modes | Claude: Auto / Default / Accept edits / Plan / Don't ask / Bypass permissions. Codex: Read only / Auto edit / Agent / Full access. Gemini: Default / Auto edit / **Yolo** / Plan. OpenCode: Build / Plan | Shown when task provider is that CLI | `mode.label.{claude,codex,gemini,opencode}.*` |
| Reasoning effort | Toolbar “Reasoning effort” / tooltip “Thought level” | Values: **Off, No thinking, On, Low, Medium, High, Extra high, Max** | `chat.toolbar.thoughtLevel.*` |
| Context | Toolbar “Context usage {used} of {total}” | Breakdown: messages / system prompt / meta / skills / tool prompt / system tools / MCP; **Compress** (sends `/compact`) | `chat.contextUsage*` |
| Multi-line | Auto-grow to `max-h-40` then scroll | Mentions inserted as Lexical mention nodes (chips) | `styles-OqUHW1P0.js:305` |
| Drafts | Persisted composer drafts | `localStorage` `zcode-v4-composer-drafts:v1:` | `styles-OqUHW1P0.js:307` |

---

## 2. Message rendering

| Feature | ZCode behavior | UI detail | Evidence |
|---|---|---|---|
| Layout | **User = right bubble; assistant = flat full-width** | User: `items-end` + `max-w-xl rounded-xl rounded-tr-xs border bg-surface px-4 py-3`. Assistant: `w-full text-ui-base` (no bubble) | `gvt` / `vvt` `styles-OqUHW1P0.js:363` |
| Hover chrome | Actions hidden until hover | `opacity-0 group-hover/user-row` / `group-hover/assistant-row` / `group-hover/assistant-turn` | `styles-OqUHW1P0.js:363` |
| User actions | Copy + Edit | Edit tooltip hardcoded `编辑` (not i18n); resubmit composer + optional **Reset chat + files** | `gvt` `:363`; `chat.edit.resetConversationAndFiles*` |
| Assistant actions | Copy, Like, Dislike, **Fork**, timestamp | Like/dislike persist; fork after task finishes | `chat.message.copy` / `like` / `fork`; `_vt` `:363` |
| User overflow | Collapsible if height > ~120px | Fade mask + expand/collapse pill | `J_t` `data-v4-user-input-collapsible-content` `:363` |
| Mentions in user text | Rendered as chips (file icon, `$skill`, `#session`, plugin, subagent, `/command`) | Goal/compact get special icons | `ovt` `:363` |
| Markdown engine | **Streamdown** + remark/rehype; fail-closed to plaintext | `[MessageResponse] markdown 渲染失败，已降级为纯文本`; modes `streaming` \| `static` | `CHe` `styles-OqUHW1P0.js:286`; `data-streamdown` attrs `:280` |
| Code blocks | **Shiki** (per-language grammar chunks + VS Code themes in `assets/`) | Header: file icon + language + **Wrap lines** + **Copy code**; optional mermaid | `mk` `styles-OqUHW1P0.js:280`; `chunk-BO2N2NFS-CSNAeaxF.js` `data-streamdown=code-block` |
| Tables | Streamdown tables; copy as **md / csv / tsv** | Sticky scrollbar vs composer dock `--chat-bottom-dock-height` | `chunk-BO2N2NFS-CSNAeaxF.js:119`; `styles-OqUHW1P0.js:280` |
| Mermaid | Auto-render when language is mermaid (`renderMermaid` default **true**) | Skip logged with reason/metrics; preview dialog | `mk` / `Aze` `styles-OqUHW1P0.js:280`; mermaid chunks in assets |
| Math | **KaTeX** via rehype-katex | `language-math` / `math-display` / `math-inline`; error span `.katex-error` | `styles-OqUHW1P0.js:261`; `katex-fHRr5Rbn.js` |
| Lists / quotes | Streamdown unordered/ordered + blockquote | `data-markdown-list`, `data-markdown-blockquote` | `styles-OqUHW1P0.js:280` |
| Images | Markdown images + gallery; workspace-relative resolved | Loading shimmer; click preview | `gVe` `:284` |
| Preview cards | After turn: Website / MD / DOCX / XLSX / PPTX / PDF | Open in editor/browser | `chat.previewCards.*`; `M_t` `:363` |
| Reasoning | Collapsible `Reasoning` / `ReasoningTrigger` / `ReasoningContent` | Streaming: animated-gradient **“Thinking...”**. Done: **“Thought for N seconds”** (or “a few seconds”). Content `max-h-60` left-border, auto-collapse after stream | `H_t`/`U_t`/`W_t` `:363`; `chat.reasoning.*` |
| Streaming | `assistantText.state==='streaming'` passed to markdown | Bottom loading slot spinner (`data-zcode-chat-loading-slot`) while last turn running and no pending approval | `vvt` / `v1` `:363` |
| Work duration | Turn header “Working for {duration}” / “Worked for {duration}” | Units d/h/m/s; collapsible history of earlier tool work | `chat.history.workingFor`; `zvt` `:363` |
| Tokens | Context-window UI (used/total + breakdown) | **No per-message token/cost/latency** strings in i18n | `chat.contextUsage*`; `chat.planUsage.contextDetail` |
| Large reply | “This reply is large. Showing a preview only ({previewBytes}/{fullBytes}). View full message” | Tool-call batch: “Showing {shown}/{total} tool calls. Load more” | `chat.message.bodyPreview.*` / `toolSlice.*` / `toolSnapshot.*` |
| Retry | `chat.message.retry` on assistant when `canRetry` | | `styles-OqUHW1P0.js:363` |
| Empty finish | “No visible output / This task finished without any chat content…” | | `chat.emptyResult.*` |
| Timeline markers | Compact / fork / model change / goal verify as centered divider rows | Running compact/goal use gradient text | `Evt` `:363`; `chat.contextCompaction.*` `chat.modelChange.*` `chat.goalVerification.*` |
| Turn navigator | Left rail (≥864px) “Conversation query map” | Hash marks jump to user queries; tooltip user+assistant preview | `chat.turnNavigator.*`; `oyt` `:368` |
| Find in chat | Command-palette **Find in task** | Scopes: Search messages / Search file changes; CSS Highlight API classes `zcode-v4-conversation-find*` | `quickPick.find.*`; `styles-OqUHW1P0.js:381` |
| Selections | Attach prior user/assistant/reasoning/tool text to next send | Caps: 8 selections, 8k chars each, 16k total | `chat.selections.*` |

---

## 3. Tool-call rendering

| Feature | ZCode behavior | UI detail | Evidence |
|---|---|---|---|
| Shell | `ToolLayout` kind **Running** / **Ran**; title = command; expand for output | Status Failed/Denied/Stopped; “No output.”; copy error | `chat.toolCall.execute.*`; `styles-OqUHW1P0.js:348` |
| File write/edit | Writing/Wrote, Updating/Updated, Deleting/Deleted, Editing/Edited | Multi-file `{count} files`; inline unified-diff rows `+`/`-` with `--color-diff-added/removed` | `chat.toolCall.edit.*`; `_ut` `:343` |
| Read | Reading / Read | Family `file-read` | `chat.toolCall.read.*`; `Qme` `:240` |
| Search / list | Find {query} / List in {cwd} / Searching / Searched | | `chat.toolCall.search.*` |
| Explore grouping | Consecutive **read-only** tools collapsed to one **Explore** card | Buckets: N search(es), N list(s), N file(s); “0 files” empty | `h_t`/`__t` `styles-OqUHW1P0.js:361`; `chat.toolCall.explore.*` |
| Hidden running shells | Shells with **empty parsed command** while streaming/running are skipped in grouping | **(inferred)** to hide noisy in-flight bash | `p_t`/`r_t` `:361` |
| Agent / Task | Card **SubAgent** + prompt; “Open in side pane” | Background: Launching/Launched + output tail “Latest {visible}/{total} rows”; hidden earlier rows | `chat.toolCall.agent.*` |
| Skill | Running skill / Ran skill + Args | | `chat.toolCall.skill.*` |
| Todo | Updating/Updated todo (can be hidden via `messageStreamShowTodos`) | Todo lives in status panel | `chat.toolCall.todo.*` |
| MCP | “View call details”, Parameters, Result, Copy result, wrap lines | | `chat.toolCall.mcp.*` |
| Node REPL | Working / Completed / failed / denied / stopped; Result image; Full result saved | Technical details drawer | `chat.toolCall.nodeRepl.*` |
| SendMessage / RespondToCoordinator / TaskOutput / TaskStop / ReadSessionContext | Dedicated status verbs + target/summary fields | Truncation notices | `chat.toolCall.sendMessage.*` etc. |
| Expand | Header toggle; aria `Expand tool details` / `Collapse` | Collapsed shows kind + primary path/command | `chat.toolCall.expandDetails` |
| Truncation | “{fields} tool field(s) were truncated. Showing preview X / Y. Load full tool data” | | `chat.toolCall.snapshot.*` |
| Status pills | Pending / Running / Completed / Failed / Denied / Stopped | Maps v4 `inputStreaming|pendingApproval|running|success|error|cancelled` | `chat.toolCall.status.*`; `o_t` `:361` |
| Child tools | Data field `childToolCalls` on Agent nodes | i18n `{count} child tools` exists | `s1` `:361`; `chat.toolCall.childCount` |
| xterm | **Dedicated Terminal panel**, not inline Bash card | `new Terminal({fontSize:13, …})` + `FitAddon`; OSC-8 http links; `quickPick.command.toggleTerminal` | `styles-OqUHW1P0.js:1060`; xterm vendor `:1058` |
| Long-running | Composer chip “Running for Ns / Nm Ns”; expand/collapse long-running panel | Background Bash/Subagent counts on composer | `chat.longRunning.*`; `chat.composer.backgroundWorks.*` |
| Errors | Destructive status + Copy | | `chat.toolCall.copyError` |

Tool identity families used by the renderer (`Qme` / `og`, `:240`): `file-read`, `file-write`, `shell`, `search`, `explore`, `todo`, `goal`, `plan-guidance` (EnterPlanMode), `switch-mode` (ExitPlanMode), `skill`, `agent`, `ask-user-question`.

---

## 4. Diff / patch / checkpoints

| Feature | ZCode behavior | UI detail | Evidence |
|---|---|---|---|
| Turn file summary | After a turn: **“N file(s) changed +add −del”** collapsible card | Expand lists each path with per-file +/− | `T_t` `styles-OqUHW1P0.js:363`; `chat.changeSummary.filesChanged.*` |
| Review | Per-file **Review** opens code viewer `{type:'patch'}` | Builds unified `--- a/ +++ b/ @@` from hunks | `u1`/`w_t` `:363` |
| Open | Split button Open + editor picker / copy abs/rel path | | `x_t` `:363` |
| Undo | Header **Undo** → dialog “Undo file changes” | Rechecks disk; Safe / Unsafe / Ignored lists; reasons: bash ignored, checkpoint missing/unreadable, external modified, unreadable, old checkpoint | `chat.changeSummary.rewind*` |
| Reapply / Undone | `Reapply` / badge `Undone` | | `chat.changeSummary.reapply` / `reverted` |
| Per-hunk accept/reject | **Not present** | No “Apply patch” / accept-hunk strings | renderer i18n + `T_t` |
| Right Diff panel | Shell titled **Diff**; toggle/close | Copy still says “UI placeholder… Git service not fully wired” **(may be stale vs live)** | `diff.title` / `diff.placeholder.*` |
| Truncation | “Diff preview truncated: {count} lines omitted…” | | `diff.preview.truncatedLines` |
| Checkpoint rewind (slash) | `/rewind [latest\|checkpointId]` | Workspace restore, not hunk UI | `zcode.pretty.js:17089-17093` |

---

## 5. Plan mode UI

| Feature | ZCode behavior | UI detail | Evidence |
|---|---|---|---|
| Enter | Tool `EnterPlanMode` rendered as `plan-guidance` | | `styles-OqUHW1P0.js:240` |
| Exit / approve | `ExitPlanMode` / schema `interaction==='plan_approval'` | Elicitation option labeled **Approve** — “Exit plan mode and start implementation.” Placeholder title **Implementation plan** | `fxt`/`Xxt` `:381-382`; `chat.elicitation.planApproval.*`; `chat.permission.switchMode.placeholder` |
| Goal blocked in plan | Sending a `/goal` while mode=`plan` shows “Goal is unavailable in Plan mode…” | | `styles-OqUHW1P0.js:382`; `chat.goal.planModeBlocked` |
| Status panel | Section **Plans**; rows open plan markdown (`planFilePath` + `markdown`) | Fallback title `Plan` | `chat.statusPanel.sessionPlans` / `openPlan`; `Dlt` `:343` |
| Toolbar | Mode option `plan` = “Plan mode” / “Plan before editing.” | | `mode.label.glm.plan` |
| Goal | Separate Goal widget (Active/Paused/Done); unavailable in plan | | `chat.target.*` |

---

## 6. Permission prompts

| Feature | ZCode behavior | UI detail | Evidence |
|---|---|---|---|
| Card | “Permission required” / “Awaiting approval” | Rounded-2xl popover `data-elicitation-dialog-card`; also used for AskUserQuestion | `chat.permission.title`; `styles-OqUHW1P0.js:381` |
| Button mapping | Agent option text mapped: **Allow** / **Always allow** / **Deny** / **Always deny** | Synonyms: allow once, approve, always allow, reject, always deny | `J1`/`Mxt`/`xxt` `:382` |
| Extra labels | **Allow for session** (Codex “allow for session”); **Always allow in this project** (GLM) | | `Nxt`/`Pxt` `:382`; `chat.permission.allowForSession` / `allowForProject` |
| Descriptions | Allow only this time / Do not ask again (command\|file\|generic) / Reject for now / Always reject… | | `chat.permission.allowOnce.description` etc. |
| Confirm | Footer **Confirm** (`common.confirm`) after selecting an option | Keyboard: **Tab / arrows to choose, Enter to confirm**; Esc dismiss / previous | `chat.permission.keyboardHint`; `:382` |
| Prefix hints | Rule prefixes shown as mono `code` chips (`data-permission-rule-prefixes`) | i18n “Command prefix” / “Exact command only” | `jxt` `:382`; `chat.permission.scope.*` |
| File ops | Create / Edit / Creates N files / Updates N files | | `chat.permission.fileChange.*` |
| Subagent origin | “Request from subagent: {agentType}” | | `chat.interactionOrigin.subagent` |
| AskUserQuestion | Multi-question card; Continue / Submit / Custom answer; countdown stop | Auto-continue if unanswered | `chat.elicitation.*` / `chat.askQuestion.*` |
| CUA | Separate macOS Accessibility / Screen Recording helper | | `chat.cuaPermission.*` |
| Session allow-all | No dedicated “allow all tools this session” button beyond **Always allow** / **Allow for session** / mode **yolo** / **bypassPermissions** | | i18n + mode catalog |

---

## 7. Command system

### 7.1 Slash popup (desktop)

Broadcast list from agent (`slashCommands[]` schema `source: builtin|custom`) plus app extras. Popup title “Commands and capabilities”; empty: “No slash commands have been broadcast…”. App extra: **side** — “Open a new side conversation”. Skills listed as `$name`. `styles-OqUHW1P0.js:257,301`; `chat.slash.*`.

### 7.2 Built-in slash commands (agent catalog)

From `zcode.pretty.js:16998-17106` (help dump `:587659`):

| Command | Usage | Notes |
|---|---|---|
| `/help` | `/help [command]` | Local help |
| `/login` | `/login [zai-coding-plan\|…]` | |
| `/logout` | `/logout` | |
| `/compact` | `/compact [instructions]` | Also alias `/compress` in composer router `d1` |
| `/init` | `/init [notes]` | Write/update workspace `AGENTS.md` |
| `/expert` | `/expert [status\|resume\|stop\|<task>]` | |
| `/effort` | `/effort [list\|<level>]` | Alias `/variant` |
| `/workflow` | create/validate/run/status/resume | |
| `/workflows` | `[runId]` | |
| `/fork` | `/fork [latest\|checkpointId]` | |
| `/locale` | `/locale [auto\|en-US\|zh-CN]` | Alias `/language` |
| `/mcp` | list/status/connect/disconnect | |
| `/plugins` | list/enable/disable | Alias `/plugin` |
| `/mode` | `/mode [plan\|build\|edit\|yolo]` | GLM permission modes |
| `/model` | `/model [list\|main\|lite\|provider/model]` | |
| `/new` | `/new` | Alias `/clear` |
| `/resume` | `/resume [sessionId]` | Alias `/continue` |
| `/rewind` | `/rewind [latest\|checkpointId]` | |
| `/skill` | `/skill [<name> [task]]` | |
| `/goal` | `/goal [pause\|resume\|clear\|replace <obj>\|<obj>]` | Alias `/target`; blocked in plan mode |

Queued `/compact` shows as literal `/compact` with **Run now** (not Steer). `styles-OqUHW1P0.js:343`.

### 7.3 Custom markdown commands

User/plugin commands: frontmatter + body. Template tokens **`$ARGUMENTS`** and **`$1` `$2`…**; unsupported dynamic `!`backtick / ` ```! ` shell interpolation detected. `zcode.pretty.js:24815-24869`, `634739-634787`. Desktop popup treats `source:'custom'` same as builtin (`Ske` schema `:257`).

### 7.4 Command palette

Title **Command palette**, placeholder **Type a command**. Sections: Suggested / Chat / Navigation / Panels / Configure / App. Commands include New task, Open workspace, Search files, Settings, Previous/Next task, Find tasks, Back/Forward, theme, MCP, Skills, toggle sidebar/terminal/preview/side pane/browser/diff, add terminal/browser/review tab, Feedback, Community, Connect/Disconnect. `quickPick.*`.

---

## 8. Conversation / session management

Tasks are first-class (sidebar “Tasks”, not “Chats”).

| Feature | ZCode behavior | UI detail | Evidence |
|---|---|---|---|
| List | Pinned / Recent; statuses Running / Restoring / Ready / Done / Failed | Tags: Awaiting approval; +add −del; Phone is using this task | `taskList.*` |
| Search | Sidebar “Search tasks…” | Archived search separate | `workspaceSidebar.searchTasksPlaceholder` |
| Organize | Timeline / By project; sort Created / Updated; Group | | `workspaceSidebar.organize*` |
| Rename / delete / pin / archive / unarchive | Context menu | Rename placeholder “Task name” | `taskList.rename` / `delete` / `pin` / `archive` |
| Fork | Per-assistant-message **Fork**; new untitled task | Errors: no checkpoint, parent missing, unsupported agent | `chat.message.fork*` |
| Split | “Open in split view” | | `taskList.openInSplitPane` |
| Unread | Mark as unread | | `taskList.markAsUnread` |
| Export conversation | **No conversation-export string** | Export **logs** only; **View model trajectory** (model-io dump) | `sidebar.exportLogs`; `taskList.viewModelTrajectory`; `modelTrajectory.*` |
| Jump | Prev/Next task; history back/forward | Blocked during model-provider restart | `taskNav.*`; `quickPick.command.previousConversation` |
| Metadata | Trajectory shows tokens **per model call**, not in chat chrome | Task list relative time now/Nm/Nh/Nd; Coding Plan quota popover (5h pool, weekly, MCP monthly) | `modelTrajectory.summaryTokens`; `chat.planUsage.*` |
| cwd / model | Workspace in empty-state + SSH alias/host/path; model in toolbar | Not a per-message footer | `workspaceSidebar.ssh*`; `chat.toolbar.model` |
| New task | Sidebar + empty state; optional CLI: Claude / OpenCode / Gemini / Codex | Default ZCode Agent | `taskList.newTask.*` |
| Cron / off-peak | Task badges “Scheduled task” / “Idle-time task” | | `taskList.cronTaskLabel` / `offPeakTaskLabel` |

---

## 9. Interrupts and queue

| Feature | ZCode behavior | UI detail | Evidence |
|---|---|---|---|
| Stop | Button **Stop**; **Esc** (tooltip + composer keydown) | “Stop only the current response. Queued messages stay held until you continue them.” | `chat.stop.description`; `:305` |
| TUI hint | Agent TUI copy “esc to interrupt” | Desktop uses Esc on Stop, no on-canvas “esc to interrupt” string | `zcode.pretty.js:587687` |
| Queue while running | Send becomes **Queue message**; placeholder “Keep typing to queue…” | Auto-send after current response | `chat.queue.enqueue*` |
| Queue list | “Queued messages (N)”; drag reorder | Per item: **Steer** (inject now) or **Run now** for `/compact`; Edit; Remove | `chat.queue.*`; `:343` |
| After stop | “The queue was paused because you stopped…” + **Continue** | | `chat.queue.paused.stopped` / `resume` |
| Send vs existing queue | Confirm: “Clear the {count} previously queued messages?” **Clear queue** / **Send message** | | `chat.queue.sendConfirm.*` |
| Input routing choice | May require confirmation when `inputRouting.mode==='choice'` | | `styles-OqUHW1P0.js:382` |
| Pending after CLI restart | Banner: input didn’t reach conversation — **Send again** / **Later** | | `chat.pendingCommand.*` |

---

## 10. Related chrome (chat-adjacent)

Status / summary panel (collapsible capsule): Git tools, Changes, Branch, Commit/Push, Goal, Plans, Progress (todos with fold completed/waiting), Terminals, Agents (N running / stop). `chat.statusPanel.*` / `chat.summaryPanel.*`.

Errors: connection lost / process exited; actions Retry, Sign in, Refresh quota, Switch model, Copy TraceID, Report issue. Quota banners with Upgrade / Switch model. `chat.error.*` / `chat.quota.*`.

---

## 11. Agent tools the UI must render (context)

Live 24 tools (from `agent-core/tools.md` / `live-tools-raw.md`): Agent, AskUserQuestion, Bash, CronCreate/Delete/List/Update, Edit, EnterPlanMode, ExitPlanMode, Read, Skill, TaskOutput, TaskStop, TodoRead, TodoWrite, WebFetch, WebSearch, Write, SendMessage, ReadSessionContext, plus `mcp__node_repl__js*`. Optional/hidden: Glob/Grep (embedded search), Task (Agent alias), RespondToCoordinator (child), js* built-ins.
