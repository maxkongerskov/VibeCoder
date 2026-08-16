# Wave U3 — `terminal`

Bottom terminal dock. One interactive login-shell PTY per project cwd. Standalone of the agent loop (`Kill` does **not** call `cancel()`).

## Files

| File | Role |
|---|---|
| `App/Views/Terminal/TerminalDockSupport.swift` | **NEW** — `Notification.Name.toggleTerminalRequested` = `agentos.toggleTerminal`. `TerminalDockStorage` (`vc.terminalDockVisible` default **false**, height 200 / 120…420). `TerminalCwd` (`worktreeRootURL ?? projectRoot`, else home). |
| `App/Views/Terminal/ANSIParser.swift` | **NEW** — incremental tokens: SGR `m`, EL `K`, `\r` `\n`, BS/`0x7f`. Unknown CSI / OSC dropped. |
| `App/Views/Terminal/TerminalBuffer.swift` | **NEW** — `Sendable` line buffer + `TerminalEmulator` (UTF-8 remainder). SGR 0 / 1 / 22 / 30–37 / 39 / 90–97. |
| `App/Views/Terminal/TerminalSession.swift` | **NEW** — `forkpty` + login argv0 (`-zsh`). Read on a serial queue; hop to MainActor to append. `Kill` = SIGTERM then SIGKILL. Close fds on deinit / kill / cwd identity change. |
| `App/Views/Terminal/TerminalTextView.swift` | **NEW** — `NSViewRepresentable` / `NSTextView`. Shows attributed output; keystrokes (and paste) go to the master fd. |
| `App/Views/Terminal/TerminalDockView.swift` | **NEW** — chrome (“Terminal” + cwd basename + Kill + hide) on `Theme.Palette.subtle`, SF Mono 12. Hide/kill icons are the only orange. Host below. |
| `App/Tests/TerminalSessionUITests.swift` | **NEW** — parser / buffer / visibility / notification. No `forkpty` in CI. |

Did **not** edit RootView, VibeCoderApp, ChatView, ChatViewModel, AppViewModel, Panels/**, Package.swift, project.yml, entitlements, or existing tests. No side-pane terminal tab, no xterm.js, no multi-tab/split.

## Host API

```swift
struct TerminalDockHost: View {
  @EnvironmentObject private var app: AppViewModel
  @AppStorage("vc.terminalDockVisible") private var visible = false
  // if visible { TerminalDockView(cwd: worktreeRootURL ?? projectRoot ?? home) }
  // .onReceive(.toggleTerminalRequested) { visible.toggle() }
}
```

- Hidden by default (`vc.terminalDockVisible` = false).
- Cwd identity = `url.standardizedFileURL.path`. Recreates the PTY when that string changes.
- Session lives on the host (`@StateObject`) so hiding the dock does not kill the shell. Kill is explicit. Hide posts `.toggleTerminalRequested`.
- Requires `AppViewModel` in the environment (already true on `DetailPane`).

## Parent glue — DetailPane (do not apply from this agent)

On **`DetailPane` only** (under chat, not under the sidebar):

```swift
.safeAreaInset(edge: .bottom, spacing: 0) { TerminalDockHost() }
```

Call-site sketch:

```swift
} detail: {
    DetailPane(
        tab: selectedTab,
        selectedConversationID: selectedConversationID
    )
    .safeAreaInset(edge: .bottom, spacing: 0) { TerminalDockHost() }
    .toolbarBackground(.hidden, for: .windowToolbar)
    .modifier(RemoveWindowTitleModifier())
}
```

Or wrap `DetailPane.body` the same way. `.toggleTerminalRequested` is already defined in `TerminalDockSupport.swift` — do **not** add a second `Notification.Name` in RootView.

## Parent glue — VibeCoderApp View menu

Inside `CommandMenu("View")`, after Stop Agent (before the DEBUG block):

```swift
Button("Toggle Terminal") {
    NotificationCenter.default.post(name: .toggleTerminalRequested, object: nil)
}
.keyboardShortcut("j", modifiers: [.command])
```

Do not put ⌘J on a colliding system menu item without `CommandGroup`.

## Parent glue — palette `toggle-terminal`

In `commandPaletteItems()`:

```swift
CommandPaletteItem(
    id: "toggle-terminal",
    title: "Toggle Terminal",
    subtitle: "Show or hide the bottom terminal dock (⌘J)",
    category: "Panels",
    keywords: ["terminal", "shell", "dock", "pty"]
),
```

In `runCommandPaletteItem`:

```swift
case "toggle-terminal":
    NotificationCenter.default.post(name: .toggleTerminalRequested, object: nil)
```

No `CommandPaletteView` change. Category `"Panels"` is not in the existing preferred-order list; it will append as its own section (same as a future `toggle-side-pane`).

## Tests

```
xcodebuild -project App/VibeCoder.xcodeproj -scheme VibeCoder \
  -destination 'platform=macOS' -derivedDataPath /tmp/vc-u3/dd-terminal \
  -only-testing:VibeCoderTests/TerminalSessionUITests test
```

**TEST SUCCEEDED** — 9/9 (`testSGRRedBoldAndReset`, `testCarriageReturnOverwritesCurrentLine`, `testUnknownCSIIsDropped`, `testBackspaceDeletesPreviousCharacter`, `testVisibilityDefaultIsFalse`, `testToggleNotificationNameString`, `testCwdPrefersWorktreeThenProjectThenHome`, `testEraseLineAfterCRClearsRemainder`, `testIncompleteCSIDoesNotPrintGarbage`).

Coverage: SGR reset / red / bold, `\r` overwrite, unknown CSI dropped, backspace, visibility default false, notification name string, cwd preference, CSI `K` after `\r`, incomplete CSI leftover.

## Open items

- Parent owns DetailPane inset, View-menu ⌘J, palette `toggle-terminal`.
- v1 is one session per window/cwd. No tabs, split, or inspector terminal tab.
- Entitlements file is empty (not sandboxed); `forkpty` is allowed. Do not add sandbox keys from this wave.
