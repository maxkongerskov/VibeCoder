//
//  WaveCCompactionBugHuntTests.swift
//
//  Wave C W08 — regression tests for compaction bugs found in bug hunt.
//

import XCTest
@testable import AgentCore

final class WaveCCompactionBugHuntTests: XCTestCase {

    // MARK: - Semantic safeCutIndex must not orphan tool results

    func testSafeCutIndexDoesNotOrphanTools() {
        // user, asst+tools, tool, tool, user, asst — keepRecent=2
        // Old buggy cut walked tools into recent while dropping assistant.
        let messages: [ChatMessage] = [
            .init(role: .user, content: "start"),
            .init(role: .assistant, content: "reading", toolCalls: [
                .init(id: "a", name: "read_file", arguments: #"{"path":"/a.swift"}"#),
                .init(id: "b", name: "read_file", arguments: #"{"path":"/b.swift"}"#),
            ]),
            .init(role: .tool, content: "A", toolCallID: "a"),
            .init(role: .tool, content: "B", toolCallID: "b"),
            .init(role: .user, content: "continue"),
            .init(role: .assistant, content: "done"),
        ]
        let cut = SemanticCompactor.safeCutIndex(messages, keepRecent: 2)
        let recent = Array(messages.suffix(from: cut))
        for (idx, m) in recent.enumerated() where m.role == .tool {
            let prior = recent.prefix(idx).reversed().first { $0.role == .assistant }
            XCTAssertNotNil(prior, "tool at recent[\(idx)] orphaned (cut=\(cut))")
            XCTAssertFalse(prior!.toolCalls.isEmpty, "prior assistant must own tool_calls")
        }
    }

    func testSemanticCompactPreservesToolPairingInRecent() async {
        var messages: [ChatMessage] = []
        for i in 0..<8 {
            messages.append(.init(role: .user, content: "step \(i)"))
            messages.append(.init(role: .assistant, content: "I will decide path \(i)", toolCalls: [
                .init(id: "c\(i)", name: "read_file", arguments: "{\"path\":\"file_\(i).swift\"}"),
            ]))
            messages.append(.init(role: .tool, content: String(repeating: "x", count: 800), toolCallID: "c\(i)"))
        }
        let result = await SemanticCompactor.compact(
            messages,
            systemPromptTokens: 50,
            budgetTokens: 300,
            keepRecent: 4)
        XCTAssertTrue(result.didCompact)
        let afterSummary = Array(result.messages.dropFirst())
        for (idx, m) in afterSummary.enumerated() where m.role == .tool {
            let prior = afterSummary.prefix(idx).reversed().first { $0.role == .assistant }
            XCTAssertNotNil(prior, "dangling tool in compacted recent region")
        }
    }

    // MARK: - FullReplace files_touched must harvest paths

    func testFullReplaceForceSyncSummaryIncludesFilesTouched() {
        let older: [ChatMessage] = [
            .init(role: .user, content: "Edit Foo"),
            .init(role: .assistant, content: "I will decide to edit Foo.swift", toolCalls: [
                .init(id: "1", name: "read_file", arguments: #"{"path":"/src/Foo.swift"}"#),
            ]),
            .init(role: .tool, content: "file body", toolCallID: "1"),
        ]
        let summary = ExtractiveHistorySummarizer().forceSyncSummary(
            older, hint: "Preserve paths")
        XCTAssertTrue(summary.contains("files_touched"), "got:\n\(summary)")
        XCTAssertTrue(summary.contains("/src/Foo.swift") || summary.contains("Foo.swift"),
                      "path missing in:\n\(summary)")
    }

    // MARK: - Case-insensitive decision mining

    func testExtractiveCapturesCapitalizedDecide() async throws {
        let msgs = [
            ChatMessage(role: .assistant, content: "Decide to use SwiftUI for all views."),
        ]
        let summary = try await ExtractiveHistorySummarizer().summarize(
            messages: msgs, systemHint: "")
        XCTAssertTrue(summary.lowercased().contains("decide")
                      || summary.lowercased().contains("swiftui"),
                      "case-sensitive mine missed 'Decide': \(summary)")
    }

    // MARK: - Path extract is JSON value only

    func testExtractPathArgumentCleanValue() {
        let path = ExtractiveHistorySummarizer.extractPathArgument(
            from: #"{"path":"/Users/x/Project/App.swift","offset":1}"#)
        XCTAssertEqual(path, "/Users/x/Project/App.swift")
    }

    // MARK: - Wire fidelity: compressor does not mutate input; subagent wire shrinks

    func testWireMessagesDoesNotMutateTranscript() {
        let big = String(repeating: "z", count: 5_000)
        var messages: [ChatMessage] = [
            .init(role: .system, content: "sys"),
            .init(role: .user, content: "q"),
        ]
        for i in 0..<4 {
            let id = "c\(i)"
            messages.append(.init(role: .assistant, content: "r\(i)", toolCalls: [
                .init(id: id, name: "read_file", arguments: #"{"path":"/f\#(i).swift"}"#),
            ]))
            messages.append(.init(role: .tool, content: big, toolCallID: id))
        }
        let original = messages.map(\.content)
        let model = ModelDescriptor(
            id: "m", displayName: "m", backend: .lmStudio,
            supportsTools: true, contextLength: 8_192)
        _ = SubAgentWireCompaction.wireMessages(
            from: messages, model: model, contextBudgetTokens: 2_048)
        XCTAssertEqual(messages.map(\.content), original)
    }

    // MARK: - Context budget math

    func testContextBudgetSeventyPercentOfWindow() {
        let budget = ContextBudget.budgetTokens(
            effectiveContextLength: 100_000, compactThresholdPercent: 70)
        XCTAssertEqual(budget, 70_000)
    }

    func testContextBudgetClampsPercent() {
        // Large window: percent clamped to [10, 100], then floor 2048.
        let low = ContextBudget.budgetTokens(
            effectiveContextLength: 10_000, compactThresholdPercent: 1)
        // 10% of 10k = 1000, but budgetTokens floors at 2048 for large windows
        XCTAssertEqual(low, 2_048)
        let high = ContextBudget.budgetTokens(
            effectiveContextLength: 10_000, compactThresholdPercent: 200)
        XCTAssertEqual(high, 10_000)
        let mid = ContextBudget.budgetTokens(
            effectiveContextLength: 10_000, compactThresholdPercent: 50)
        XCTAssertEqual(mid, 5_000)
        // Small window (≤2048): honor percent — leave headroom (Wave C2 B10)
        let small = ContextBudget.budgetTokens(
            effectiveContextLength: 2_048, compactThresholdPercent: 70)
        XCTAssertEqual(small, 1_434) // rounded 2048 * 0.7
        XCTAssertLessThan(small, 2_048)
    }

    // MARK: - Wave C2 residuals

    func testFullReplaceDefaultThresholdIsBudgetNot085() {
        let msgs = (0..<5).map { i in
            ChatMessage(role: .user, content: String(repeating: "w ", count: 20) + "\(i)")
        }
        let used = ChatLoop.estimateTotalTokens(systemPromptTokens: 10, messages: msgs)
        XCTAssertGreaterThan(used, 0)
        // Under budget at default 1.0 → no compact
        XCTAssertFalse(
            FullReplaceCompactor.shouldCompact(
                messages: msgs, systemPromptTokens: 10, budgetTokens: used + 100),
            "default thresholdFraction=1.0 must not fire under budget")
        // At budget → compact
        XCTAssertTrue(
            FullReplaceCompactor.shouldCompact(
                messages: msgs, systemPromptTokens: 10, budgetTokens: used),
            "fires at budget")
        // Explicit 0.5 of a budget that is 2× used → used >= budget*0.5
        XCTAssertTrue(
            FullReplaceCompactor.shouldCompact(
                messages: msgs, systemPromptTokens: 10, budgetTokens: used * 2,
                thresholdFraction: 0.5),
            "explicit 0.5 of 2×used should fire")
        // Prior early-fire: 0.85 of (used/0.6) would fire under old dual-stack;
        // at 1.0 default, under-budget stays false.
        let oldStyleBudget = Int(Double(used) / 0.6) // ~budget if window*0.7 then *0.85 stacked
        XCTAssertFalse(
            FullReplaceCompactor.shouldCompact(
                messages: msgs, systemPromptTokens: 10,
                budgetTokens: max(used + 1, oldStyleBudget)),
            "must not fire early when still under budget at 1.0")
    }

    func testFullReplaceNoCarrierWhenCutIsZero() async {
        // Only tools after a short prefix — cut walks to 0 → no empty carrier.
        let msgs: [ChatMessage] = [
            .init(role: .tool, content: "orphan-looking", toolCallID: "x"),
            .init(role: .tool, content: "t2", toolCallID: "y"),
            .init(role: .user, content: "u"),
            .init(role: .assistant, content: "a"),
        ]
        // keepRecent large enough that cut starts mid-tools and walks to 0
        let result = await FullReplaceCompactor.compact(
            msgs, systemPromptTokens: 0, budgetTokens: 50, keepRecent: 3)
        // Either no drop, or no empty carrier prefix with droppedCount 0
        if result.droppedCount == 0 {
            XCTAssertEqual(result.messages.count, msgs.count,
                           "must not inject empty FR carrier when nothing dropped")
        }
    }

    // MARK: - Preserve hint surfaces in summary (manual /compact path)

    func testSemanticSystemHintCarriesPreserve() async {
        var messages: [ChatMessage] = []
        for i in 0..<12 {
            messages.append(.init(role: .user, content: "u\(i) " + String(repeating: "p", count: 100)))
            messages.append(.init(role: .assistant, content: "a\(i) " + String(repeating: "q", count: 100)))
        }
        let result = await SemanticCompactor.compact(
            messages,
            systemPromptTokens: 10,
            budgetTokens: 200,
            keepRecent: 4,
            systemHint: SemanticCompactor.defaultSystemHint
                + "\nUser asked to preserve: auth middleware details")
        XCTAssertTrue(result.didCompact)
        XCTAssertTrue(
            (result.summary ?? "").contains("auth middleware")
                || (result.summary ?? "").contains("preserve"),
            "preserve hint should appear in extractive summary: \(result.summary ?? "")")
    }
}
