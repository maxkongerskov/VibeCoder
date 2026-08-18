//
//  ConversationIOTests.swift
//  Phase B PB6 — resume / save conversation JSON round-trip.
//

import XCTest
import AgentCore
@testable import EvalRunnerLib

final class ConversationIOTests: XCTestCase {
    private var idsToClear: [UUID] = []

    override func tearDown() async throws {
        for id in idsToClear {
            await SessionReadTracker.shared.clear(conversationID: id)
        }
        idsToClear.removeAll()
        try await super.tearDown()
    }

    private func track(_ id: UUID) {
        idsToClear.append(id)
    }

    func testSaveLoadRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb6-convo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("c.json").path
        var convo = Conversation(
            title: "eval",
            modelID: "mock",
            projectRoot: URL(fileURLWithPath: "/tmp/project-a")
        )
        track(convo.id)
        convo.messages.append(ChatMessage(role: .user, content: "hello"))
        convo.messages.append(ChatMessage(role: .assistant, content: "world"))

        try await ConversationIO.save(convo, toPath: path)
        let loaded = try ConversationIO.load(fromPath: path)
        XCTAssertEqual(loaded.id, convo.id)
        XCTAssertEqual(loaded.messages.count, 2)
        XCTAssertEqual(loaded.messages[0].content, "hello")
        XCTAssertEqual(loaded.modelID, "mock")
    }

    func testRebindProjectRoot() {
        let oldRoot = URL(fileURLWithPath: "/old")
        let newRoot = URL(fileURLWithPath: "/new/work")
        var c = Conversation(projectRoot: oldRoot)
        let under = SafeModeConfig.normalizePath("/old/src.swift")
        let outside = SafeModeConfig.normalizePath("/tmp/other.swift")
        c.sessionReadPaths = [under, outside]

        let rebound = ConversationIO.rebindProjectRoot(c, projectRoot: newRoot)
        XCTAssertEqual(rebound.projectRoot?.path, "/new/work")
        let expected = SafeModeConfig.normalizePath("/new/work/src.swift")
        XCTAssertTrue(
            rebound.sessionReadPaths.contains(expected),
            "reads under the old root must rebase: \(rebound.sessionReadPaths)")
        XCTAssertTrue(
            rebound.sessionReadPaths.contains(outside),
            "paths outside the old root stay put: \(rebound.sessionReadPaths)")
        XCTAssertFalse(rebound.sessionReadPaths.contains(under))
    }

    func testSaveMergesLiveTrackerPaths() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb6-save-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("src.swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let convo = Conversation(title: "eval", modelID: "mock", projectRoot: dir)
        track(convo.id)

        await SessionReadTracker.shared.clear(conversationID: convo.id)
        await SessionReadTracker.shared.recordRead(path: file.path, conversationID: convo.id)
        XCTAssertTrue(convo.sessionReadPaths.isEmpty)

        let path = dir.appendingPathComponent("c.json").path
        try await ConversationIO.save(convo, toPath: path)
        let loaded = try ConversationIO.load(fromPath: path)
        let norm = SafeModeConfig.normalizePath(file.path)
        XCTAssertTrue(
            loaded.sessionReadPaths.contains(norm),
            "save must persist live tracker reads: \(loaded.sessionReadPaths)")
    }

    func testSaveLoadRebindHydrateHitsNewPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb6-rebind-\(UUID().uuidString)", isDirectory: true)
        let oldDir = root.appendingPathComponent("old", isDirectory: true)
        let newDir = root.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldFile = oldDir.appendingPathComponent("src.swift")
        let newFile = newDir.appendingPathComponent("src.swift")
        try "let x = 1\n".write(to: oldFile, atomically: true, encoding: .utf8)
        try "let x = 1\n".write(to: newFile, atomically: true, encoding: .utf8)

        var convo = Conversation(title: "eval", modelID: "mock", projectRoot: oldDir)
        track(convo.id)
        convo.sessionReadPaths = [oldFile.path]

        let json = root.appendingPathComponent("c.json").path
        await SessionReadTracker.shared.clear(conversationID: convo.id)
        try await ConversationIO.save(convo, toPath: json)

        let loaded = try ConversationIO.load(fromPath: json)
        let rebound = ConversationIO.rebindProjectRoot(loaded, projectRoot: newDir)
        let newNorm = SafeModeConfig.normalizePath(newFile.path)
        let oldNorm = SafeModeConfig.normalizePath(oldFile.path)
        XCTAssertTrue(
            rebound.sessionReadPaths.contains(newNorm),
            "rebind must rewrite to the new workdir: \(rebound.sessionReadPaths)")
        XCTAssertFalse(rebound.sessionReadPaths.contains(oldNorm))

        await SessionReadTracker.shared.clear(conversationID: rebound.id)
        await ConversationIO.hydrateSessionReads(rebound)
        let hitNew = await SessionReadTracker.shared.hasRead(
            path: newFile.path, conversationID: rebound.id)
        let hitOld = await SessionReadTracker.shared.hasRead(
            path: oldFile.path, conversationID: rebound.id)
        XCTAssertTrue(hitNew, "eval --resume must seed the rebound path")
        XCTAssertFalse(hitOld, "stale workdir path must not remain after rebind")
    }

    func testHydrateEmptyDoesNotWipeLiveRead() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb6-empty-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("src.swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let convo = Conversation(title: "eval", modelID: "mock", projectRoot: dir)
        track(convo.id)
        XCTAssertTrue(convo.sessionReadPaths.isEmpty)

        await SessionReadTracker.shared.clear(conversationID: convo.id)
        await SessionReadTracker.shared.recordRead(path: file.path, conversationID: convo.id)
        await ConversationIO.hydrateSessionReads(convo)
        let hit = await SessionReadTracker.shared.hasRead(
            path: file.path, conversationID: convo.id)
        XCTAssertTrue(hit, "empty seed must not wipe a live recordRead")
    }

    func testResumeMissingThrows() {
        do {
            _ = try ConversationIO.load(fromPath: "/tmp/definitely-missing-\(UUID().uuidString).json")
            XCTFail("expected throw")
        } catch let e as EvalRunnerLibError {
            if case .resumeMissing = e {} else {
                XCTFail("expected resumeMissing, got \(e)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
