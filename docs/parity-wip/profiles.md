# profiles — subagent frontmatter + mailbox (wave 1)

Integrator note for wave-2 `subagents` (`TaskTool` / `SubAgentRunner`).
This agent owns parse + mailbox only; it does not spawn or drain in the loop.

## `DiscoveredAgentDefinition` (markdown)

Existing (unchanged): `name`, `description`, `systemPrompt`, `tools`, `fileURL`.

New optional frontmatter fields:

| Field | Frontmatter keys | Type | Notes |
|---|---|---|---|
| `model` | `model` | `String?` | Raw model id; host maps to `ModelDescriptor` at spawn. |
| `thoughtLevel` | `thoughtLevel`, `thought_level`, `thought-level`, else `effort` | `String?` | `thoughtLevel` wins if both set. |
| `permissionMode` | `permissionMode`, `permission_mode`, `permission-mode` | `ExecutionMode?` | See mapping below. |
| `maxTurns` | `maxTurns`, `max_turns`, `max-turns` | `Int?` | Positive ints only; `0` / junk → nil. |
| `background` | `background` | `Bool?` | `true/false/yes/no/on/off/1/0`. |

`tools` / `allowed-tools` / `allowed_tools` and the body system prompt are unchanged.

Typed bag: `discovered.profileSettings` → `AgentProfileSettings` (also stored on
`AgentDefinition.profileSettings`, default `.empty`).

### `permissionMode` mapping (`AgentProfileSettings.parsePermissionMode`)

| Input (case-insensitive; `_` / `-` ignored) | `ExecutionMode` |
|---|---|
| `plan` | `.plan` |
| `build` | `.build` |
| `edit`, `acceptEdits` | `.edit` |
| `yolo`, `bypassPermissions` | `.yolo` |
| anything else | `nil` |

## `AgentMailbox` (`Sources/AgentCore/Agent/SubAgents/AgentMailbox.swift`)

Actor, process-wide `AgentMailbox.shared`, or `AgentMailbox(diskRoot:)` for
optional JSON persistence (`<diskRoot>/<agentId>.json`).

IDs: `agent_<uuid>` via `AgentMailbox.makeAgentId()` /
`normalizeAgentId` (bare UUID → `agent_<uuid>`).

```
send(to:summary:message:from:) -> SendResult
  // SendResult.message, SendResult.resumeRequested
drain(agentId:) -> [Message]
peek(agentId:) -> [Message]
state(agentId:) -> AgentState          // messages, completed, resumeRequested
resumeRequested(agentId:) -> Bool
isCompleted(agentId:) -> Bool
markCompleted(_:)
markRunning(_:)                        // completed=false + clear resume
setCompleted(_:completed:)
clearResumeRequested(_:)
consumeResumeRequest(agentId:) -> Bool // peek+clear
setDiskRoot(_:)
reset()
```

`Message`: `id`, `to`, `from`, `summary`, `message`, `createdAt`.

Resume: `markCompleted` then `send` sets `resumeRequested = true`. `drain`
does **not** clear that flag — consume it when you actually resume the child.

## `send_message` (`SendMessageTool`)

- name `send_message`, permission `.executes`, category `.agent`, availability `.core`
- params: `to`, `summary` (5–10 words), `message` (ZCode SendMessage copy, names adapted)
- writes `AgentMailbox.shared`
- extras: `mailbox_resume` = `"true"` when the target was completed (resume requested)
- not registered in `ToolRegistry` (wave-2 `registry` owner)

Wave-2: after `task` spawn, register `agent_<uuid>`, `markCompleted` on finish,
drain mailbox at child loop boundaries, and if `consumeResumeRequest` then
restart `SubAgentRunner` in background with the drained `message` as the prompt.
