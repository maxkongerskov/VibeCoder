# Compact wave-1 — APIs for `loop` (wave-2)

Do **not** edit `AgentLoop.swift` in this wave. Wire the helpers below
on the next pass. None of these mutate the persisted conversation unless
the loop assigns the returned value.

## 1. Reactive compact — context overflow

```swift
public enum ContextOverflowClassifier {
    static func isContextExceeded(_ message: String) -> Bool
    static func isContextExceeded(error: Error) -> Bool
}
```

Call on every model-step failure (and HTTP 400/422 bodies) **before**
giving up the turn:

```swift
if ContextOverflowClassifier.isContextExceeded(error: error)
    || ContextOverflowClassifier.isContextExceeded(message) {
    // compact once (FullReplace / Semantic) then retry the same model step
}
```

`max_tokens` / finish-reason `length` is **not** overflow — do not
reactive-compact.

ZCode markers: `model_context_exceeded`, `context_exceeded`,
`context_length_exceeded`, `context_window_exceeded`,
`model_context_window_exceeded`, `prompt_too_long`. Also matches
OpenAI/Anthropic prose (`maximum context length`, `too many tokens`).

## 2. Micro-compact (old tool bodies)

```swift
public enum MicroCompactor {
    static let clearedMarker: String            // "[Old tool result content cleared]"
    static let defaultKeepRecent: Int           // 6
    static let defaultCompactableToolNames: Set<String>

    static func isClearedToolResult(_ content: String) -> Bool

    static func compact(
        _ conversation: Conversation,
        keepRecent: Int = defaultKeepRecent,
        compactableToolNames: Set<String> = defaultCompactableToolNames
    ) -> Conversation

    static func compact(
        messages: [ChatMessage],
        keepRecent: Int = defaultKeepRecent,
        compactableToolNames: Set<String> = defaultCompactableToolNames
    ) -> [ChatMessage]
}
```

Returns a **copy**. Last `keepRecent` messages stay verbatim. Only
`.tool` bodies whose `toolCallID` maps to a compactable name are
rewritten; `tool_call_id` pairing is untouched.

Default names (ZCode Read/Bash/Grep/…): `read_file`, `run_shell`,
`grep_code`, `glob_files`, `fetch_url`, `web_search`, `edit_file`,
`write_file`, `apply_patch`. ZCode aliases (`Read`, `Bash`, …) are
accepted.

ZCode trigger (loop owns this): ~90% of auto-compact threshold **or**
60 min idle. Helper is trigger-agnostic.

## 3. Rapid-refill breaker

```swift
public struct RapidRefillBreaker: Sendable, Equatable {
    static let consecutiveCompactLimit: Int     // 3
    static let minToolTurnsToReset: Int         // 3

    var consecutiveRapidCompacts: Int { get }
    var toolTurnsSinceCompact: Int { get }

    init(consecutiveRapidCompacts: Int = 0, toolTurnsSinceCompact: Int = 0)

    mutating func recordCompact()
    mutating func recordToolTurn()
    func shouldHardStop() -> Bool
}
```

One instance per turn:

```swift
var refill = RapidRefillBreaker()

// before auto/reactive compact:
if refill.shouldHardStop() {
    // hard-stop the turn (ZCode `rapid_refill_blocked`)
}
// after a successful compact:
refill.recordCompact()
// after a real tool-result batch:
refill.recordToolTurn()
```

Trips when the **next** compact would be the 3rd consecutive compact
with `< 3` tool turns between each pair. Resets on `>= 3` tool turns.

## 4. Full-replace (9-section + continuation)

```swift
public enum FullReplaceCompactor {
    static let continuationPreamble: String
    static let nineSectionHeadings: [String]
    static let nineSectionInstructions: String   // LLM compact prompt

    static func formatCompactSummary(_ raw: String) -> String
    static func wrapContinuation(summary: String, recentMessagesPreserved: Bool = true) -> String
    static func makeContinuationCarrier(summary: String, recentMessagesPreserved: Bool = true) -> ChatMessage

    static func shouldCompact(
        messages: [ChatMessage],
        systemPromptTokens: Int,
        budgetTokens: Int,
        thresholdFraction: Double = 1.0
    ) -> Bool

    static func compact(
        _ messages: [ChatMessage],
        systemPromptTokens: Int,
        budgetTokens: Int,
        keepRecent: Int = 6,
        summarizer: (any HistorySummarizing)? = nil
    ) async -> FullReplaceResult

    static func extractDurableNote(from summary: String, older: [ChatMessage]) -> String
}

public struct FullReplaceResult: Sendable {
    var messages: [ChatMessage]
    var summary: String
    var droppedCount: Int
    var durableNote: String
}
```

Extractive path emits the 9 ZCode headings. Carrier user message starts
with `continuationPreamble` (“This session is being continued from a
previous conversation that ran out of context…”). Pass a
`HistorySummarizing` + `nineSectionInstructions` for an LLM summary;
`<analysis>` / `<summary>` tags are stripped via `formatCompactSummary`.

## 5. Semantic compact (unchanged call shape)

```swift
public enum SemanticCompactor {
    static func compact(
        _ messages: [ChatMessage],
        systemPromptTokens: Int,
        budgetTokens: Int,
        keepRecent: Int = 6,
        systemHint: String = SemanticCompactor.defaultSystemHint,
        summarizer: any HistorySummarizing = ExtractiveHistorySummarizer()
    ) async -> SemanticCompactionResult
}
```

Still extractive. Structured text now also emits `pending_tasks:`.

## 6. Tool-result compressor (wire copy)

```swift
public enum ToolResultCompressor {
    static func compress(_ messages: [ChatMessage]) -> [ChatMessage]
}
```

Public API unchanged. Already-cleared microcompact markers are left
intact (not re-summarized).

## Suggested loop order (ZCode)

Each iteration, before `backend.stream`:

1. `MicroCompactor.compact` on a **wire copy** (or persist if you opt in).
2. If `FullReplaceCompactor.shouldCompact` (or Semantic budget):
   - if `refill.shouldHardStop()` → hard-stop
   - else `await FullReplaceCompactor.compact(...)` then `refill.recordCompact()`
3. `ToolResultCompressor.compress` on the wire copy.

On stream error: `ContextOverflowClassifier` → one reactive compact +
`recordCompact()` + retry the same step (unless breaker trips).

On a completed real tool-result batch: `refill.recordToolTurn()`.
