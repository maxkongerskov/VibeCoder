# Plan mode tools — loop integrator

Wave-1 owner: `planmode`. New tools live in
`Sources/AgentCore/Tools/Builtins/PlanModeTools.swift`. Do **not** expect
them to change `ExecutionMode` themselves.

Wave-2 `registry` must add (also commented at the top of that file):

```
register(EnterPlanModeTool.self)
register(ExitPlanModeTool.self)
```

Do not register from this note; `ToolRegistry.swift` is owned by `registry`.

## Honor `ToolResult.extras`

`AgentLoop.recordToolResult` currently only reads `unlocked_deferred`.
These tools speak through the shared extras contract in
`docs/parity-wip/COORDINATION.md`. The loop (owner: `loop`) must apply
them after a successful (non-error) tool result:

| Tool | extras | Loop action |
|---|---|---|
| `enter_plan_mode` | `request_execution_mode` = `plan` | Switch session `ExecutionMode` to `.plan` (read-only gate). |
| `exit_plan_mode` | `request_execution_mode` = `build`, `plan_approved` = `true` | After user approval, switch to `.build` and treat the turn as plan-exited (`ToolContext.planModeExited`). |

Do not fold extras into model-visible content. The tool result `content`
is already what the model should see.

### Approval gate

ZCode's `ExitPlanMode` is `requiresUserInteraction`. This tool always
emits `plan_approved=true` and the "start implementing" content because
it has no UI. The loop / host should:

1. Intercept `exit_plan_mode` (or its extras) and show the `plan`
   argument for user review.
2. On approve: apply `request_execution_mode=build`, keep
   `plan_approved=true`, leave the tool content as-is (or inject the
   same "The plan was recorded. Start implementing." + plan text).
3. On reject: do **not** switch mode. Rewrite extras to
   `plan_approved=false` (omit or ignore `request_execution_mode`) and
   return model content `"The plan was not approved by the user."`

Until that gate exists, honoring extras immediately will flip plan →
build on the tool call, which matches the current product
`approvePlanAndContinue` destination (`ExecutionMode.build`).

### Persist

`exit_plan_mode` already persists best-effort:

- `PlanStore.setPlan` keyed by `ToolContext.conversationID` (full plan
  text as the goal) when a conversation id is present.
- Raw markdown to `ToolContext.sessionPlanFileURL` (`plan.md`) when a
  workspace / plan file URL is bound.

If persist fails the tool still returns the plan in `content`. The loop
does not need to write the file again.

### Permissions

Both tools are `ToolPermission.readOnly`. Mode switch is extras, not a
file mutation (`mutatedPaths` is empty). Plan-mode authorization already
allows `create_plan` / `update_todo` / `revise_plan` and writes to the
session `plan.md`.

### Subagents

ZCode strips Enter/Exit plan-mode tools from child agents. When
`subagents` / `registry` wire these names, keep them parent-only.
