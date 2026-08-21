//
//  ConversationPersistenceTests.swift
//
//  Characterization of persist + save-failure status (Ada P2). Ported from
//  `testChatViewModelSaveFailureSetsStatusLine` so the contract lives with
//  the extracted type, not the frozen ChatViewModel.
//

import XCTest
@testable import AgentCore

final class ConversationPersistenceTests: XCTestCase {

    /// Characterization: save failure sets the idle status line.
    /// Same unwritable-path store as `testChatViewModelSaveFailureSetsStatusLine`.
    func testChatViewModelSaveFailureSetsStatusLine() async throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cvm-save-block-\(UUID().uuidString)")
        try Data([0x00]).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = ConversationStore(
            directory: blocker.appendingPathComponent("conversations", isDirectory: true))
        let snapshot = Conversation(title: "p2-save")
        let outcome = await ConversationPersistence.persistSnapshot(
            snapshot,
            store: store,
            suppressed: false,
            isRunning: false,
            logLabel: "ChatViewModel.save")
        XCTAssertFalse(outcome.didSave)
        XCTAssertEqual(outcome.statusLine, "Couldn't save conversation.")
        XCTAssertEqual(
            outcome.statusLine,
            ConversationPersistence.saveFailureStatusLine)
    }

    func testSaveFailureWhileRunningDoesNotSetStatusLine() async {
        let outcome = await ConversationPersistence.persistSnapshot(
            Conversation(title: "p2-running"),
            store: FailingConversationStore(),
            isRunning: true)
        XCTAssertFalse(outcome.didSave)
        XCTAssertNil(outcome.statusLine)
    }

    func testSuppressedPersistDoesNotSaveOrSetStatusLine() async {
        let store = FailingConversationStore()
        let outcome = await ConversationPersistence.persistSnapshot(
            Conversation(title: "p2-suppressed"),
            store: store,
            suppressed: true,
            isRunning: false)
        XCTAssertFalse(outcome.didSave)
        XCTAssertNil(outcome.statusLine)
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 0)
    }

    func testSuccessfulSaveDoesNotSetStatusLine() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationStore(directory: dir)
        let snapshot = Conversation(title: "p2-ok")
        let outcome = await ConversationPersistence.persistSnapshot(
            snapshot,
            store: store,
            isRunning: false)
        XCTAssertTrue(outcome.didSave)
        XCTAssertNil(outcome.statusLine)
    }
}

/// In-memory store that always fails `save`.
private actor FailingConversationStore: ConversationStoring {
    private(set) var saveCount = 0

    func load(id: UUID) async throws -> Conversation? { nil }

    func save(_ conversation: Conversation) async throws {
        saveCount += 1
        throw NSError(
            domain: "ConversationPersistenceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "disk full"])
    }

    func list() async throws -> [Conversation] { [] }

    func delete(id: UUID) async throws {}
}
