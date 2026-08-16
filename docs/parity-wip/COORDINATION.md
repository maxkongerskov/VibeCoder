# ZCode parity implementation — coordinator contract

Parent orchestrator owns sequencing. Child agents have **exclusive file
ownership**. Never edit a file you do not own. If you need a change in
someone else's file, write the requested snippet into your note at
`docs/parity-wip/<your-id>.md` and stop.

## Shared extras contract (`ToolResult.extras`)

Use these keys only (string values):

| Key | Value | Meaning |
|---|---|---|
| `request_execution_mode` | `plan` / `build` / `edit` / `yolo` | Tool asks loop to switch mode |
| `plan_approved` | `true` / `false` | ExitPlanMode user decision |
| `unlocked_deferred` | existing | already used by tool_search |
| `stop_continue` | `true` | reserved — hooks use typed API, not extras |

## Settings

Do **not** edit `AppSettings.swift`. Put new knobs as `public enum` defaults
in your own file (e.g. `ModelIORecorder.enabledDefault`). Wave-2 may wire
settings later.

## Tests

Each agent writes **new** test files only under `Tests/AgentCoreTests/`,
named `Parity<Topic>Tests.swift`. Do not edit existing test files.

## Style

Match surrounding Swift (strict concurrency, Sendable, no force-unwraps in
new code, short factual comments only). SPM auto-picks up new files under
`Sources/AgentCore/`. Do not touch `Package.swift` or `App/project.yml`.

## Wave 1 owners (parallel)

| id | Owns (exclusive) | Must not touch |
|---|---|---|
| `prompt` | `Agent/AgentSystemPromptComposer.swift`, NEW `Agent/GitStatusSnapshot.swift`, NEW `Agent/ZCodeBehaviorPrompt.swift` | AgentLoop, ToolRegistry |
| `compact` | `Compaction/FullReplaceCompactor.swift`, `Safety/SemanticCompactor.swift`, `Agent/ToolResultCompressor.swift`, NEW `Agent/ContextOverflowClassifier.swift`, NEW `Agent/MicroCompactor.swift`, NEW `Agent/RapidRefillBreaker.swift` | AgentLoop, ToolRegistry |
| `perms` | `Safety/PermissionRules.swift`, `Safety/ToolAuthorization.swift` | AgentLoop, tools |
| `hooks` | `Hooks/HookDispatcher.swift` | AgentLoop |
| `sessionctx` | NEW `Tools/Builtins/ReadSessionContextTool.swift`, NEW `Conversation/ConversationSearch.swift` | ConversationStore.swift (read only), ToolRegistry |
| `cron` | NEW `Tools/Builtins/CronTools.swift` | SchedulerService.swift, ScheduledTaskStore.swift (read + call public API only) |
| `trace` | NEW `Diagnostics/ModelIORecorder.swift` | OpenAICompatibleClient, AppSettings |
| `profiles` | `Agent/AgentDefinition.swift`, `Agent/AgentDefinitionDiscovery.swift`, NEW `Tools/Builtins/SendMessageTool.swift`, NEW `Agent/SubAgents/AgentMailbox.swift` | TaskTool, SubAgentRunner, ToolRegistry |
| `planmode` | NEW `Tools/Builtins/PlanModeTools.swift` | ExecutionMode.swift (read only), AgentLoop |

## Wave 2 owners (after wave 1)

| id | Owns |
|---|---|
| `loop` | `Agent/AgentLoop.swift`, `Agent/ChatLoop.swift` |
| `subagents` | `Tools/Builtins/TaskTool.swift`, `Agent/SubAgentRunner.swift`, `Agent/SubAgents/SubagentCatalog.swift` |
| `registry` | `Tools/ToolRegistry.swift`, `App/Views/Settings/ToolsSettingsView.swift` (catalog names only) |
| `client` | `Backends/OpenAICompatibleClient.swift` |
