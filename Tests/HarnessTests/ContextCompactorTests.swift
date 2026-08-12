//
//  ContextCompactorTests.swift  (Harness)
//
//  Pins token-aware context compaction: the elision-only strategy that
//  keeps long agentic runs inside a small context window without ever
//  breaking assistant↔tool `tool_call_id` pairing. Ported from AgentCore's
//  ChatLoopTests compaction cases, plus added cases that pin the
//  never-touch invariants (user messages, recent messages) and the
//  tool-output-first ordering.
//
//  Note on assertion style (matches StallDetectorTests): we assert on the
//  marker text the compactor itself produces ("elided"), which is plain
//  text, so there's no JSONSerialization '/'-escaping to worry about here.
//

import XCTest
@testable import Harness

final class ContextCompactorTests: XCTestCase {

    private func msg(_ role: Role, _ content: String,
                     calls: [ToolCall] = []) -> ChatMessage {
        ChatMessage(role: role, content: content, toolCalls: calls)
    }

    private func toolMsg(_ content: String, id: String = "t1") -> ChatMessage {
        ChatMessage(role: .tool, content: content, toolCallID: id)
    }

    // MARK: - under budget → unchanged

    func testCompactionLeavesShortHistoryUntouched() {
        let messages = [msg(.user, "hi"), msg(.assistant, "hello")]
        let out = ContextCompactor.compactHistory(messages, systemPromptTokens: 100, budgetTokens: 10_000)
        XCTAssertEqual(out.map(\.content), messages.map(\.content))
    }

    func testCompactionNoOpWhenBudgetNonPositive() {
        // budgetTokens <= 0 disables compaction entirely — return as-is even
        // though a 0 budget is technically "over".
        let big = String(repeating: "z", count: 5_000)
        var messages: [ChatMessage] = [
            msg(.assistant, "", calls: [ToolCall(id: "t1", name: "read_file", arguments: "{}")]),
            toolMsg(big),
        ]
        for i in 0..<8 { messages.append(msg(.user, "f\(i)")); messages.append(msg(.assistant, "a\(i)")) }
        let out = ContextCompactor.compactHistory(messages, systemPromptTokens: 0, budgetTokens: 0)
        XCTAssertEqual(out.map(\.content), messages.map(\.content))
    }

    // MARK: - over budget → tool outputs elided first

    func testCompactionElidesOldToolOutputFirst() {
        let bigToolOutput = String(repeating: "x", count: 40_000)
        var messages: [ChatMessage] = [
            msg(.user, "do the thing"),
            msg(.assistant, "", calls: [ToolCall(id: "t1", name: "read_file", arguments: "{}")]),
            toolMsg(bigToolOutput),
        ]
        // Recent padding so the old tool message is outside keepRecent.
        for i in 0..<8 {
            messages.append(msg(.user, "follow-up \(i)"))
            messages.append(msg(.assistant, "answer \(i)"))
        }

        let out = ContextCompactor.compactHistory(messages, systemPromptTokens: 0, budgetTokens: 2_000)

        // Structure intact: same count, same roles, tool_call pairing alive.
        XCTAssertEqual(out.count, messages.count)
        XCTAssertEqual(out[2].role, .tool)
        XCTAssertEqual(out[2].toolCallID, "t1")
        // Old tool body elided, marker present.
        XCTAssertLessThan(out[2].content.count, 2_000)
        XCTAssertTrue(out[2].content.contains("elided"))
        XCTAssertTrue(out[2].content.contains("tool output"))
        // User messages never touched.
        XCTAssertEqual(out[0].content, "do the thing")
    }

    // MARK: - recent keepRecent never touched

    func testCompactionNeverTouchesRecentMessages() {
        let big = String(repeating: "y", count: 30_000)
        var messages: [ChatMessage] = []
        for i in 0..<4 {
            messages.append(msg(.user, "q\(i)"))
            messages.append(msg(.assistant, "", calls: [ToolCall(id: "c\(i)", name: "grep_code", arguments: "{}")]))
            messages.append(toolMsg(big, id: "c\(i)"))
        }
        let out = ContextCompactor.compactHistory(messages, systemPromptTokens: 0,
                                                  budgetTokens: 1_000, keepRecent: 3)
        // The last 3 messages are protected even when over budget.
        for i in (messages.count - 3)..<messages.count {
            XCTAssertEqual(out[i].content, messages[i].content,
                           "message \(i) is inside keepRecent and must be untouched")
        }
    }

    // MARK: - user messages never touched (even huge & old)

