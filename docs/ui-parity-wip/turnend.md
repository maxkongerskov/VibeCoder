# Wave U1 — `turnend`

ZCode turn-end **"N file(s) changed +a −d"** card with per-file Review and header Undo.

## Files changed

| File | Role |
|---|---|
| `Sources/AgentCore/Conversation/TurnChangeSummary.swift` | **NEW** — pure aggregator (Sendable). Pairs assistant `toolCalls` with `.tool` results; write/edit/apply_patch/delete; dedupe by path + sum +/−; failed results skipped. |
| `App/Views/Chat/TurnChangeSummaryView.swift` | **NEW** — card UI + `Notification.Name.turnRewindRequested`. Review expands `CodeDiffBlock` inline in the file row. |
| `App/Views/ChatView.swift` | Sole Wave U1 owner — card at end of a **completed** assistant turn (`!isRunning` last twin). |
| `App/ViewModels/ChatViewModel.swift` | Observe `.turnRewindRequested` (init + deinit) → existing `handleRewind()` when conversation id matches. |
| `Tests/AgentCoreTests/ParityTurnChangeSummaryTests.swift` | **NEW** — totals, dedupe, delete=removed-only, empty turn, multi-turn isolation, failed write ignored. |
| `App/Views/Chat/MessageBubbleViewV2.swift` | **Untouched** — turn-end chrome lives in `ChatView` after the bubble (WorkingHeader stays inside the bubble). |

Did **not** edit Package.swift, project.yml, WorkingHeader, RootView, or CheckpointStore.

## Test results

```
swift test --filter ParityTurnChangeSummaryTests
```

7 tests, 0 failures (`testWriteAndEditTotals`, `testDedupeSamePathSumsCounts`, `testApplyPatchCounts`, `testDeleteCountedAsRemovedOnly`, `testTurnWithNoChangesIsEmpty`, `testMultiTurnIsolation`, `testFailedToolIsIgnored`).

`swift build` succeeded (AgentCore incremental).

## App-build status

`xcodebuild -scheme VibeCoder -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/vc-u1/dd-turnend build` → **BUILD SUCCEEDED**.

`flock` is not on PATH here (`command not found`); the rest of the compile script still ran (`xcodegen generate` + `xcodebuild`). New `TurnChangeSummaryView.swift` was compiled via xcodegen directory sources.

## Open items

- **Review** is inline `CodeDiffBlock` expansion (as specified), not ZCode’s side-pane `{type:'patch'}` viewer. Feels fine for chat-width hunks; a sheet would only help multi-hundred-line rewrites.
- `delete_file` rows have no reconstructed hunks from `ChatToolPartition` (edit-tools set excludes delete) → Review shows **“No diff preview”**. Counts still appear (removed-only).
- Header **Undo** is the existing `/rewind` path (latest checkpoint + drop last user turn). ZCode’s Safe / Unsafe / Ignored dialog, Reapply, and Undone badges are **not** implemented.
- Per-hunk Undo on `InlineEditCardView` is unchanged (complementary).
- Live streaming turn does not show the card (hidden with the finished twin while `isRunning`).
