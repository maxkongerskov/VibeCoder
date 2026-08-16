# Wave U1 `permsheet` — permission prompt parity

## Files

- NEW `Sources/AgentCore/Safety/SessionGrantStore.swift` — in-memory, conversation-keyed grants (process lifetime, no disk)
- EDIT `App/Services/ShellApprovalCoordinatorService.swift` — consult store before presenting; `resolveSession()` / `rememberSession`
- EDIT `App/Views/Chat/ShellApprovalSheet.swift` — Session button, Tab/←→/↩/Esc, scope chip, kbd hint
- NEW `Tests/AgentCoreTests/ParitySessionGrantStoreTests.swift`

Did not edit `Package.swift`, `App/project.yml`, `ChatView.swift`, `ChatViewModel.swift`, or `Sources/AgentCore/Safety/ShellApproval.swift`.

## Behavior

Sheet (existing titles/copy kept):

- Buttons: **Once** · **Allow for this session** · **Always** / **Never** · **Deny**
- Session help: “Remember only until you quit the app”
- Dangerous shell: Session/Always/Never **disabled** (safety; ZCode would still offer session). Once + Deny only. Always still acts as Once in AgentCore.
- Keyboard: focused-index over **enabled** buttons; Tab / Shift-Tab / ← → move; ↩ confirms; Esc / onExitCommand = deny
- Footer (SF Mono 11, tertiary): `Tab choose · ↩ confirm · Esc deny`
- Scope chip under detail: **Applies to:** `git *` (first token) or the tool name
- Origin line ready: `Request from subagent: {type}` — hidden until plumbing stamps an origin (see below)

Coordinator:

- Holds `sessionGrants: SessionGrantStore` + `activeConversationID`
- Matching session grant → resolve `.once` **without** a sheet (dangerous never matches)
- Session choice records a grant, then returns `.once` so Always/Never disk path is unchanged
- Existing `resolve(.once/.always/.never/.deny)` signature kept (App tests)

Store:

- Scopes: `.shellPrefix` (first token, all segments must be covered) and `.tool(name:originTag:)`
- `matches` → `true` allow / `nil` no grant (session never stores deny)
- Isolation: grant in convo A does not match B; `clearConversation` drops one id only

**Deviation from ZCode:** dangerous commands cannot use Session (same rule as Always/Never).

## Tests

`swift build` — success (~3s)

`swift test --filter ParitySessionGrantStoreTests` — **12 tests, 0 failures**

Covered: shell prefix (`git *`), chained `git && npm` needs both prefixes, tool-name scope, origin-tag match/miss, conversation isolation, `clearConversation`, `grants(for:)`, bound-conversation 2-arg `matches`, idempotent add, `/usr/bin/git` basename.

## App build

First attempt (with `flock`) failed: `flock` is not on this macOS (`command not found`). xcodebuild still ran and failed in **hooks-ui** (`SettingsViewV2.swift:360 cannot find 'HooksSettingsView' in scope`) — not a permsheet error. `SessionGrantStore` / sheet / coordinator compiled in that graph with no errors.

Retry after `HooksSettingsView.swift` appeared + `xcodegen generate`:

`xcodebuild -project App/VibeCoder.xcodeproj -scheme VibeCoder -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/vc-u1/dd-permsheet build` — **BUILD SUCCEEDED** (~6s incremental).

## Open items (other agents' files)

### 1. Bind conversation id — `ChatViewModel` / `ConversationCoordinator`

Until this is wired, session grants use `SessionGrantStore.unscopedConversationID` (app-run scoped, not per-task).

```swift
// ConversationCoordinator: after selectedConversationID changes
host.shellApprovalCoordinatorService.activeConversationID = selectedConversationID

// deleteConversation(_ id:)
host.shellApprovalCoordinatorService.sessionGrants.clearConversation(id)
```

### 2. Optional sheet callback — `ChatView.swift` `ShellApprovalSheetMount`

Works today via `presentedService.resolveSession()`. Prefer explicit:

```swift
ShellApprovalSheet(request: pending.request) { decision in
    coordinator.resolve(decision)
}
// or:
// coordinator.resolveSheet(choice)  // ShellApprovalSheetDecision includes .session
```

Pass `originTag: pending.originTag` when ask plumbing stamps it.

### 3. Origin + conversation on the ask payload — `ShellApproval.swift` (not owned)

`ShellApprovalRequest` has `id`, `toolName`, `reason`, `command`, `detail` only. No origin / conversationID.

```swift
// ShellApprovalRequest
public let conversationID: UUID?
public let originTag: String?   // subagent type, e.g. "explore"

// makeRequest(... context: ToolContext)
//   conversationID: context.conversationID
//   originTag: context.subagentDepth > 0 ? /* agent type if added to ToolContext */ : nil
```

`ToolContext` has `subagentDepth` but no agent-type string. Subagent origin line stays dark until both fields exist.

Do **not** add `.session` to `ShellApprovalDecision` unless `resolveAsk` is updated — the coordinator maps session → `.once` on purpose so durable grants stay Once/Always/Never only.