    func testCompactionNeverTouchesUserMessages() {
        // A giant OLD user message that is well outside keepRecent must still
        // be left verbatim — only tool/assistant bodies are elision targets.
        let bigUser = String(repeating: "u", count: 50_000)
        var messages: [ChatMessage] = [
            msg(.user, bigUser),
            msg(.assistant, "", calls: [ToolCall(id: "t1", name: "read_file", arguments: "{}")]),
            toolMsg(String(repeating: "x", count: 50_000)),
        ]
        for i in 0..<8 { messages.append(msg(.user, "f\(i)")); messages.append(msg(.assistant, "a\(i)")) }

        let out = ContextCompactor.compactHistory(messages, systemPromptTokens: 0, budgetTokens: 1_000)
        XCTAssertEqual(out[0].role, .user)
        XCTAssertEqual(out[0].content, bigUser, "old user message must never be elided")
        XCTAssertFalse(out[0].content.contains("elided"))
    }

    // MARK: - phase 2: assistant prose elided when tool elision isn't enough

    func testCompactionElidesOldAssistantProseWhenStillOverBudget() {
        // No tool messages to elide → phase 2 must trim old assistant prose,
        // leaving tool-call structure intact and user messages untouched.
        let bigAssistant = String(repeating: "a", count: 40_000)
        var messages: [ChatMessage] = [
            msg(.user, "go"),
            msg(.assistant, bigAssistant),
        ]
        for i in 0..<8 { messages.append(msg(.user, "f\(i)")); messages.append(msg(.assistant, "a\(i)")) }

        let out = ContextCompactor.compactHistory(messages, systemPromptTokens: 0, budgetTokens: 1_500)
        XCTAssertEqual(out[1].role, .assistant)
        XCTAssertLessThan(out[1].content.count, 1_500)
        XCTAssertTrue(out[1].content.contains("elided"))
        XCTAssertTrue(out[1].content.contains("assistant message"))
        XCTAssertEqual(out[0].content, "go", "user message untouched")
    }

    // MARK: - plan-authoring assistant messages never touched

    func testCompactionNeverTouchesPlanAuthoringAssistantMessages() {
        // An old assistant message whose tool call is a plan-authoring call
        // must be preserved verbatim even when over budget — repeated plan
        // updates are progress, and the plan is load-bearing context.
        let planCall = ToolCall(id: "p1", name: "update_todo", arguments: "{}")
        let bigPlanProse = String(repeating: "p", count: 40_000)
        var messages: [ChatMessage] = [
            msg(.user, "plan it"),
            msg(.assistant, bigPlanProse, calls: [planCall]),
        ]
        for i in 0..<8 { messages.append(msg(.user, "f\(i)")); messages.append(msg(.assistant, "a\(i)")) }

        let out = ContextCompactor.compactHistory(messages, systemPromptTokens: 0, budgetTokens: 1_000)
        XCTAssertEqual(out[1].content, bigPlanProse,
                       "plan-authoring assistant message must never be elided")
        XCTAssertFalse(out[1].content.contains("elided"))
    }

    // MARK: - tool_call id pairing / structure preserved

