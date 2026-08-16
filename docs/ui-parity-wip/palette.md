# Wave U1 — `palette`

Command palette expansion + keyboard selection. Owns
`App/Views/CommandPalette/CommandPaletteView.swift` and
`RootView.commandPaletteItems` / `runCommandPaletteItem` only.

## Items

Kept the original 12 (same ids, titles, effects):

| id | title | category |
|---|---|---|
| `new-chat` | New Conversation | Chat |
| `clear-chat` | Clear Conversation | Chat |
| `compact` | Compact Conversation | Chat |
| `session-info` | Session Info | Chat |
| `fork-chat` | Fork Conversation | Chat |
| `toggle-safe-mode` | Enable/Disable Safe Mode | Safety |
| `cycle-mode` | Cycle Permission Mode | Safety |
| `mode-plan` | Plan Mode | Safety |
| `choose-model` | Choose Model | Model |
| `open-settings` | Open Settings | App |
| `open-projects` | Projects | App |
| `open-scheduled` | Scheduled Tasks | App |

Added 8:

| id | title | category | effect |
|---|---|---|---|
| `toggle-theme` | Theme: System/Light/Dark | App | cycles `app.settings.colorScheme` system → light → dark (persists via existing `settings` didSet) |
| `prev-task` | Previous Task | Chat | previous row in `sidebarOrderedConversations()` (pinned first, `updatedAt` desc, archived already omitted); no-op at start / no selection |
| `next-task` | Next Task | Chat | next row in that list; no-op at end |
| `export-conversation` | Export Conversation | Chat | posts `.exportConversationRequested` with selected id (same name as `/export`); switches to Chat first if needed, then **one** deferred post so `ChatView` is mounted. Does **not** re-post from the existing RootView receiver |
| `open-notes` | Open Notes | App | `selectedTab = .notes` |
| `open-models` | Open Models | App | posts `.openModelsPane` (existing handler closes Settings + selects Models) |
| `new-project` | New Project | App | `selectedTab = .projects` only (see open items) |
| `stop-agent` | Stop Agent | Safety | posts `.cancelAgentRequested` |

**Open Scheduled:** already present as `open-scheduled` / “Scheduled Tasks”. Not duplicated.

Palette now has **20** commands. Filter API (`CommandPaletteFilter` / `CommandPaletteItem`) unchanged.

## Key handling

- Search field still focused on appear; query cleared each open.
- ↑ / ↓ move a highlighted row across the **flattened** filtered list (headers skipped). Wraps at both ends.
- Enter / Return runs the **focused** item. If the user never moved focus (and never hovered), that is the first match — same as the old “run first” behavior.
- Esc / dim tap dismiss (unchanged `.onExitCommand` + dim).
- Query change resets focus to “first match”.
- Hover sets focus so Enter runs the hovered row.
- Focused row uses `Theme.Palette.hover` fill; `ScrollViewReader` keeps it on screen.
- TextField swallows arrows, so a local `NSEvent` keyDown monitor also consumes unmodified ↑/↓ while the overlay is up. `onKeyPress` on the field is a fallback; the monitor eats the event first so they do not double-step.
- Trailing kbd hints (SF Mono 11, tertiary) by id: New Conversation `⌘N`, Open Settings `⌘,`, Stop Agent `⌘.`, Cycle Permission Mode `⇧Tab`.
- Visible items grouped under uppercase 10 pt tertiary headers: **CHAT / SAFETY / MODEL / APP** (unknown categories append in first-seen order). Order inside a section is the items-array / filter order.
- Category capsules on rows were dropped — redundant with section headers.

## Test / build

| Check | Result |
|---|---|
| `cd …/vibecoder && swift build` | **ok** (3.7s) |
| `swift test --filter CommandPalette` | **0 SPM tests** (filter lives in the App target; no core regression) |
| `xcodebuild … -scheme VibeCoder … build` (`/tmp/vc-u1/dd-palette`) | **BUILD SUCCEEDED** |
| `xcodebuild … test -only-testing:VibeCoderTests/CommandPaletteFilterTests` | **TEST SUCCEEDED** — 2/2 (`testEmptyQueryReturnsAllItems`, `testFilterMatchesTitleCategoryAndKeywords`) |

`flock` is not installed on this Mac; the xcodebuild still completed without killing other processes.

## Open items

1. **New Project sheet.** `showNewSheet` is `@State` inside `ProjectsView`. Opening the sheet from the palette needs a notification (or similar) owned by ProjectsView. Suggested snippet (do not apply from this wave):

```swift
// Notification.Name (next to the existing RootView names):
static let newProjectSheetRequested = Notification.Name("agentos.newProjectSheet")

// runCommandPaletteItem "new-project":
selectedTab = .projects
NotificationCenter.default.post(name: .newProjectSheetRequested, object: nil)

// ProjectsView body:
.onReceive(NotificationCenter.default.publisher(for: .newProjectSheetRequested)) { _ in
    showNewSheet = true
}
```

2. **Export from a non-Chat tab** relies on `DispatchQueue.main.async` after switching tab so `ChatView` is in the tree. If that ever races, the save panel will not appear (RootView still must not rebroadcast).

3. **Prev/Next Task** have no menu accelerators (ZCode ⌘⇧[ / ⌘⇧]). Out of scope — would be `VibeCoderApp.swift` `.commands`.

4. Shortcut hints are a view-side id map. Adding a `shortcut` field would require editing `CommandPaletteFilter.swift` (forbidden this wave).
