# hooks-ui (Wave U1)

Hooks editor in Settings over the exact `HookDispatcher` JSON schema.

## Files changed

| File | Role |
|---|---|
| `Sources/AgentCore/Hooks/HookConfigStore.swift` | **NEW** load/save + `HookEntry` |
| `Sources/AgentCore/Hooks/HookDispatcher.swift` | **Additive only**: public + `Sendable` on config structs; public inits; `loadConfig` public; `encodeConfigObject` / `writeConfig`. No dispatch/decision edits. |
| `App/Views/Settings/HooksSettingsView.swift` | **NEW** Settings pane |
| `App/Views/Settings/SettingsViewV2.swift` | Register tab `hooks` in Agent group |
| `Tests/AgentCoreTests/ParityHookConfigStoreTests.swift` | **NEW** schema + dispatcher load tests |

Did not edit `Package.swift`, `App/project.yml`, other settings views, or the dispatcher run path.

## Schema

Nested file (what we write):

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write", "hooks": [{ "type": "command", "command": "lint.sh", "timeout": 30, "args": ["--fix"], "async": true }] }
    ]
  }
}
```

- Project write target: existing `hooks.json` / `config.json` under the first dir `HookDispatcher.hooksDir` would read (`.vibecoder/hooks` then `.grok/hooks`); else create `<project>/.vibecoder/hooks/hooks.json`.
- `load(projectRoot:)` → `HookDispatcher.loadConfig` (empty if no dir).
- Extra handler keys the dispatcher ignores: `args`, `async`/`background`, `enabled`.
- Disabled rows are stored under top-level `disabledHooks` (same nested shape) so `loadConfig` does not run them. Toggle is therefore real without a dispatcher change.
- Unknown top-level keys (`$schema`, `version`, …) are preserved on save. Unknown event names under `hooks` are preserved by the store; `HookDispatcher.parseConfigJSON` drops them (no slot).
- Pretty JSON: `JSONSerialization` `[.prettyPrinted, .sortedKeys]`.

`HookEntry` fields: `event`, `matcher?`, `command`, `args`, `timeoutSeconds?`, `background`, `enabled`. Map onto matcher groups + command handlers. Timeout omit → dispatcher default 5s.

## User scope

`HookDispatcher.hooksDir` / `loadConfig` only search `projectRoot` then `worktreeRoot` for `.vibecoder/hooks` or `.grok/hooks`. **No home-dir read.**

`HookConfigStore.userConfigURL` = `~/.vibecoder/hooks.json` (UI only). Settings User tab: path + Reveal in Finder; rows/add disabled; caption “Agent reads project hooks only.”

P2 snippet (do **not** ship in this item) to actually load user hooks:

```swift
// HookDispatcher.hooksDir — after project/worktree, if still nil:
let userDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".vibecoder/hooks", isDirectory: true)
if FileManager.default.fileExists(atPath: userDir.path) { return userDir }
// Plus optionally a lone ~/.vibecoder/hooks.json (not a directory today).
```

That is a behavior change (user hooks would start firing).

## UI

- Settings → **Agent** group → **Hooks** (`rawValue` `hooks`, subtitle “Lifecycle events”, icon `bolt.horizontal.circle`).
- Scope: Project (conversation `projectRoot` else `openedProject`) / User.
- List grouped by the 7 ZCode events (`SessionStart` … `Stop`). Extra names (incl. `Notification`) still group if present.
- Row: matcher or “All tools”, mono truncated command, enabled toggle, edit, delete.
- Add/Edit sheet: Event, Matcher (`e.g. Write, Edit, Bash — blank = all`), Command (`echo 'Hello from hook'`), Arguments (one per line), Timeout seconds optional, Run in background.
- Caption: “Changes apply to new sessions.”
- Persist: mutate in-memory array + `saveEntries` (same pattern as MCP bind-and-write).

Not mirrored (ZCode extras, P2): runner `process`, shell override, status message, custom JSON, import / plugin hooks.

## Tests

`swift build` — ok (package already incremental-clean).

`swift test --filter ParityHookConfigStoreTests` — **13/13 passed**:

- `HookEntry` Codable equality
- entries JSON payload round-trip (`args` / `async` / timeout)
- `save(HookConfigFile)` then `HookDispatcher.loadConfig` equality
- `saveEntries` then dispatcher sees command / matcher / timeout
- disabled hook omitted from dispatcher `hooks`
- unknown event kept by store, dropped by dispatcher parse, kept on `HookConfigFile` save merge
- unknown top-level keys preserved
- pretty-print stable across rewrite
- creates `.vibecoder/hooks`; nil project empty / throws
- `userConfigURL` is `~/.vibecoder/hooks.json`
- existing `config.json` updated in place (no second `hooks.json`)

## App build

`flock` is not on this macOS (`command not found: flock`). `xcodegen generate` + `xcodebuild` still ran.

```
xcodebuild -project App/VibeCoder.xcodeproj -scheme VibeCoder -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/vc-u1/dd-hooksui build
```

**BUILD SUCCEEDED** (compiled `HooksSettingsView.swift` in the VibeCoder target).

## Open items

- P2: dispatcher user-scope read (snippet above).
- Dispatcher still runs `command` as one shell string; `args` are persisted for ZCode-shaped files but not argv-split at spawn.
- `async` is persisted only; spawn is still synchronous with timeout.
- `Notification` is in the dispatcher schema but not in the 7-event picker (ZCode `f2t`).
- Sidebar now 12 tabs; `UI_DESIGN.md` / research still say 11 — out of this item’s file set.
