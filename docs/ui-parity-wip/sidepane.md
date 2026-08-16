# Wave U3 — `sidepane`

Right inspector column (Files + Changes). v1 only — **no** Browser / Whiteboard / Subagents / in-pane terminal.

## Files

| File | Role |
|---|---|
| `App/Views/Panels/InspectorPanelAttach.swift` | **NEW** — `Notification.Name.toggleInspectorRequested` (`agentos.toggleInspector`), `setInspectorVisible` (`agentos.setInspectorVisible`, `userInfo["visible"]`), `InspectorPanelAttach`, `View.vibecoderInspectorPanel()` |
| `App/Views/Panels/InspectorPanelModel.swift` | **NEW** — tabs, `@AppStorage` key `vc.inspectorVisible` default **false**, project-root resolver, Files tree wrapper, `InspectorChangeAggregator` |
| `App/Views/Panels/InspectorPanelView.swift` | **NEW** — tab strip + pane (subtle bg, ~280–320pt) |
| `App/Views/Panels/InspectorFilesTab.swift` | **NEW** — `ProjectFileIndex.listAllFilesAsync` + `FileTreeNode.build`; click file → Reveal in Finder; context menu Reveal + Copy path |
| `App/Views/Panels/InspectorChangesTab.swift` | **NEW** — `TurnChangeSummary.summarizeEachTurn` (same walk as ChatView); +/− rows; expand → `CodeDiffBlock` via `CodeSessionBuilder` (no ChatView ownership); else “Open in Finder” |
| `App/Tests/InspectorPanelUITests.swift` | **NEW** — empty root, files tree, TurnChangeSummary aggregation, notification string, visibility default |

Did **not** edit: RootView, VibeCoderApp, ChatView, ChatViewModel, AppViewModel, InputBarViewV2, ZCodeSidebar, ProjectFileTreeBuilder.swift, TurnChangeSummary.swift, Package.swift, project.yml, existing tests.

## Public attach API

```swift
struct InspectorPanelAttach: ViewModifier {
  // @EnvironmentObject AppViewModel
  // @AppStorage("vc.inspectorVisible") default false
  // .inspector(isPresented:) { InspectorPanelView(...) }
  // .onReceive(.toggleInspectorRequested) { toggle }
  // .onReceive(.setInspectorVisible) { userInfo["visible"] as? Bool }
}
extension View {
  func vibecoderInspectorPanel() -> some View { modifier(InspectorPanelAttach()) }
}
```

Project root: selected conversation `worktreeRootURL ?? projectRoot`, else `app.openedProject?.url`.

Empty copy:
- Files: `No project folder — bind a project to see files.`
- Changes: `No file changes in this task yet.`

## RootView one-liner (parent glue)

On `navigationSplit`:

```swift
.vibecoderInspectorPanel()
```

## VibeCoderApp menu snippet (parent glue)

In the existing `CommandMenu("View")` (after Stop Agent is fine):

```swift
Button("Toggle Side Pane") {
    NotificationCenter.default.post(name: .toggleInspectorRequested, object: nil)
}
.keyboardShortcut("b", modifiers: [.command, .option])
```

`.toggleInspectorRequested` is defined in `InspectorPanelAttach.swift` — do **not** add a second `Notification.Name` in RootView / VibeCoderApp.

Optional force-show (palette / tests):

```swift
NotificationCenter.default.post(
    name: .setInspectorVisible,
    object: nil,
    userInfo: ["visible": true]
)
```

## Palette snippet (`toggle-side-pane`)

In `commandPaletteItems()`:

```swift
CommandPaletteItem(
    id: "toggle-side-pane",
    title: "Toggle Side Pane",
    subtitle: "Show or hide the inspector (⌥⌘B)",
    category: "App",
    keywords: ["inspector", "side", "pane", "files", "changes", "panel"]
),
```

In `runCommandPaletteItem`:

```swift
case "toggle-side-pane":
    NotificationCenter.default.post(name: .toggleInspectorRequested, object: nil)
```

Optional kbd hint in `CommandPaletteView.shortcutHint`: `"toggle-side-pane": return "⌥⌘B"`.

## Tests

```
xcodebuild -project App/VibeCoder.xcodeproj -scheme VibeCoder \
  -destination 'platform=macOS' -derivedDataPath /tmp/vc-u3/dd-sidepane \
  -only-testing:VibeCoderTests/InspectorPanelUITests test
```

**TEST SUCCEEDED** — 12/12 (`testToggleInspectorNotificationName`, `testSetInspectorVisibleNotificationName`, `testVisibilityStoreDefaultFalse`, `testSetInspectorVisibleParsesUserInfo`, `testEmptyRootHasNoProject`, `testProjectRootPrefersWorktreeThenConversationThenOpened`, `testFilesTabUsesTree`, `testChangesTabEmptyWhenNoMutations`, `testChangesTabAggregatesTurnChangeSummary`, `testChangesTabMergesSamePathAcrossTurns`, `testReconstructsDiffLinesForWriteWithoutChatView`, `testChangeFileURLPrefersAbsoluteThenRoot`).

## Open items (parent)

- Inspector is not visible until the one-liner + View-menu item are applied.
- Changes tab reads the list-row `Conversation` (same snapshot as `app.conversations`); live mid-turn VM transcript is not observed (updates after persist).
- File-changes Find scope / Browser / Whiteboard / in-pane terminal are out of v1.
