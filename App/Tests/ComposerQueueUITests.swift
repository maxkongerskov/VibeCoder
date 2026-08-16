//
//  ComposerQueueUITests.swift
//
//  Pure queue store + ChatViewModel wrap (no AgentLoop).
//

import XCTest
import AgentCore
@testable import VibeCoderApp

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
}

@MainActor
final class ComposerQueueViewModelTests: XCTestCase {

    override func tearDown() {
        ChatPromptHooks.resetTestHandlers()
        super.tearDown()
    }

    private func makeVM() -> ChatViewModel {
        ChatPromptHooks.userPromptSubmitHandler = { _, _, _ in .allow }
        let app = AppViewModel()
        return ChatViewModel(conversation: Conversation(), app: app)
    }

    func testSendWhileRunningEnqueuesWithoutStartingATurn() {
        let vm = makeVM()
        vm.isRunning = true
        XCTAssertTrue(vm.send("  follow up  "))
        XCTAssertEqual(vm.composerQueue.map(\.text), ["follow up"])
        XCTAssertEqual(vm.statusLine, "Queued — will send after this turn")
        XCTAssertTrue(vm.send("second"))
        XCTAssertEqual(vm.composerQueue.map(\.text), ["follow up", "second"])
        XCTAssertEqual(vm.statusLine, "2 messages queued")
        XCTAssertTrue(vm.isRunning, "queue must not start a second loop")
    }

    func testEnqueueFollowUpRejectsEmptyAndHookDeny() {
        let vm = makeVM()
        XCTAssertFalse(vm.enqueueFollowUp("   "))
        XCTAssertTrue(vm.composerQueue.isEmpty)
        ChatPromptHooks.userPromptSubmitHandler = { _, _, _ in .deny("no secrets") }
        XCTAssertFalse(vm.enqueueFollowUp("leak"))
        XCTAssertTrue(vm.composerQueue.isEmpty)
        XCTAssertTrue(vm.statusLine.contains("no secrets"))
    }

    func testCancelPausesNonEmptyQueue() {
        let vm = makeVM()
        vm.isRunning = true
        XCTAssertTrue(vm.enqueueFollowUp("held"))
        vm.cancel()
        XCTAssertTrue(vm.queuePaused)
        XCTAssertEqual(vm.composerQueue.map(\.text), ["held"])
        XCTAssertTrue(vm.statusLine.lowercased().contains("queue paused"))
    }

    func testSteerRemovesItemFromQueue() {
        let vm = makeVM()
        vm.isRunning = true
        XCTAssertTrue(vm.enqueueFollowUp("nudge"))
        let id = vm.composerQueue[0].id
        vm.steerQueuedItem(id: id)
        XCTAssertTrue(vm.composerQueue.isEmpty)
    }

    func testRunNowClassifiesCompactAsSlash() {
        let vm = makeVM()
        XCTAssertTrue(vm.enqueueFollowUp("/compress keep the API notes"))
        let id = vm.composerQueue[0].id
        XCTAssertEqual(
            ComposerQueueStore.dispatch(for: vm.composerQueue[0].text),
            .compactSlash
        )
        vm.runQueuedItemNow(id: id)
        XCTAssertTrue(vm.composerQueue.isEmpty)
        // Too little history — handleCompact still consumes the slash.
        XCTAssertFalse(vm.statusLine.isEmpty)
    }

    func testViewModelReorderAndRemove() {
        let vm = makeVM()
        XCTAssertTrue(vm.enqueueFollowUp("a"))
        XCTAssertTrue(vm.enqueueFollowUp("b"))
        XCTAssertTrue(vm.enqueueFollowUp("c"))
        vm.moveQueuedItem(from: 0, to: 3)
        XCTAssertEqual(vm.composerQueue.map(\.text), ["b", "c", "a"])
        vm.moveQueuedItemUp(id: vm.composerQueue[2].id)
        XCTAssertEqual(vm.composerQueue.map(\.text), ["b", "a", "c"])
        vm.removeQueuedItem(id: vm.composerQueue[1].id)
        XCTAssertEqual(vm.composerQueue.map(\.text), ["b", "c"])
    }
}
