# Wave U2 — `sidebar`

In-sidebar **Search tasks…**. Owns `App/Views/Sidebar/ZCodeSidebar.swift` and
NEW `App/Tests/SidebarSearchUITests.swift`.

## UI

- Field sits under **New Task**, above the task list (section chrome, always
  visible). Placeholder is exactly `Search tasks…`.
- Compact 12 pt `.plain` TextField in a muted rounded rect (`hover` fill +
  divider stroke). Magnifying-glass + optional `xmark.circle.fill` clear.
  No orange chrome.
- Clear (x) appears when the query is non-empty; sets query to `""`.
- Escape in the field (`onExitCommand`) also clears.
- Typing a non-whitespace query uncollapses the Tasks list.

## Filter

`ZCodeSidebar.filteredConversations(_:query:cleanModelChrome:)` (pure, static):

- Trim whitespace. Empty / whitespace-only → return all items (current list).
- Case-insensitive substring on **title** OR **preview** (`previewLine`).
- Pin / time grouping / context menus / rename run on the filtered set only.

## Empty states

| Condition | Copy |
|---|---|
| `conversations.isEmpty` (any query) | **No tasks yet** |
| Query non-empty after trim, no matches | **No matching tasks** (12 pt tertiary, centered) |

Delete-all still counts the unfiltered `conversations` list.

Initializer unchanged — query is `@State` only. RootView wiring not touched.

## Tests

`SidebarSearchUITests`: empty query; title match; preview match (user +
assistant messages); case-insensitive; no match; whitespace-only.

`xcodebuild … -only-testing:VibeCoderTests/SidebarSearchUITests` (`/tmp/vc-u2/dd-sidebar`)
→ **TEST SUCCEEDED** — 6/6.

## Out of scope (other U2 agents)

Queue, mentions, find-in-task. No RootView / ChatView / Package.swift /
project.yml edits.
