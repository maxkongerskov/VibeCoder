//
//  CompactEventCopyTests.swift
//  Product S7 — compact notice explains what was summarized / elided.
//

import XCTest
@testable import AgentCore

final class CompactEventCopyTests: XCTestCase {

    func testAutoWireExplainsDropCountAndWireOnly() {
        let copy = CompactEventCopy.make(
            summaryPreview: "",
            droppedMessages: 12,
            source: .autoWire
        )
        XCTAssertEqual(copy.title, "Context compacted")
        XCTAssertTrue(copy.detail.contains("12 older messages were summarized"))
        XCTAssertTrue(copy.detail.contains("wire-only") || copy.detail.contains("transcript still shows"))
        XCTAssertTrue(copy.detail.contains("Recent turns kept verbatim"))
        XCTAssertTrue(copy.statusLine.contains("12"))
    }

    func testManualRewriteMentionsUndo() {
        let copy = CompactEventCopy.make(
            summaryPreview: "current_goal: ship S7 meter\ndecisions:\n  - use window %",
            droppedMessages: 8,
            source: .manualRewrite
        )
        XCTAssertEqual(copy.title, "Conversation compacted")
        XCTAssertTrue(copy.detail.contains("/undo"))
        XCTAssertTrue(copy.detail.contains("rewritten") || copy.detail.contains("Rewrote")
                      || copy.detail.lowercased().contains("transcript"))
        XCTAssertTrue(copy.detail.contains("Goal kept") || copy.detail.contains("ship S7"))
    }

    func testExtractsFilesAndDecisionsFromExtractiveSummary() {
        let summary = """
        [context summary — compacted older turns]
        current_goal: fix context meter
        decisions:
          - show used/window not budget
        files_touched:
          - App/Views/Chat/InputBarViewV2.swift
          - Sources/AgentCore/Util/CompactEventCopy.swift
        failing_commands_or_errors:
          - Tool error: boom
        note: recent turns after this summary are verbatim.
        """
        let copy = CompactEventCopy.make(
            summaryPreview: summary,
            droppedMessages: 20,
            source: .autoWire
        )
        XCTAssertTrue(copy.detail.contains("InputBarViewV2") || copy.detail.contains("Files in summary"))
        XCTAssertTrue(copy.detail.contains("used/window") || copy.detail.contains("Decisions retained"))
        XCTAssertTrue(copy.detail.contains("Failures noted: 1"))
        XCTAssertFalse(copy.highlights.isEmpty)
        // Status should not dump raw machine headers.
        XCTAssertFalse(copy.statusLine.contains("[context summary"))
    }

    func testEmptyPreviewZeroDropsStillExplainsElision() {
        let copy = CompactEventCopy.make(
            summaryPreview: "   ",
            droppedMessages: 0,
            source: .autoWire
        )
        XCTAssertTrue(
            copy.detail.lowercased().contains("elided")
                || copy.detail.lowercased().contains("summarized")
        )
        XCTAssertFalse(copy.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testUnstructuredPreviewSurfacedInDetail() {
        let copy = CompactEventCopy.make(
            summaryPreview: "Kept auth tokens and project path /Users/me/app",
            droppedMessages: 5,
            source: .autoWire
        )
        XCTAssertTrue(copy.detail.contains("Summary:") || copy.detail.contains("auth tokens"))
        XCTAssertTrue(copy.statusLine.contains("5"))
    }
}

final class ContextUsageMeterLabelTests: XCTestCase {

    func testMeterLabelsUseWindowNotBudget() {
        let b = ContextUsageBreakdown.build(
            systemPrompt: "sys",
            messages: [
                .init(role: .user, content: String(repeating: "hello world ", count: 50)),
            ],
            windowTokens: 100_000,
            budgetTokens: 70_000,
            compactThresholdPercent: 70
        )
        XCTAssertEqual(b.windowTokens, 100_000)
        XCTAssertEqual(b.budgetTokens, 70_000)
        XCTAssertTrue(b.meterUsedOverWindowLabel.contains("/"))
        XCTAssertTrue(b.meterUsedOverWindowLabel.contains("100.0k") || b.meterUsedOverWindowLabel.contains("100k"))
        // Window % should be well under 100 for a short prompt.
        XCTAssertLessThan(b.windowPercent, 50)
        XCTAssertNotEqual(b.meterWindowPercentLabel, "compact")
        XCTAssertTrue(b.meterWindowPercentLabel.hasSuffix("%"))
    }

    func testFormatTokenCount() {
        XCTAssertEqual(ContextUsageBreakdown.formatTokenCount(500), "500")
        XCTAssertEqual(ContextUsageBreakdown.formatTokenCount(12_300), "12.3k")
        XCTAssertEqual(ContextUsageBreakdown.formatTokenCount(1_500_000), "1.5M")
    }

    func testPastCompactLabel() {
        let b = ContextUsageBreakdown(
            categories: [],
            totalTokens: 80_000,
            budgetTokens: 70_000,
            windowTokens: 100_000,
            compactThresholdPercent: 70
        )
        XCTAssertTrue(b.isAtOrPastCompact)
        XCTAssertEqual(b.meterWindowPercentLabel, "compact")
        XCTAssertEqual(b.windowPercent, 80)
    }
}
