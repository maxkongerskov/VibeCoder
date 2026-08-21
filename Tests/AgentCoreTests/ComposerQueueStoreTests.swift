//
//  ComposerQueueStoreTests.swift
//
//  Characterization of the pending-turn composer queue. Ported from
//  `ComposerQueueStoreTests` in App/Tests so the contract lives with
//  the extracted type, not the frozen ChatViewModel.
//

import XCTest
@testable import AgentCore

final class ComposerQueueStoreTests: XCTestCase {

    func testEnqueueRejectsEmptyAndWhitespace() {
        var store = ComposerQueueStore()
        XCTAssertNil(store.enqueue(""))
        XCTAssertNil(store.enqueue("   \n\t  "))
        XCTAssertTrue(store.isEmpty)
    }

    func testEnqueueTrimsAndAppends() {
        var store = ComposerQueueStore()
        let a = store.enqueue("  first  ")
        let b = store.enqueue("second")
        XCTAssertEqual(a?.text, "first")
        XCTAssertEqual(b?.text, "second")
        XCTAssertEqual(store.items.map(\.text), ["first", "second"])
    }

    func testReorderAndRemove() {
        var store = ComposerQueueStore()
        let a = store.enqueue("a")!
        let b = store.enqueue("b")!
        let c = store.enqueue("c")!
        XCTAssertTrue(store.moveDown(id: a.id))
        XCTAssertEqual(store.items.map(\.text), ["b", "a", "c"])
        XCTAssertTrue(store.moveUp(id: c.id))
        XCTAssertEqual(store.items.map(\.text), ["b", "c", "a"])
        XCTAssertTrue(store.move(from: 0, to: 3))
        XCTAssertEqual(store.items.map(\.text), ["c", "a", "b"])
        XCTAssertEqual(store.remove(id: a.id)?.text, "a")
        XCTAssertEqual(store.items.map(\.text), ["c", "b"])
        XCTAssertNil(store.remove(id: a.id))
    }

    func testSteerRemovesItem() {
        var store = ComposerQueueStore()
        let kept = store.enqueue("keep")!
        let steered = store.enqueue("steer me")!
        XCTAssertEqual(store.takeForSteer(id: steered.id)?.text, "steer me")
        XCTAssertEqual(store.items.map(\.id), [kept.id])
    }

    func testPauseOnStopFlag() {
        var store = ComposerQueueStore()
        XCTAssertFalse(store.pauseIfNonEmpty())
        XCTAssertFalse(store.paused)
        _ = store.enqueue("held")
        XCTAssertTrue(store.pauseIfNonEmpty())
        XCTAssertTrue(store.paused)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNil(store.takeNextAfterTurn(), "paused queue must not flush")
        XCTAssertEqual(store.items.count, 1)
    }

    func testContinueReturnsNextText() {
        var store = ComposerQueueStore()
        _ = store.enqueue("one")
        _ = store.enqueue("two")
        _ = store.pauseIfNonEmpty()
        XCTAssertEqual(store.continuePaused(isRunning: true), nil)
        XCTAssertFalse(store.paused)
        XCTAssertEqual(store.items.map(\.text), ["one", "two"])
        _ = store.pauseIfNonEmpty()
        XCTAssertEqual(store.continuePaused(isRunning: false), "one")
        XCTAssertEqual(store.items.map(\.text), ["two"])
        XCTAssertFalse(store.paused)
    }

    func testFlushNextAfterTurn() {
        var store = ComposerQueueStore()
        _ = store.enqueue("first")
        _ = store.enqueue("second")
        XCTAssertEqual(store.takeNextAfterTurn(), "first")
        XCTAssertEqual(store.items.map(\.text), ["second"])
        XCTAssertEqual(store.takeNextAfterTurn(), "second")
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.takeNextAfterTurn())
    }

    func testCompactClassifiedAsRunNowNotSteer() {
        XCTAssertEqual(ComposerQueueStore.dispatch(for: "/compact"), .compactSlash)
        XCTAssertEqual(ComposerQueueStore.dispatch(for: "/compact keep auth"), .compactSlash)
        XCTAssertEqual(ComposerQueueStore.dispatch(for: "  /COMPRESS  extra  "), .compactSlash)
        XCTAssertEqual(ComposerQueueStore.dispatch(for: "/compress"), .compactSlash)
        XCTAssertEqual(ComposerQueueStore.dispatch(for: "please compact"), .followUp)
        XCTAssertEqual(ComposerQueueStore.dispatch(for: "/help"), .followUp)
        XCTAssertTrue(ComposerQueueStore.isCompactSlash("/compact"))
        XCTAssertFalse(ComposerQueueStore.isCompactSlash("/goal pause"))
        XCTAssertEqual(
            ComposerQueueStore.normalizedCompactCommand("/compress keep tests"),
            "/compact keep tests"
        )
        XCTAssertEqual(
            ComposerQueueStore.normalizedCompactCommand("/compact"),
            "/compact"
        )
    }

    func testRemovingLastItemClearsPause() {
        var store = ComposerQueueStore()
        let item = store.enqueue("only")!
        _ = store.pauseIfNonEmpty()
        _ = store.remove(id: item.id)
        XCTAssertTrue(store.isEmpty)
        XCTAssertFalse(store.paused)
    }

    func testEnqueuedStatusLineMatchesChatViewModelChip() {
        XCTAssertEqual(
            ComposerQueueStore.enqueuedStatusLine(count: 1),
            "Queued — will send after this turn")
        XCTAssertEqual(
            ComposerQueueStore.enqueuedStatusLine(count: 2),
            "2 messages queued")
    }

    func testRunNowCompactSlashRemovesWithoutSend() {
        var store = ComposerQueueStore()
        let item = store.enqueue("/compress keep the API notes")!
        let outcome = store.runNow(id: item.id, isRunning: true)
        XCTAssertEqual(
            outcome,
            .compactSlash(command: "/compact keep the API notes"))
        XCTAssertTrue(store.isEmpty)
    }

    func testRunNowIdleDequeuesFrontItem() {
        var store = ComposerQueueStore()
        _ = store.enqueue("first")
        let second = store.enqueue("second")!
        let outcome = store.runNow(id: second.id, isRunning: false)
        XCTAssertEqual(outcome, .send("second"))
        XCTAssertEqual(store.items.map(\.text), ["first"])
    }

    func testCancellingStatusLineWhenQueuePaused() {
        XCTAssertEqual(
            ComposerQueueStore.cancellingStatusLine(queuePaused: true),
            "Cancelling… queue paused")
        XCTAssertEqual(
            ComposerQueueStore.cancellingStatusLine(queuePaused: false),
            "Cancelling…")
        XCTAssertEqual(
            ComposerQueueStore.cancelledStatusLine(queuePaused: true),
            "Task ended by user — queue paused")
        XCTAssertEqual(
            ComposerQueueStore.cancelledStatusLine(queuePaused: false),
            "Task ended by user")
    }
}
