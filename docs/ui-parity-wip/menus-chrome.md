# U4 `menus-chrome` — shipped

ZCode File / View / workspace-header chrome. Exclusive files only.

## Files

| File | Role |
|---|---|
| `App/VibeCoderApp.swift` | File: New conversation ⌘N (kept), **Open Workspace… ⌘O**, **Close Window ⌘W**. View: existing palette / stop / side pane / terminal + **Toggle Sidebar ⌘B**, **Previous Task ⌘⇧[**, **Next Task ⌘⇧]**. Help → **About VibeCoder**. DEBUG ⌘⇧W untouched. |
| `App/Views/RootView.swift` | `toggleSidebarRequested` (`agentos.toggleSidebar`), `previousTaskRequested` (`agentos.previousTask`), `nextTaskRequested` (`agentos.nextTask`). `MenuChrome` helpers. Detail toolbar: side pane + terminal. Palette prev/next uses the helper. |
| `App/Tests/MenuChromeUITests.swift` | **NEW** — notification raw values, prev/next walk, sidebar `.all` ↔ `.detailOnly`. |

Did **not** edit Panels/**, Settings/**, ChatView, ChatViewModel, ZCodeSidebar, Package.swift, project.yml, `docs/UI_PARITY_WITH_ZCODE.md`. No `CommandPaletteView` shortcut-hint map (not owned).

## File menu

- **New conversation** ⌘N — still posts `.newConversationRequested`.
- **Open Workspace…** ⌘O — `NSOpenPanel` (directories only). Silent bind via `ProjectsService.register(existingFolder:)` then `app.openedProject = project` (same overlay as double-clicking a Projects card). If register fails, posts `.newProjectSheetRequested` with the picked URL.
- **Close Window** ⌘W — `CommandGroup(replacing: .saveItem)` → `NSApp.keyWindow?.performClose(nil)`. Does not replace DEBUG View → Worktree Review (⌘⇧W).

## View menu

Kept: Command Palette ⌘K, Stop Agent ⌘., Toggle Side Pane ⌥⌘B, Toggle Terminal ⌘J.

Added:

- **Toggle Sidebar** ⌘B — posts `.toggleSidebarRequested`. RootView sets `columnVisibility` `.all` ↔ `.detailOnly` via `MenuChrome.toggledSidebarVisibility`. System sidebar button stays.
- **Previous Task** ⌘⇧[ / **Next Task** ⌘⇧] — posts `.previousTaskRequested` / `.nextTaskRequested`. RootView walks `app.sidebarOrderedConversations()` with `MenuChrome.adjacentTaskID` (same as palette `prev-task` / `next-task`; no-op at ends / no selection).

## Header (detail toolbar)

`ToolbarItemGroup(placement: .primaryAction)` on the detail column:

- `sidebar.right` — Toggle Side Pane — posts `.toggleInspectorRequested`. Help: `Toggle Side Pane (⌥⌘B)`.
- `terminal` — Toggle Terminal — posts `.toggleTerminalRequested`. Help: `Toggle Terminal (⌘J)`.

Sidebar pencil (⌘N) unchanged.

## Help

**About VibeCoder** (`CommandGroup(after: .help)`) posts `.settingsRequested` with object `"about"` (existing Settings tab).

## Helpers (`MenuChrome` in RootView.swift)

```swift
enum MenuChrome {
  static func adjacentTaskID(visibleIDs: [UUID], currentID: UUID?, delta: Int) -> UUID?
  static func toggledSidebarVisibility(_ current: NavigationSplitViewVisibility)
    -> NavigationSplitViewVisibility  // .detailOnly ↔ .all
}
```

Palette `prev-task` / `next-task` call `selectAdjacentTask(delta:)` so menu and palette share the walk.

## Tests

```
xcodebuild -project App/VibeCoder.xcodeproj -scheme VibeCoder \
  -destination 'platform=macOS' -derivedDataPath /tmp/vc-u4/dd-menus \
  -only-testing:VibeCoderTests/MenuChromeUITests test
```

**TEST SUCCEEDED** — 6/6 (`testToggleSidebarNotificationName`, `testPreviousTaskNotificationName`, `testNextTaskNotificationName`, `testAdjacentTaskIDWalksVisibleList`, `testAdjacentTaskIDNilWhenMissingOrEmpty`, `testSidebarVisibilityTogglesAllAndDetailOnly`).

`cd App && xcodegen generate` was needed so the new test file was in the pbxproj (project.yml untouched).

## Parent glue

None. Notifications live in RootView (owned). `.toggleInspectorRequested` / `.toggleTerminalRequested` stay defined in InspectorPanelAttach / TerminalDockSupport.
