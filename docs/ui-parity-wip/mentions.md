# Wave U2 — `mentions`

`$skill` / `#session` composer triggers. Owns
`MentionSearchCoordinator.swift`, `MentionAwareComposer.swift`,
`StickyContextPin.swift`, and NEW `App/Tests/MentionTriggersUITests.swift`.

## API

### Triggers

`MentionSearchCoordinator.activeMentionQuery(in:)` is **unchanged** (`@`
after BOS/whitespace only; emails stay `nil`).

New: `activeTrigger(in:) -> (kind, query)?` for `@` / `$` / `#` with the
same token rules (space ends the query; newline cancels).

`stripActiveTriggerToken(from:)` drops a trailing `[@$#]token` only when
the trigger starts a token (emails and `cost$100` / `issue#12` stay).

`refresh(text:root:sessions:currentID:)` — last two args default so
existing `@` tests still compile:

| Trigger | Search |
|---|---|
| `@` | existing `searchAll` (needs `root`; nil root clears rows) |
| `$` | `SkillDiscovery.discover(projectRoot:root, worktreeRoot:nil, metadataOnly:true)` (`root` may be nil → bundled + home) then name/description contains query. Cap 14. |
| `#` | `sessions` from the view (`app.conversations`). Title / preview / UUID. Skip `archived` and `currentID`. Cap 14. |

Helpers: `filterSkills`, `searchSkills`, `searchSessions`, `sessionPreview`
(first 72 chars of last user/assistant body).

Published: `activeTriggerKind` for the popup header.

### Candidates / pins

`MentionCandidateKind` + `StickyContextPin.Kind` add `.skill` and `.session`.

| Kind | `path` | `displayName` | `systemImage` | one-shot attach |
|---|---|---|---|---|
| skill | SKILL.md path or name | skill name | `sparkles` | no |
| session | `conversation.id.uuidString` | title or `Untitled` | `bubble.left.and.bubble.right` | no |

`pinHeaderText`:

- `.skill`: `byName` (no project root on the pin) or parse `path` as a
  file; then `formatSkillMessage`. Miss → `- $skill {name}` + description
  (`symbolName`).
- `.session`:
  ```
  - #session {title} ({uuid})
    Use read_session_context with sessionId="{uuid}" query="handoff from this session" strategy="handoff".
  ```

`fileAttachments` still files/symbols only.

`asRecord` / `init(record:)` use string `kind` (`skill` / `session`).
`StickyContextPinRecord` in AgentCore was not edited.

### Composer

`MentionAwareComposer` reads `AppViewModel` via `@EnvironmentObject`
(already on `ChatView`). No new required view parameters — `ChatView`
does not need a snippet.

Popup headers: `@ context` / `$ skills` / `# sessions`.
`kindBadge` includes skill/session.
Select skill/session → sticky pin only (no `ContextAttachment`).
↑/↓/Enter/Esc unchanged.

## Files

- `App/ViewModels/MentionSearchCoordinator.swift`
- `App/Views/Chat/MentionAwareComposer.swift`
- `App/ViewModels/StickyContextPin.swift`
- `App/Tests/MentionTriggersUITests.swift`

## Parent snippets

None.

## Tests

`MentionTriggersUITests` (+ `MentionTriggersRefreshUITests`):

- `$` / `#` / `@` trigger detection; email `@` is nil
- skill filter matches name (and description)
- session filter matches title / preview; archived + current ID excluded
- skill/session record round-trip; header contains skill name / session UUID
- `@` / `$` / `#` token strip; emails and mid-token `$`/`#` left alone

Did **not** edit `MentionSearchCoordinatorTests.swift` or
`StickyContextPinTests.swift`.

## Test / build

| Check | Result |
|---|---|
| `xcodebuild … test -only-testing:VibeCoderTests/MentionTriggersUITests` (+ Refresh) | **TEST SUCCEEDED** — 17/17 |
| `MentionSearchCoordinatorTests` + `StickyContextPinTests` | **passed** (existing `@` / pin compose) |
| BugHunt `activeMentionQuery` / email strip | **passed** |
