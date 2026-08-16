# subagents — TaskTool / SubAgentRunner / catalog (wave 2)

Owner: `subagents`. Exclusive files:

- `Sources/AgentCore/Tools/Builtins/TaskTool.swift`
- `Sources/AgentCore/Agent/SubAgentRunner.swift`
- `Sources/AgentCore/Agent/SubAgents/SubagentCatalog.swift`

Does **not** edit `AgentLoop`, `ToolRegistry`, `AgentDefinition`, or
`AgentMailbox`. Reads `AgentDefinition.profileSettings` and
`AgentMailbox` public API only.

## Concurrent launch

`SubagentCatalog.taskToolDescription` (and therefore `TaskTool.schema`)
tells the model:

- When launching **multiple independent** subagents, emit multiple
  `task` tool calls in a **single** assistant message so they run
  concurrently.
- `run_in_background: true` still works (immediate `task_id`).
- A new task starts **fresh** — the prompt must be self-contained.

Concurrency of those calls is the parent loop / tool-dispatch seam
(wave-2 `loop`). This track only advertises the contract.

## Profile settings on spawn

Custom markdown agents (`DiscoveredAgentDefinition.profileSettings`)
are applied by `SubAgentRunner.applyProfileSettings` from TaskTool
**and** again inside `SubAgentRunner.run`:

| Field | Effect |
|---|---|
| `maxTurns` | Tightens the iteration cap (`min(default, maxTurns)`). Explore/plan default 12; else 15. |
| `permissionMode` | Child `executionMode` (overrides parent). |
| `background == true` | Treated as `run_in_background` **only if** the parent omitted `run_in_background` / `background`. An explicit parent flag wins. |
| `thoughtLevel` | Mapped to `ThinkingEffort` + `ThinkingModelScanner.detect(modelId:)` → `ThinkingRequestConfig`. Unrecognized / non-thinking models keep the parent thinking config. |
| `model` | Same parent `BackendIdentifier`; new `ModelDescriptor(id:displayName:)`. No new backend. Empty id skipped. |

## Mailbox

Agent id format: `agent_<uuid>` via `AgentMailbox.makeAgentId` /
`normalizeAgentId`. Spawn meta includes `id`, `agent_id`, and `task_id`
(BackgroundJobManager UUID).

| When | Call |
|---|---|
| After job register (TaskTool) and at `run` start | `markRunning` |
| Each child iteration start | `drain` → if messages, append a user turn `Message from coordinator: …` |
| Child `run` finishes (success, cap, cancel, stream error) | `markCompleted` |

Helpers (testable):

- `SubAgentRunner.formatCoordinatorMessages`
- `SubAgentRunner.drainAndFormatCoordinatorMessages`

`send_message` extras `mailbox_resume` is **not** consumed here (parent
loop). Resume is explicit:

### `resume_agent_id`

Optional TaskTool param. When set, skip spawn and call
`SubAgentRunner.resumeIfRequested(agentId:)`:

1. `consumeResumeRequest`
2. `drain` messages
3. If resume was requested and a process-local spawn record exists,
   `markRunning` and start a **background** job whose prompt is the
   drained coordinator text (or “Please continue.” if empty).

No spawn record (different process / never spawned here) → error
result, no job.

## Unchanged

- Depth max 1 (`ToolContext.subagentDepth >= 1` refuses, including resume).
- `task` stripped from child allowlists.
- Worktree isolation (`isolation=worktree`) unchanged; success keeps
  the tree, cancel/fail discards.

## Tests

`Tests/AgentCoreTests/ParitySubagentRuntimeTests.swift`
