# cron — model-facing schedule tools

Wave-1 owner for `cron`. Exclusive file: **NEW**
`Sources/AgentCore/Tools/Builtins/CronTools.swift`.
Did not edit `SchedulerService.swift`, `ScheduledTaskStore.swift`, or
`ToolRegistry.swift`.

## Shipped

Four `Tool` types, ZCode `Cron*` descriptions adapted to VibeCoder
snake_case names and the existing `TaskFrequency` model (not 5-field cron):

| Tool | Maps to | Persist |
|---|---|---|
| `cron_create` | `CronCreate` | `ScheduledTaskStore.add` |
| `cron_list` | `CronList` | `load()` |
| `cron_update` | `CronUpdate` | `update` (patch; omitted fields kept) |
| `cron_delete` | `CronDelete` | `remove(id:)` |

Shared metadata: **category `planning`**, **permission `mutates`**,
**availability `core`**. Descriptions state that **schedules run only
while the app is open**.

### `cron_create`

- Required: `name`, `prompt`, `frequency` (`manual|hourly|daily|weekdays|weekly`).
- Optional: `timeOfDayMinutes` (0–1439), `projectFolder` (defaults to
  `context.usableWorkspaceRoot`).
- `prompt` is written to both `shortPrompt` and `longPrompt` (same as `/loop`).
- `setupComplete = true` so `SchedulerService.shouldFire` will consider them.
- Cap: if `load().count >= 20`, error content is exactly
  `Error: do not retry; schedule limit reached`.

### Store

`ScheduledTaskStore` has **no** `shared` singleton. Tools call
`ScheduledTaskStore()` (default dir = UI / boot-time scheduler) unless
tests set:

```swift
CronToolStore.override = ScheduledTaskStore(directoryURL: tempDir)
// tearDown: CronToolStore.override = nil
```

No `SchedulerService` change is required: `tick()` already `reload()`s,
so tasks the model creates appear on the next poll.

## Wave-2 registry snippet (do not apply in wave 1)

`Sources/AgentCore/Tools/ToolRegistry.swift` `registerBuiltins()`:

```swift
register(CronCreateTool.self)
register(CronListTool.self)
register(CronUpdateTool.self)
register(CronDeleteTool.self)
```

These four lines are also in the `CronTools.swift` file header.

`Tests/AgentCoreTests/ToolRegistryTests.swift` required-names list (when
you own that file): add `"cron_create", "cron_list", "cron_update", "cron_delete"`.

## Tests

`Tests/AgentCoreTests/ParityCronToolsTests.swift` — temp-dir store via
the override hook. Run:

```
swift test --filter ParityCronToolsTests
```

## Out of scope (parity §12 P2)

- Persist-and-fire while the app is quit (launchd / re-arm on boot).
- Z.ai off-peak cloud runs.
- ZCode 5-field cron / `delayMinutes` / `interval` / `maxRuns` — VibeCoder
  frequencies are the five `TaskFrequency` cases already used by the UI.
