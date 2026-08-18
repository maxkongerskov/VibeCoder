//
//  ConversationIOTests.swift
//  Phase B PB6 — resume / save conversation JSON round-trip.
//

import XCTest
import AgentCore
@testable import EvalRunnerLib

final class ConversationIOTests: XCTestCase {

    func testSaveLoadRoundTrip() throws {
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
        convo.messages.append(ChatMessage(role: .user, content: "hello"))
        convo.messages.append(ChatMessage(role: .assistant, content: "world"))

        try ConversationIO.save(convo, toPath: path)
        let loaded = try ConversationIO.load(fromPath: path)
        XCTAssertEqual(loaded.id, convo.id)
        XCTAssertEqual(loaded.messages.count, 2)
        XCTAssertEqual(loaded.messages[0].content, "hello")
        XCTAssertEqual(loaded.modelID, "mock")
    }

    func testRebindProjectRoot() {
        var c = Conversation(projectRoot: URL(fileURLWithPath: "/old"))
        let rebound = ConversationIO.rebindProjectRoot(
            c, projectRoot: URL(fileURLWithPath: "/new/work"))
        XCTAssertEqual(rebound.projectRoot?.path, "/new/work")
    }

    func testHydrateSessionReadsSeedsTracker() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb6-hydrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("src.swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        var convo = Conversation(title: "eval", modelID: "mock", projectRoot: dir)
        convo.sessionReadPaths = [file.path]

        await SessionReadTracker.shared.clear(conversationID: convo.id)
        await ConversationIO.hydrateSessionReads(convo)
        let hit = await SessionReadTracker.shared.hasRead(
            path: file.path, conversationID: convo.id)
        XCTAssertTrue(hit, "eval --resume must seed SessionReadTracker")
        await SessionReadTracker.shared.clear(conversationID: convo.id)
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
