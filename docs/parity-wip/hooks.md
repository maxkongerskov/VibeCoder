# Hooks — AgentLoop call contract (wave 2)

Owner: `hooks` (`Sources/AgentCore/Hooks/HookDispatcher.swift`).
Do **not** edit `AgentLoop.swift` from this track. Wave-2 `loop` must switch
the call sites below.

ZCode semantics (`agent-loop.md` §5): Stop `continue: true` + additionalContext
forces ≤3 more model steps; PreToolUse may deny / ask / allow and rewrite
`tool_input` via `updatedInput`; exit 2 / `decision: block` still deny.

---

## Constants

| Symbol | Value | Meaning |
|---|---|---|
| `HookDispatcher.maxStopContinuations` | `3` | Honor Stop-continue at most this many times per turn |
| `HookDispatcher.denyExitCode` | `2` | Process exit → deny |
| `HookDispatcher.eventPermissionRequest` | `"PermissionRequest"` | Config key; optional fire |
| `HookDispatcher.eventPostToolUseFailure` | `"PostToolUseFailure"` | Config key; optional fire |
| `HookDispatcher.eventPreToolUse` | `"PreToolUse"` | |
| `HookDispatcher.eventStop` | `"Stop"` | |
| `HookDispatcher.eventSessionStart` | `"SessionStart"` | |
| `HookDispatcher.eventUserPromptSubmit` | `"UserPromptSubmit"` | |
| `HookDispatcher.eventPostToolUse` | `"PostToolUse"` | |
| `HookDispatcher.eventNotification` | `"Notification"` | |

`config.json` / `hooks.json` may declare `PermissionRequest` and
`PostToolUseFailure` (nested or snake_case). Parse is fail-open; declaring
them does not crash.

---

## 1. Stop continuation (required)

When a model step ends with **no tool calls** (natural `stop` / `end_turn`),
**do not** call `HookDispatcher.stop`. That wrapper only returns
`HookDecision` and **drops** `continue` / `additionalContext`.

Call:

```swift
let stop = HookDispatcher.stopDetailed(
    reason: reason,                          // e.g. "finished"
    projectRoot: conversation.projectRoot,
    worktreeRoot: conversation.worktreeRootURL
)

if HookDispatcher.shouldContinueAfterStop(stop, continuationCount: n) {
    let body = HookDispatcher.formatHookAdditionalContext(
        [stop.additionalContext].compactMap { $0 }
    )
    // Inject `body` as a hook_context user/system-reminder attachment.
    // Treat hook output as user feedback (system-prompt already says so).
    n += 1
    // continue the model loop (do not break)
} else {
    // break / finish the turn
}
```

`shouldContinueAfterStop` is the ZCode gate:

- `stop.allow == true`
- `stop.shouldContinue == true` (`continue: true` in hook JSON)
- `stop.additionalContext` non-empty (`additionalContext` or `additional_context`)
- `continuationCount < HookDispatcher.maxStopContinuations` (3)

A deny (`decision: "block"` / `"deny"`, or exit 2) sets `allow = false` and
**never** continues.

Keep `HookDispatcher.stop` (or `fireStopHook`) for paths where the turn is
**already ending**: iteration cap, cancel, SessionStart deny, halt. Those must
not honor `continue`.

---

## 2. PreToolUse (required)

Before permission check + tool execute (both `ToolRegistry.execute` and
AgentLoop MCP path), **do not** stay on `HookDispatcher.preTool` if you need
input rewrite or ask. Call:

```swift
let pre = HookDispatcher.preToolDetailed(
    toolName: name,
    argumentsSummary: argumentsJSON,         // prefer raw tool-input JSON
    projectRoot: context.projectRoot,
    worktreeRoot: context.worktreeRoot
)
```

Then, in order:

1. If `pre.allow == false` **or** `pre.permissionDecision == "deny"` →
   do not run the tool. Surface `pre.message` as the error result.
2. If `pre.updatedInputJSON != nil` → replace the tool arguments with that
   JSON object **before** authorize / execute.
3. If `pre.permissionDecision == "ask"` → escalate to the user (permission
   ask) even if the current mode would auto-allow.
4. If `pre.additionalContext` is non-empty → inject via
   `formatHookAdditionalContext` (same hook_context channel as Stop).
5. Otherwise proceed (`permissionDecision` `allow` / nil).

`HookDispatcher.preTool` still wraps `preToolDetailed` and preserves
deny-still-deny / allow-still-allow. `ask` maps to **allow** on the old
`HookDecision` path (no ask bit). Wave-2 loop must use the detailed API.

---

## 3. Optional later (config already parses)

Fire when the pipeline is about to ask the user:

```swift
_ = HookDispatcher.permissionRequest(
    toolName: name,
    payload: argumentsJSON,
    projectRoot: context.projectRoot,
    worktreeRoot: context.worktreeRoot
)
```

Fire after a failed tool (in addition to `postTool`):

```swift
_ = HookDispatcher.postToolUseFailure(
    toolName: name,
    errorSummary: String(result.content.prefix(200)),
    projectRoot: context.projectRoot,
    worktreeRoot: context.worktreeRoot
)
```

---

## Hook stdout JSON (what the dispatcher already parses)

Stop:

```json
{ "continue": true, "additionalContext": "run the test suite" }
```

(`additional_context` alias accepted.)

PreToolUse:

```json
{
  "permissionDecision": "allow",
  "updatedInput": { "path": "/tmp/x" },
  "additionalContext": "rewrote path"
}
```

(`updated_input` as object **or** JSON string; also under `hookSpecificOutput`.)

Deny (any event): `{ "decision": "block" }` / `"deny"`, or process **exit 2**.

---

## Result types

```swift
public struct StopHookResult: Sendable {
    public var allow: Bool
    public var shouldContinue: Bool
    public var additionalContext: String?
    public var message: String?
}

public struct PreToolHookResult: Sendable {
    public var allow: Bool
    public var permissionDecision: String? // allow|ask|deny
    public var updatedInputJSON: String?
    public var additionalContext: String?
    public var message: String?
}
```
