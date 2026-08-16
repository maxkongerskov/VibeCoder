# U4 `subagents-pane`

ZCode right pane: tab **Subagents** (`sidePane.subagentDirectory`) + per-agent
**Subagent** detail. Chat card button **Open in side pane**.

## Surface (copy from ZCode i18n)

Directory:
- Title **Subagents**
- Sections **Running** / **Ended**
- Empty running: **No running subagents**
- Empty all: no task tool calls + no jobs → **No subagents in this task**
- Load fail: **Unable to load subagents.**
- **Show 20 more** if ended > 20
- Statuses: Running / Waiting / Blocked / Completed / Failed / Cancelled / Lost

Chat card:
- Button **Open in side pane** (always visible on `task` rows, not only when running)

Detail (when a row is selected):
- Type (mono, `Theme.Palette.subagentType`) + description
- Status + elapsed
- **Prompt** (from `task` args JSON `prompt`)
- **SubAgent output** — latest lines; if truncated, footer
  `Latest {visible} rows / {total} total`
- Running: **Kill** if we have a job UUID (reuse existing kill path via
  `BackgroundJobManager.shared.kill` — do **not** edit ChatViewModel)

## Data (do not edit ChatViewModel)

1. Live: `BackgroundJobManager.shared.list(conversationID:)` + `listRunning()`,
   `kind == .subagent`. `command` is the description string.
2. Transcript: walk `conversation.messages` like `TurnChangeSummary` —
   assistant `toolCalls` where `name == "task"`, match `.tool` results by
   `toolCallID`. Parse `task_id` / `agent_id` / `type` / `description` from
   result (`<subagent_meta>` block or `task_id:` lines).
3. Merge by `task_id` UUID when present; else by tool-call id.

Poll jobs ~0.5s while the tab is visible.

## Notifications (define in InspectorPanelAttach.swift)

```
.openSubagentInInspector = "agentos.openSubagentInInspector"
```

`userInfo`:
- `taskId` String? (UUID)
- `toolCallId` String?
- `type` String?
- `description` String?

Receivers:
- Attach: force `isPresented = true`
- Panel view: `selectedTab = .subagents`, select that row

Also accept `.setInspectorVisible` (already exists).

## Tab model

Add `InspectorPanelTab.subagents` title **Subagents** (keep Files / Changes).
Bump inspector `max` width to ~480 so output is readable
(`inspectorColumnWidth`).

## Chat card

`ZCodeActivityLineView` subagent row: add **Open in side pane** (11pt medium,
accent) next to Kill. Posts `.openSubagentInInspector` +
`.setInspectorVisible` visible=true. Do not change generic tool rows.

## Tests (`InspectorSubagentsUITests.swift`)

- Tab enum includes subagents
- Empty conversation → empty directory
- Merge a `task` invocation + tool result with `task_id:` into Ended/Completed
- Running `BackgroundJobSnapshot` (you may construct the struct) maps to Running
- Status map: killed→Cancelled, failed→Failed, timedOut→Failed/Lost
- Notification name + userInfo parse
- Open-in-side-pane userInfo keys

Do **not** edit RootView / VibeCoderApp / ChatView / ChatViewModel.

## Shipped (U4)

- `InspectorPanelTab.subagents` title **Subagents**; inspector column max width **480**.
- Notification `agentos.openSubagentInInspector` in `InspectorPanelAttach` (`taskId` / `toolCallId` / `type` / `description`). Attach forces `isPresented`; panel selects the Subagents tab + row. Pending store covers the hidden-inspector mount race. No parent (RootView / ChatView / ChatViewModel) glue.
- Pure merge in `InspectorSubagentDirectory`: transcript `task` + `.tool` results (`<subagent_meta>` or `task_id:` lines) + `BackgroundJobSnapshot` (`kind == .subagent`). Merge key is `task_id` UUID else tool-call id.
- Status: job `killed` → Cancelled, `failed` → Failed, `timedOut` → Lost. Directory **Running** / **Ended**, empty copy, **Show 20 more**, detail Prompt + SubAgent output (latest-N footer) + Kill via `BackgroundJobManager.shared.kill`.
- Chat `task` rows: **Open in side pane** (11pt medium accent) next to Kill; posts open + `setInspectorVisible`. Generic tool rows unchanged.
- Tests: `App/Tests/InspectorSubagentsUITests.swift`.
