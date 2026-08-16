# Wave U2 — exclusive file ownership

Parent orchestrates. Children implement. **Never edit a file you do not own.**
If you need a change in someone else's file, put a complete drop-in snippet in
your note (`docs/ui-parity-wip/<id>.md`) and stop.

Do **not** edit: `Package.swift`, `App/project.yml`, `docs/UI_PARITY_WITH_ZCODE.md`,
another agent's owned files, or existing test files. New tests only.

**Hub files this wave (one owner):**

| Hub | Owner |
|---|---|
| `App/ViewModels/ChatViewModel.swift` | `queue` |
| `App/Views/Chat/InputBarViewV2.swift` | `queue` |
| `App/Views/ChatView.swift` | `chatsearch` |
| `App/VibeCoderApp.swift` | `chatsearch` |
| `App/Views/Sidebar/ZCodeSidebar.swift` | `sidebar` |
| `App/ViewModels/MentionSearchCoordinator.swift` | `mentions` |
| `App/Views/Chat/MentionAwareComposer.swift` | `mentions` |
| `App/ViewModels/StickyContextPin.swift` | `mentions` |

Unowned this wave (snippets only): `RootView.swift`, `AppViewModel.swift`,
`SettingsViewV2.swift`, `CommandPaletteView.swift`.

New files you create are yours. Notes: `docs/ui-parity-wip/<id>.md`.

## Compile / test

- `cd /Users/maxkongerskov/vibecoder`
- App sources auto-glob — no `project.yml` edits.
- New App tests: `App/Tests/<Topic>UITests.swift`
- Do not run a full `xcodebuild` clean of the whole app unless you need it;
  prefer `swift test --filter Parity` only if you added AgentCore tests.
- macOS has **no** `flock`. Don't wait on other agents' builds.

## Cross-file rules (read this)

1. **`InputBarViewV2` new parameters MUST have defaults** so
   `MentionAwareComposer` keeps compiling without edits.
2. Mount `ComposerQueueBar` **inside** `InputBarViewV2` (both owned by `queue`).
   Do not ask `ChatView` / `MentionAwareComposer` to host it.
3. Compress: post a notification defined in a `queue`-owned file;
   `ChatViewModel` observes it and runs `handleSlashCommand("/compact")`.
4. **`MentionCandidateKind` new cases break `StickyContextPin.init(candidate:)`.**
   `mentions` owns `StickyContextPin.swift` this wave so those switches stay exhaustive.
5. Find-in-task palette entry: `chatsearch` writes a RootView snippet; parent glues.
6. Do not change `send()`'s idle-path compose (pins, attachments, skill envelopes)
   except where the queue contract below requires it.

## Parent glue (after children release)

`RootView` is unowned this wave. Apply only snippets the children write:

- `chatsearch`: palette item `find-in-task` + `runCommandPaletteItem` posts
  `.findInTaskRequested` (switch to Chat first).
- `queue` / `mentions`: only if they could not stay exclusive (should be none
  if InputBar / MentionAwareComposer new params have defaults).

Then: `swift test --filter Parity`; `xcodegen generate` not required (App
auto-glob); `xcodebuild` Debug; live-check queue, `$`/`#`, ⌘F, sidebar search.

## Parent glue applied

- RootView palette: `find-in-task` + deferred `.findInTaskRequested`.
- `VibeCoderApp`: Find in Task is `CommandGroup(after: .pasteboard)` (Edit / ⌘F).
  A View-menu button with ⌘F never appeared in the menu bar (AppKit Find group).
