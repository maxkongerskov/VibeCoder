# Wave U3 — `statuscapsule`

Slim collapsible status strip under `ChatHeaderView` / `EngineLoadBar`: git branch + dirty count + latest-turn files + plan todos. Compact chrome, not a full ZCode capsule (no Commit/Push, terminals, or agents).

## What shipped

- Collapsed (default): one line, e.g. `main · 3 dirty · 2 files · 1/4 todos`. Missing segments omitted.
- Chevron expands stacked rows: **Branch**, **Dirty**, **Changes** (`TurnChangeSummary` of the latest *completed* assistant turn), **Todos** (`activePlan` done/total, skipped counts as done).
- Hidden when there is no cwd (`worktreeRootURL ?? projectRoot`) or `git` exits 128 (not a repo). Never shows “not a git repo”.
- Refresh: `.task(id: conversation.id + cwd)` and again when `isRunning` flips to false. Git probes are off-MainActor with a 1.5s budget.

## Files

| File | Role |
|---|---|
| `App/Utilities/GitWorkingCopySummary.swift` | **NEW** — branch + dirtyCount; injectable runner; porcelain / collapsed-label / todo-fraction helpers |
| `App/Views/Chat/StatusCapsuleView.swift` | **NEW** — Theme-token strip; owns expand + probe `@State` |
| `App/Views/ChatView.swift` | Mount in `chatColumn` after `EngineLoadBar`. Reuses `turnChangeSummary` for the last completed assistant block. New computed props only. |
| `App/Tests/StatusCapsuleUITests.swift` | **NEW** — porcelain count, HEAD trim, collapsed omit, exit 128 hide, todo fraction |

Did **not** edit: RootView, VibeCoderApp, ChatViewModel, InputBarViewV2, ChatHeaderView, AgentCore, Package.swift, project.yml, `handleSend`, find-in-task, queue, composer, plan panel, existing tests.

## Parent glue

None. Capsule is local to `ChatView` + new files.

## Tests

`App/Tests/StatusCapsuleUITests.swift` (`@testable import VibeCoderApp`):

- porcelain → dirty count (modified + untracked; skip `!!` / blanks)
- branch trim / detached `"HEAD"` still shown
- collapsed label omits empty segments
- capture `nil` when runner exits 128
- todo fraction (`1/4 todos`; `nil` when total is 0)

```
xcodebuild -scheme VibeCoder -destination 'platform=macOS' -only-testing:VibeCoderTests/StatusCapsuleUITests test
```

7 tests, 0 failures. **TEST SUCCEEDED**.
