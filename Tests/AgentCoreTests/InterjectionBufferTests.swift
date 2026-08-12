//
//  InterjectionBufferTests.swift
//  Wave B S9 — mid-turn interjection buffer unit tests.
//

import XCTest
@testable import AgentCore

final class InterjectionBufferTests: XCTestCase {

    func testEnqueueDrainOrderPreserved() async {
        let id = UUID()
        await InterjectionBuffer.shared.clear(conversationId: id)
        await InterjectionBuffer.shared.enqueue(conversationId: id, text: "a")
        await InterjectionBuffer.shared.enqueue(conversationId: id, text: "b")
        await InterjectionBuffer.shared.enqueue(conversationId: id, text: "c")
        let items = await InterjectionBuffer.shared.drain(conversationId: id)
        XCTAssertEqual(items, ["a", "b", "c"])
    }

    func testConversationsAreIsolated() async {
        let a = UUID()
        let b = UUID()
        await InterjectionBuffer.shared.clear(conversationId: a)
        await InterjectionBuffer.shared.clear(conversationId: b)
        await InterjectionBuffer.shared.enqueue(conversationId: a, text: "only-a")
        await InterjectionBuffer.shared.enqueue(conversationId: b, text: "only-b")
        let da = await InterjectionBuffer.shared.drain(conversationId: a)
        XCTAssertEqual(da, ["only-a"])
        let db = await InterjectionBuffer.shared.drain(conversationId: b)
        XCTAssertEqual(db, ["only-b"])
    }

    func testClearDiscardsUndelivered() async {
        let id = UUID()
        await InterjectionBuffer.shared.enqueue(conversationId: id, text: "discard me")
        await InterjectionBuffer.shared.clear(conversationId: id)
        let pc = await InterjectionBuffer.shared.peekCount(conversationId: id)
        XCTAssertEqual(pc, 0)
        let drained = await InterjectionBuffer.shared.drain(conversationId: id)
        XCTAssertTrue(drained.isEmpty)
    }

    func testWhitespaceOnlyRejected() async {
        let id = UUID()
        await InterjectionBuffer.shared.clear(conversationId: id)
        await InterjectionBuffer.shared.enqueue(conversationId: id, text: "   \n\t  ")
        let pc = await InterjectionBuffer.shared.peekCount(conversationId: id)
        XCTAssertEqual(pc, 0)
    }

    /// Cancel-discard journey: enqueue mid-turn, clear (as cancel does),
    /// then a new turn must not see leaked steers.
    func testCancelClearPreventsLeakIntoNextDrain() async {
        let id = UUID()
        await InterjectionBuffer.shared.enqueue(conversationId: id, text: "steer me")
        let before = await InterjectionBuffer.shared.peekCount(conversationId: id)
        XCTAssertEqual(before, 1)
        await InterjectionBuffer.shared.clear(conversationId: id)
        let leaked = await InterjectionBuffer.shared.drain(conversationId: id)
        XCTAssertTrue(leaked.isEmpty, "cancel must discard buffered interjections")
    }

    /// P4 hard-stop fail-closed: after clear, enqueue with the *old* epoch
    /// is rejected so cancelled-turn steers cannot land post-stop.
    func testHardStopFailClosedRejectsStaleEpochEnqueue() async {
        let id = UUID()
        await InterjectionBuffer.shared.clear(conversationId: id)
        let epochBefore = await InterjectionBuffer.shared.currentEpoch(conversationId: id)
        let accepted = await InterjectionBuffer.shared.enqueue(
            conversationId: id, text: "live steer", expectedEpoch: epochBefore)
        XCTAssertTrue(accepted)
        // Hard-stop: clear bumps epoch (AgentLoop cancel / natural end).
        await InterjectionBuffer.shared.clear(conversationId: id)
        let rejected = await InterjectionBuffer.shared.enqueue(
            conversationId: id, text: "late steer after cancel", expectedEpoch: epochBefore)
        XCTAssertFalse(rejected, "stale epoch after hard-stop must fail closed")
        let leaked = await InterjectionBuffer.shared.drain(conversationId: id)
        XCTAssertTrue(leaked.isEmpty)
    }

    /// Wave C W09: natural finish also clears (AgentLoop return + finishRun).
    /// Late interjections after the last model call must not poison next run.
    func testEndOfTurnClearPreventsLeakIntoNextRun() async {
        let id = UUID()
        await InterjectionBuffer.shared.clear(conversationId: id)
        await InterjectionBuffer.shared.enqueue(conversationId: id, text: "too late for this turn")
        let pending = await InterjectionBuffer.shared.peekCount(conversationId: id)
        XCTAssertEqual(pending, 1)
        // Simulate finishRun / AgentLoop natural exit.
        await InterjectionBuffer.shared.clear(conversationId: id)
        let nextTurn = await InterjectionBuffer.shared.drain(conversationId: id)
        XCTAssertTrue(nextTurn.isEmpty, "finish must discard undelivered interjections")
    }
}
