# Wave U2 — `queue`

ZCode-style **queue-while-running** + **Steer** + **Compress**. Send no longer interjects; Steer is the old `InterjectionBuffer` path.

## What shipped

- While `isRunning`, composer Send / Return **enqueues** a follow-up (`enqueueFollowUp`). Status: `Queued — will send after this turn` / `N messages queued`.
- Visible **Queued messages (N)** bar inside the input card: truncated mono text, **Steer** · **Run now** · **Remove**, up/down reorder.
- **Steer** = remove from queue + existing mid-turn interjection (epoch / peekCount / “Turn ended — interjection not applied.”).
- **Run now** on `/compact` or `/compress` [instructions] calls `handleSlashCommand("/compact…")` immediately (not Steer). Other items move to front; idle → `send(_:)`.
- **Stop** still clears `InterjectionBuffer`. Visible queue **survives**; `queuePaused = true` + banner *The queue was paused because you stopped.* + **Continue**.
- After a successful turn (`finishRun`, `isRunning = false`): interjections cleared; queue kept; if not paused, dequeue first and `send` on the next MainActor tick (compact slash is dispatched via `handleSlashCommand`, not as a user bubble).
- **Compress** chip next to the context meter posts `Notification.Name.compactConversationRequested` (`agentos.compactConversation`). Selected `ChatViewModel` runs `/compact`.
- Placeholder while running: `Keep typing to queue…`. Send help/a11y while running: **Queue message**. Stop stays Esc / red square.
- Idle compose path (pins, attachments, skill envelopes, hooks, `isRunning = true`) is unchanged.

### Idle send while the queue is non-empty

**Keep the queue** (no confirm sheet — ChatView is not ours). The new send runs now; existing items stay queued and flush after this turn. A paused queue is **unpaused** so that flush still happens.

## Files

| File | Role |
|---|---|
| `App/ViewModels/ComposerQueueStore.swift` | **NEW** — `ComposerQueueItem`, pure store, compact classifier, `Notification.Name.compactConversationRequested` |
| `App/ViewModels/ChatViewModel.swift` | Queue published state + send/cancel/finishRun + Compress observer |
| `App/Views/Chat/ComposerQueueBar.swift` | **NEW** — queue chrome (Theme tokens) |
| `App/Views/Chat/InputBarViewV2.swift` | Mount bar, placeholder, Queue message, Compress chip |
| `App/Tests/ComposerQueueUITests.swift` | **NEW** — store + VM wrap tests |
| `docs/ui-parity-wip/queue.md` | This note |

Did **not** edit: MentionAwareComposer, ChatView, RootView, ZCodeSidebar, VibeCoderApp, StickyContextPin, Package.swift, project.yml, existing tests, `UI_PARITY_WITH_ZCODE.md`. New `InputBarViewV2` stored properties: none (MentionAwareComposer call site unchanged).

## Tests

`App/Tests/ComposerQueueUITests.swift` (`@testable import VibeCoderApp`):

- enqueue reject empty / trim / append
- reorder + remove (`move`, up/down)
- Steer removes item (store-level)
- pause-on-stop; paused `takeNextAfterTurn` is nil
- continue returns next text when idle; nil when still running
- `/compact` + `/compress` classified as `compactSlash` (Run now), not Steer
- VM: `send` while `isRunning` enqueues (no AgentLoop); hook deny; cancel pauses; Steer/remove/reorder; Run now on `/compress` consumes slash

```
xcodebuild test -scheme VibeCoder -destination 'platform=macOS' \
  -only-testing:VibeCoderTests/ComposerQueueStoreTests \
  -only-testing:VibeCoderTests/ComposerQueueViewModelTests
```

**TEST SUCCEEDED** — 15 cases (9 store + 6 VM).

## Snippets for parent

None required. Compress is a notification the owned VM already observes. Queue bar is mounted **inside** `InputBarViewV2`.

Optional later (not owned here): ChatView `handleSend` intercepts known slash commands **before** `send()`, so typing `/compact` while a turn is running still compact-now and never lands in the queue. `/compress` is not in the slash catalog, so it *does* queue and Run now remaps to `/compact`.

## Open issues

- No in-place **Edit** on a queued row (ZCode has it). Remove + retype.
- No drag-reorder (up/down only).
- No ZCode “Clear the N previously queued messages?” confirm on idle send — we keep the queue (documented above).
- Composer `/compact` while running is handled by ChatView’s slash intercept, not the queue.
- Compress chip is shown only when the context meter is visible (`showContextMeter`).
