# Wave U3 — exclusive file ownership

The original plan was sequential (shared `RootView`). Parallel fan-out works
if children **never edit hub files**. Parent glues `RootView`, `VibeCoderApp`,
and palette after release.

**Never edit a file you do not own.** Snippets for others go in
`docs/ui-parity-wip/<id>.md`.

Do **not** edit: `Package.swift`, `App/project.yml`, `docs/UI_PARITY_WITH_ZCODE.md`,
another agent's files, existing tests. New tests only.

## Owners

| id | Exclusive | Must not touch |
|---|---|---|
| `sidepane` | NEW `App/Views/Panels/**` + NEW `App/Tests/InspectorPanelUITests.swift` | RootView, VibeCoderApp, ChatView, AppViewModel, Terminal/** |
| `terminal` | NEW `App/Views/Terminal/**` + NEW `App/Tests/TerminalSessionUITests.swift` | RootView, VibeCoderApp, ChatView, AppViewModel, Panels/** |
| `statuscapsule` | NEW `App/Views/Chat/StatusCapsuleView.swift` (+ helper NEW files under `App/Utilities/` or `App/ViewModels/`), `App/Views/ChatView.swift`, NEW `App/Tests/StatusCapsuleUITests.swift` | RootView, VibeCoderApp, InputBarViewV2, ChatViewModel, Panels/**, Terminal/** |

**Unowned (parent glue only):** `RootView.swift`, `VibeCoderApp.swift`,
`AppViewModel.swift`, `ChatViewModel.swift`, `CommandPaletteView.swift`.

Notifications you define live in **your** files (same pattern as
`FindInTaskOverlay.findInTaskRequested`). Do not add names to RootView.

## Compile / test

- `cd /Users/maxkongerskov/vibecoder`
- App sources auto-glob — no `project.yml` edits.
- New App tests: `App/Tests/<Topic>UITests.swift`
- AgentCore work (if any) → NEW `Tests/AgentCoreTests/Parity<Topic>Tests.swift` only.
- macOS has **no** `flock`. Don't wait on other agents' builds.

## Parent glue (after children)

1. `navigationSplit`: `.modifier(InspectorPanelAttach())` (name from sidepane note).
2. `DetailPane` body: `.safeAreaInset(edge: .bottom, spacing: 0) { TerminalDockHost() }`.
3. `VibeCoderApp` View menu: Toggle Side Pane (⌥⌘B) + Toggle Terminal (⌘J) posting
   the notifications defined by those agents. **Do not** put ⌘F-style shortcuts on
   a colliding system menu item without `CommandGroup`.
4. Palette items `toggle-side-pane` / `toggle-terminal` from snippets.

Then: `swift test --filter Parity`; `xcodegen generate`; `xcodebuild` Debug;
live-toggle inspector + terminal.

## Parent glue insertion points (do not apply until children release)

`navigationSplit` (`RootView` ~183): after `RemoveWindowTitleModifier`, add
`.vibecoderInspectorPanel()` (or the name in `sidepane.md`).

`DetailPane.body` (~587): wrap the `if/switch` in a Group and
`.safeAreaInset(edge: .bottom, spacing: 0) { TerminalDockHost() }`.

`VibeCoderApp` `CommandMenu("View")` after Stop Agent: Toggle Side Pane +
Toggle Terminal (exact titles/notifications from child notes).

`commandPaletteItems` / `runCommandPaletteItem`: two Panels items from notes.