    func testCompactionPreservesToolCallStructure() {
        let bigToolOutput = String(repeating: "x", count: 40_000)
        let call = ToolCall(id: "t1", name: "read_file", arguments: #"{"path":"/etc/hosts"}"#)
        var messages: [ChatMessage] = [
            msg(.user, "read it"),
            msg(.assistant, "", calls: [call]),
            toolMsg(bigToolOutput, id: "t1"),
        ]
        for i in 0..<8 { messages.append(msg(.user, "f\(i)")); messages.append(msg(.assistant, "a\(i)")) }

        let out = ContextCompactor.compactHistory(messages, systemPromptTokens: 0, budgetTokens: 2_000)

        // The assistant tool call is structurally identical — only the tool
        // result body was elided.
        XCTAssertEqual(out.count, messages.count)
        XCTAssertEqual(out[1].toolCalls.count, 1)
        XCTAssertEqual(out[1].toolCalls[0].id, "t1")
        XCTAssertEqual(out[1].toolCalls[0].name, "read_file")
        // Decode the preserved arguments rather than asserting on raw bytes.
        let decoded = try? JSONSerialization.jsonObject(
            with: Data(out[1].toolCalls[0].arguments.utf8)) as? [String: String]
        XCTAssertEqual(decoded?["path"], "/etc/hosts")
        // And the paired tool result still references the same id.
        XCTAssertEqual(out[2].role, .tool)
        XCTAssertEqual(out[2].toolCallID, "t1")
    }

    // MARK: - estimation helpers

    func testEstimateMessageTokensCountsContentAndToolCallArgs() {
        // content + name + arguments all contribute (char/4, rounded up).
        let m = msg(.assistant, "1234", calls: [ToolCall(id: "x", name: "abcd", arguments: "efgh")])
        // "1234"→1, "abcd"→1, "efgh"→1
        XCTAssertEqual(ContextCompactor.estimateMessageTokens(m), 3)
    }

    func testEstimateTotalTokensAddsSystemPrompt() {
        let messages = [msg(.user, "1234"), msg(.assistant, "5678")]
        XCTAssertEqual(
            ContextCompactor.estimateTotalTokens(systemPromptTokens: 10, messages: messages),
            10 + 1 + 1)
    }

    // MARK: - KV-cache-preserving bucket-marker arithmetic
    //
    // The elision marker reports the original size bucketed to 1000-char
    // granularity so the marker text doesn't change byte-for-byte as the
    // transcript grows by a few chars — that stability is what preserves
    // KV-cache hits on the elided content. Pin both the arithmetic and the
    // within-bucket stability so a future edit dropping the `*1000` rounding
    // is caught.

    private func elideOldToolBody(_ bodyLen: Int) -> String {
        var messages: [ChatMessage] = [
            msg(.user, "go"),
            msg(.assistant, "", calls: [ToolCall(id: "t1", name: "read_file", arguments: "{}")]),
            toolMsg(String(repeating: "x", count: bodyLen)),
        ]
        for i in 0..<8 { messages.append(msg(.user, "f\(i)")); messages.append(msg(.assistant, "a\(i)")) }
        let out = ContextCompactor.compactHistory(messages, systemPromptTokens: 0, budgetTokens: 2_000)
        return out[2].content
    }

    func testElisionMarkerReportsBucketedSize() {
        // 40_000 chars → bucket (40000/1000)*1000 = 40000.
        XCTAssertTrue(elideOldToolBody(40_000).contains("~40000 chars"))
    }

    func testElisionMarkerStableWithinSameBucket() {
        // 40_000 and 40_500 land in the same 1000-char bucket → byte-identical
        // markers (same head prefix of 'x', same bucket number).
        XCTAssertEqual(elideOldToolBody(40_000), elideOldToolBody(40_500))
    }

    // MARK: - elideCap boundary + phase short-circuit

    func testToolBodyAtExactlyElideCapIsNotElided() {
        // The guard is strictly `old.count > elideCap`, so a body of exactly
        // elideCap (240) chars is left verbatim even while over budget. A
        // second, larger old tool body forces the run over budget so we know
        // compaction actually ran.
        let exact = String(repeating: "s", count: 240)        // == elideCap, must survive
        let big = String(repeating: "x", count: 40_000)       // must be elided
        var messages: [ChatMessage] = [
            msg(.user, "go"),
            msg(.assistant, "", calls: [ToolCall(id: "a", name: "read_file", arguments: "{}")]),
            toolMsg(exact, id: "a"),
            msg(.assistant, "", calls: [ToolCall(id: "b", name: "read_file", arguments: "{}")]),
            toolMsg(big, id: "b"),
        ]
        for i in 0..<8 { messages.append(msg(.user, "f\(i)")); messages.append(msg(.assistant, "a\(i)")) }

        let out = ContextCompactor.compactHistory(messages, systemPromptTokens: 0, budgetTokens: 2_000)
        XCTAssertEqual(out[2].content, exact, "body of exactly elideCap chars must NOT be elided")
        XCTAssertFalse(out[2].content.contains("elided"))
        XCTAssertTrue(out[4].content.contains("elided"), "the larger old tool body should be elided")
    }

    func testPhaseTwoSkippedWhenPhaseOneAlreadyUnderBudget() {
        // Eliding the one big tool output alone brings the run under budget, so
        // phase 2 must short-circuit and leave a big OLD assistant prose
        // message verbatim. Pins the underBudget() early-return between phases.
        let bigTool = String(repeating: "x", count: 40_000)       // ~10_000 tokens
        let bigProse = String(repeating: "a", count: 40_000)      // ~10_000 tokens, must survive
        var messages: [ChatMessage] = [
            msg(.user, "go"),
            msg(.assistant, "", calls: [ToolCall(id: "t1", name: "read_file", arguments: "{}")]),
            toolMsg(bigTool, id: "t1"),
            msg(.assistant, bigProse),
        ]
        for i in 0..<8 { messages.append(msg(.user, "f\(i)")); messages.append(msg(.assistant, "a\(i)")) }

        // Budget sits between "after phase 1" (~10_100) and "before" (~20_000).
        let out = ContextCompactor.compactHistory(messages, systemPromptTokens: 0, budgetTokens: 12_000)
        XCTAssertTrue(out[2].content.contains("elided"), "phase 1 should elide the tool output")
        XCTAssertEqual(out[3].content, bigProse, "phase 2 must be skipped → assistant prose preserved")
        XCTAssertFalse(out[3].content.contains("elided"))
    }

    // MARK: - percentOfContext

    func testPercentOfContextRoundsAndGuardsZero() {
        XCTAssertEqual(TokenEstimator.percentOfContext(tokens: 5_000, contextSize: 10_000), 50)
        XCTAssertEqual(TokenEstimator.percentOfContext(tokens: 1, contextSize: 3), 33)   // 33.3 → 33
        XCTAssertEqual(TokenEstimator.percentOfContext(tokens: 2, contextSize: 3), 67)   // 66.7 → 67
        XCTAssertEqual(TokenEstimator.percentOfContext(tokens: 100, contextSize: 0), 0)  // guard
    }
}
