# Wave U4 — subagent pane + leftover ZCode chrome

User: right-pane **subagent viewing is not at parity**, and **menus / overall UI**
from ZCode are still missing.

U3 shipped Files + Changes only. ZCode's side pane is a **Subagents directory**
(Running / Ended, statuses, "Open in side pane" from the chat card). Menu bar
is still File(⌘N)+Settings+Find+View(palette/stop/pane/terminal). Settings still
has no Skills / Subagents managers.

## Exclusive owners

| id | Exclusive files | Must not touch |
|---|---|---|
| `subagents-pane` | `App/Views/Panels/InspectorPanelModel.swift`, `InspectorPanelView.swift`, `InspectorPanelAttach.swift`, NEW `InspectorSubagentsTab.swift`, NEW `InspectorSubagentDirectory.swift`, `App/Views/Chat/ZCodeActivityLineView.swift`, NEW `App/Tests/InspectorSubagentsUITests.swift` (may **add** tests to existing `InspectorPanelUITests.swift`) | RootView, VibeCoderApp, ChatView, ChatViewModel, AppViewModel, Settings/**, Terminal/** |
| `menus-chrome` | `App/VibeCoderApp.swift`, `App/Views/RootView.swift`, NEW `App/Tests/MenuChromeUITests.swift` | Panels/**, Settings/**, ZCodeActivityLineView, ChatView, ChatViewModel, ZCodeSidebar |
| `settings-managers` | `App/Views/Settings/SettingsViewV2.swift`, NEW `SkillsSettingsView.swift`, NEW `SubagentsSettingsView.swift`, NEW helpers under `App/Views/Settings/` or `App/Utilities/`, NEW `App/Tests/SettingsManagersUITests.swift` | RootView, VibeCoderApp, Panels/**, Chat/**, ZCodeSidebar |

**Never edit:** `Package.swift`, `App/project.yml`, `docs/UI_PARITY_WITH_ZCODE.md`,
another agent's files, existing tests except `subagents-pane` may append to
`InspectorPanelUITests.swift`. App sources auto-glob.

Notifications you define live in **your** files.

## Compile / test

```
cd /Users/maxkongerskov/vibecoder
# App tests:
xcodebuild -project App/VibeCoder.xcodeproj -scheme VibeCoder \
  -destination 'platform=macOS' -derivedDataPath /tmp/vc-u4/dd-<id> \
  -only-testing:VibeCoderTests/<YourSuite> test
```

macOS has **no** `flock`. Don't wait on other agents' builds. Don't kill
`/Applications/VibeCoder.app`.

## Out of scope (P3 / later)

In-app browser, whiteboard, mermaid/KaTeX, plugin marketplace, SSH/WSL,
split-pane tasks, task groups/colors, like/dislike, prompt-enhance, zh-CN.
