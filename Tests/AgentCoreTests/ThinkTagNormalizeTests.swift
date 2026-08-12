//
//  ThinkTagNormalizeTests.swift
//  Wave C2 W09 — think-tag promotion + interjection epoch.
//

import XCTest
@testable import AgentCore

final class ThinkTagNormalizeTests: XCTestCase {

    func testChannelReasoningPreferredOverTags() {
        let (body, reasoning, secs) = AgentLoop.normalizeAssistantThinking(
            channelReasoning: "from channel",
            content: "<think>from tags</think>answer",
            thinkingDurationSeconds: 9
        )
        XCTAssertEqual(reasoning, "from channel")
        XCTAssertEqual(body, "<think>from tags</think>answer")
        XCTAssertEqual(secs, 9)
    }

    func testTagOnlyPromotedAndBodyCleaned() {
        let (body, reasoning, secs) = AgentLoop.normalizeAssistantThinking(
            channelReasoning: "",
            content: "<think>plan the edit</think>\n\nDone.",
            thinkingDurationSeconds: nil
        )
        XCTAssertEqual(reasoning, "plan the edit")
        XCTAssertEqual(body, "Done.")
        XCTAssertNil(secs)
    }

    func testNoTagsLeavesContentIntact() {
        let (body, reasoning, _) = AgentLoop.normalizeAssistantThinking(
            channelReasoning: "",
            content: "plain answer",
            thinkingDurationSeconds: nil
        )
        XCTAssertNil(reasoning)
        XCTAssertEqual(body, "plain answer")
    }

    func testThinkingTagVariant() {
        let (_, reasoning, _) = AgentLoop.normalizeAssistantThinking(
            channelReasoning: "  ",
            content: "<thinking>x</thinking>y",
            thinkingDurationSeconds: 3
        )
        XCTAssertEqual(reasoning, "x")
    }
}

final class InterjectionEpochTests: XCTestCase {

    func testEnqueueRejectedAfterClearEpochBump() async {
        let id = UUID()
        await InterjectionBuffer.shared.clear(conversationId: id)
        let epoch = await InterjectionBuffer.shared.currentEpoch(conversationId: id)
        // Clear again bumps epoch (simulates cancel/finish).
        await InterjectionBuffer.shared.clear(conversationId: id)
        let accepted = await InterjectionBuffer.shared.enqueue(
            conversationId: id,
            text: "straggler",
            expectedEpoch: epoch
        )
        XCTAssertFalse(accepted)
        let n = await InterjectionBuffer.shared.peekCount(conversationId: id)
        XCTAssertEqual(n, 0)
    }

    func testEnqueueAcceptedWhenEpochMatches() async {
        let id = UUID()
        await InterjectionBuffer.shared.clear(conversationId: id)
        let epoch = await InterjectionBuffer.shared.currentEpoch(conversationId: id)
        let accepted = await InterjectionBuffer.shared.enqueue(
            conversationId: id,
            text: "ok",
            expectedEpoch: epoch
        )
        XCTAssertTrue(accepted)
        let n = await InterjectionBuffer.shared.peekCount(conversationId: id)
        XCTAssertEqual(n, 1)
        await InterjectionBuffer.shared.clear(conversationId: id)
    }
}
