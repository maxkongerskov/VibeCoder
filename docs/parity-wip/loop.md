# Wave 2 — `loop`

Owner: `loop`. Exclusive files: `Sources/AgentCore/Agent/AgentLoop.swift`
(and `ChatLoop.swift` only if compactHistory needed a change — it did not).

## Wired into `AgentLoop.run`

### 1. Reactive compact on context-exceeded

`backend.stream` catch: if `ContextOverflowClassifier.isContextExceeded`
(error or description) **and** this step has not already reactive-compacted:

1. Hard-stop if `RapidRefillBreaker.shouldHardStop()` (`rapid refill blocked`).
2. `FullReplaceCompactor.compact` on persisted `convo` (Semantic if FR
   drops nothing). Budget = `contextBudgetTokens` or half the current
   estimate.
3. `recordCompact()` only when history actually shrank.
4. Hard-stop again if the breaker trips.
5. Decrement `iteration` and `continue` (same model step).

A second overflow on the retry finishes the turn (existing error path +
`fireStopHook`). `max_tokens` / finish-reason `length` is not overflow.

### 2. Rapid-refill breaker

One `RapidRefillBreaker` per `run()`.

| Event | Action |
|---|---|
| Persisted FullReplace/Semantic shrink (reactive) | `recordCompact()` |
| Completed tool-result batch (not cancelled mid-dispatch) | `recordToolTurn()` |
| `shouldHardStop()` before/after reactive compact, or before proactive FR | finish with `"rapid refill blocked"` + `fireStopHook` |

Wire-only Micro / FullReplace / Semantic (proactive, not assigned back to
`convo`) do **not** `recordCompact()`. They run every iteration against
the full persisted transcript; counting them would trip the breaker on
any long over-budget session.

### 3. Micro-compact on the wire copy

Each iteration, before `backend.stream`:

1. `MicroCompactor.compact(messages:)` on a **copy**
2. `ToolResultCompressor.compress`
3. FullReplace then Semantic (existing, still wire-only)
4. `ChatLoop.compactHistory` when a budget is set

Persisted `convo` stays full — same as today's FullReplace persistence.

### 4. Stop-hook continuation

Natural **no-tool** finish (after interjections, finishHalt, grounding /
edit-verify, goal continue) calls `HookDispatcher.stopDetailed` **not**
`stop`. If `shouldContinueAfterStop`, inject
`formatHookAdditionalContext` as a user-role `# System reminder — hook`
message and `continue`. Cap: `continuationCount < maxStopContinuations`.

That path already ran the Stop handlers — trailing `fireStopHook` is
skipped (`stopHookAlreadyFired`).

`fireStopHook` / `HookDispatcher.stop` still used on cap, cancel, SessionStart
deny, goal pause, stall/governor, error after failed reactive compact,
rapid-refill hard-stop.

### 5. Plan-mode extras

`recordToolResult` on a successful result:

| extras | Action |
|---|---|
| `request_execution_mode` = valid `ExecutionMode` rawValue | Rebuild `ToolContext` with that mode |
| `plan_approved` = `true` | Set `planModeExited` (subsequent tools can mutate) |
| `plan_approved` = `false` | Ignore `request_execution_mode` |

Conversation has no `executionMode` field — live `ToolContext` is the
session gate. `unlocked_deferred` unchanged.

### 6. Parallel `task` fan-out

After the read-only batch: consecutive invocations named `task` (max 10)
run via `withTaskGroup` + `dispatchOne`. Results recorded in invocation
order. Serial `while` skips `task` so leftovers of 11+ are batched on
the next outer pass. `run_shell` / `write_file` / other executes stay
serial.

## Tests

`Tests/AgentCoreTests/ParityLoopIntegrationTests.swift`

- Classifier-driven overflow → one compact retry → no-tool finish
- Second overflow after that retry still fails the turn
- Stop `continue` + `additionalContext` injects and takes another stream
- Micro-compact on the wire, not on persisted `convo`
