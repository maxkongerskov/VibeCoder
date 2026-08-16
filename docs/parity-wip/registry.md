# registry — wave-2 ToolRegistry + Settings catalog

Owner: `registry`. Exclusive files:

- `Sources/AgentCore/Tools/ToolRegistry.swift`
- `App/Views/Settings/ToolsSettingsView.swift` (`BuiltinToolCatalog` names + toggle rows only)

Did not edit AgentLoop, TaskTool, or tool implementations.

## `registerBuiltins()`

Added (type names verified against `Tools/Builtins/`):

| Type | `Tool.name` |
|---|---|
| `ReadSessionContextTool` | `read_session_context` |
| `CronCreateTool` | `cron_create` |
| `CronListTool` | `cron_list` |
| `CronUpdateTool` | `cron_update` |
| `CronDeleteTool` | `cron_delete` |
| `SendMessageTool` | `send_message` |
| `EnterPlanModeTool` | `enter_plan_mode` |
| `ExitPlanModeTool` | `exit_plan_mode` |

Already registered (unchanged): `git_commit`, `create_pull_request`,
`list_background_jobs`, `monitor_jobs`.

## Parallel-safe execute set

```swift
public static let parallelSafeExecuteTools: Set<String> = ["task"]
```

Source of truth for isolated-spawn overlap. **Dispatch is unchanged** —
`AgentLoop` still owns how batches run.

## Settings catalog (`BuiltinToolCatalog`)

`registeredBuiltinNames` + `all` rows now include the eight new tools and
the four previously registered names that were missing from Settings:

| Name | Category |
|---|---|
| `read_session_context` | memory |
| `cron_create` / `cron_list` / `cron_update` / `cron_delete` | planning |
| `enter_plan_mode` / `exit_plan_mode` | planning |
| `send_message` | agent |
| `git_commit` / `create_pull_request` | git |
| `list_background_jobs` / `monitor_jobs` | agent |

App-target `BuiltinToolCatalog` is not visible to `AgentCoreTests`.

## Tests

`Tests/AgentCoreTests/ParityRegistryTests.swift` — after
`registerBuiltins()`, `registeredNames()` contains the new names.

```
swift test --filter ParityRegistryTests
```

`ToolRegistryTests.testBuiltinsRegister` required-names list also includes
the new tools.

## Loop / subagents (not this owner)

- Honor `enter_plan_mode` / `exit_plan_mode` extras (`request_execution_mode`,
  `plan_approved`) — see `docs/parity-wip/planmode.md`.
- Strip Enter/Exit plan-mode tools from child agents (parent-only).
- Drain `send_message` mailbox after `task` spawn — see `profiles.md`.
