# Wave U2 — `chatsearch`

**Find in task (⌘F).** Messages-only v1 (file-changes scope is P2).

## Files

| File | Role |
|---|---|
| `App/Utilities/FindInTaskSearch.swift` | **NEW** — pure search. Empty/whitespace query → `[]`. Case-insensitive substring on `ChatMessage.content` when `appearsInTranscript` (user + assistant; skips `.tool` / `.system` / wire-only reminders). Optional live `streamingContent` is a trailing hit with id `"pending"`. **v1: one hit per message** (first range + snippet). `nextIndex` / `previousIndex` wrap. |
| `App/Views/Chat/FindInTaskOverlay.swift` | **NEW** — compact top bar (`Theme.Palette.*`): placeholder `Find in task`, `N of M` (`0 of 0` when none), prev/next chevrons, clear (x), Done, Esc / `.onExitCommand`. `Notification.Name.findInTaskRequested` = `agentos.findInTask`. |
| `App/Views/ChatView.swift` | Hub: `@State showFindInTask` + query + index; `.onReceive` opens + focuses; recomputes hits from messages / `streamingContent`; highlight wrap on `MessageBubbleViewV2` / pending bubble (`accent.opacity(0.12)` + stroke); `ScrollViewReader.scrollTo(hit, .center)`. Did not touch `handleSend`, plan panel, export receiver, or turn-change summary. |
| `App/VibeCoderApp.swift` | View menu **Find in Task** after Stop Agent, `⌘F`, posts `.findInTaskRequested`. |
| `App/Tests/FindInTaskUITests.swift` | **NEW** — empty query, case-insensitive, skip non-transcript roles, wrap next/prev, one-hit-per-message, pending stream hit. |

Did **not** edit RootView, CommandPaletteView, ChatViewModel, InputBarViewV2, MentionAwareComposer, ZCodeSidebar, MessageBubbleViewV2, Package.swift, project.yml, or existing tests.

## Parent glue — RootView palette (do not apply from this agent)

Add the item with the other Chat commands in `commandPaletteItems()`:

```swift
CommandPaletteItem(id: "find-in-task", title: "Find in Task", subtitle: "Search messages in this conversation (⌘F)", category: "Chat", keywords: ["find", "search", "task", "messages"]),
```

In `runCommandPaletteItem`:

```swift
case "find-in-task":
    selectedTab = .chat
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .findInTaskRequested, object: nil)
    }
```

`selectedTab = .chat` first, then a **deferred** post so `ChatView` is mounted (same pattern as export). `.findInTaskRequested` is already defined in `FindInTaskOverlay.swift` — do not add a second `Notification.Name` in RootView.

No `CommandPaletteView` change.

## Tests

```
xcodebuild -project App/VibeCoder.xcodeproj -scheme VibeCoder \
  -destination 'platform=macOS' -derivedDataPath /tmp/vc-u2/dd-chatsearch \
  -only-testing:VibeCoderTests/FindInTaskUITests test
```

**TEST SUCCEEDED** — 7/7 (`testEmptyQueryYieldsNoHits`, `testCaseInsensitiveSubstringMatch`, `testSkipsNonTranscriptRoles`, `testWrapAroundNextAndPrevious`, `testMultipleMatchesInOneMessageCountAsOneHit`, `testPendingStreamingContentIsASyntheticHit`, `testWhitespaceStreamingIsIgnored`).

v1 design (locked in tests): **one hit per matching message**. Intra-message ranges and file-changes scope are P2.

## Open items

- Palette item is parent-owned (snippet above).
- Consecutive assistant iterations collapse to one `RenderBlock`; several message hits can highlight the same bubble (still one hit per message in the counter).
- Live last-assistant twin is hidden while running — those hits scroll/highlight `"pending"`.
- File-changes find scope is explicitly out of v1.
