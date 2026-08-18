//
//  ParityMemoryUpdateTests.swift
//  Mid-turn memory_update reminder (write actions only; no embeddings).
//

import XCTest
@testable import AgentCore

final class ParityMemoryUpdateTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-memupd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir {
            try? FileManager.default.removeItem(at: dir)
        }
        dir = nil
    }

    private func ctx() -> ToolContext {
        ToolContext(projectRoot: dir, conversationID: UUID())
    }

    private func args(_ dict: [String: Any]) -> ToolArguments {
        ToolArguments(dictionary: dict)
    }

    // MARK: - Formatter

    func testExtrasKeyAndHeading() {
        XCTAssertEqual(MemoryUpdateReminder.extrasKey, "memory_update")
        XCTAssertTrue(MemoryUpdateReminder.heading.hasPrefix("# System reminder"))
        XCTAssertTrue(SystemReminder.isWireOnly(MemoryUpdateReminder.heading + "\nbody"))
        XCTAssertTrue(SystemReminder.isSystemReminder(MemoryUpdateReminder.heading + "\nbody"))
    }

    func testFormatIncludesActionAndClippedBody() {
        let long = String(repeating: "keep-this-fact ", count: 80)
        let text = MemoryUpdateReminder.format(action: "remember", body: long)
        XCTAssertTrue(MemoryUpdateReminder.isMemoryUpdate(text), text)
        XCTAssertTrue(text.contains("Action: remember"), text)
        XCTAssertTrue(text.contains("keep-this-fact"), text)
        XCTAssertTrue(text.contains("stale"), text)
        XCTAssertLessThan(text.count, long.count + 400)
        XCTAssertTrue(text.contains("…"), "long body should clip")
    }

    func testClipShortBodyUnchanged() {
        XCTAssertEqual(MemoryUpdateReminder.clip("  hello  "), "hello")
    }

    func testShouldEmitWriteOnly() {
        XCTAssertTrue(MemoryUpdateReminder.shouldEmit(
            action: "remember", isError: false, body: "fact"))
        XCTAssertTrue(MemoryUpdateReminder.shouldEmit(
            action: "log_decision", isError: false, body: "use SwiftUI"))
        XCTAssertTrue(MemoryUpdateReminder.shouldEmit(
            action: "write_handoff", isError: false, body: "shipped compact"))
        XCTAssertFalse(MemoryUpdateReminder.shouldEmit(
            action: "read", isError: false, body: "anything"))
        XCTAssertFalse(MemoryUpdateReminder.shouldEmit(
            action: "remember", isError: true, body: "fact"))
        XCTAssertFalse(MemoryUpdateReminder.shouldEmit(
            action: "remember", isError: false, body: "   "))
        XCTAssertFalse(MemoryUpdateReminder.shouldEmit(
            action: "unknown", isError: false, body: "fact"))
    }

    func testResultAttachesExtrasAndKeepsAckPrefix() {
        let result = MemoryUpdateReminder.result(
            content: "Remembered in workspace memory (fact…).",
            action: "remember",
            body: "prefer patches over rewrites",
            mutatedPaths: ["MEMORY.md"])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.mutatedPaths, ["MEMORY.md"])
        XCTAssertTrue(result.content.hasPrefix("Remembered in workspace memory"), result.content)
        let extra = MemoryUpdateReminder.extract(result.extras)
        XCTAssertNotNil(extra)
        XCTAssertTrue(MemoryUpdateReminder.isMemoryUpdate(extra!), extra ?? "nil")
        XCTAssertTrue(result.content.contains(extra!), "content should carry the reminder for this turn")
        XCTAssertTrue(extra!.contains("prefer patches over rewrites"), extra ?? "")
    }

    func testResultDoesNotEmitOnReadAction() {
        let result = MemoryUpdateReminder.result(
            content: "file body",
            action: "read",
            body: "file body")
        XCTAssertTrue(result.extras.isEmpty)
        XCTAssertEqual(result.content, "file body")
        XCTAssertNil(MemoryUpdateReminder.extract(result.extras))
        XCTAssertFalse(MemoryUpdateReminder.isMemoryUpdate("Please edit App.swift"))
    }

    // MARK: - MemoryTool writes

    func testRememberSetsMemoryUpdateExtras() async throws {
        let tool = MemoryTool()
        let result = try await tool.execute(
            arguments: args([
                "action": "remember",
                "text": "Always isolate agent edits in a git worktree.",
            ]),
            context: ctx())
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.hasPrefix("Remembered in workspace memory"), result.content)
        let extra = MemoryUpdateReminder.extract(result.extras)
        XCTAssertNotNil(extra, "remember must set extras[\(MemoryUpdateReminder.extrasKey)]")
        XCTAssertTrue(MemoryUpdateReminder.isMemoryUpdate(extra!), extra ?? "")
        XCTAssertTrue(extra!.contains("Action: remember"), extra ?? "")
        XCTAssertTrue(extra!.contains("worktree"), extra ?? "")
        XCTAssertTrue(result.content.contains(MemoryUpdateReminder.heading), result.content)
    }

    func testLogDecisionSetsMemoryUpdateExtras() async throws {
        let tool = MemoryTool()
        let result = try await tool.execute(
            arguments: args([
                "action": "log_decision",
                "decision": "Use extractive compact, not embeddings.",
                "rationale": "ZCode ships semantic recall disabled.",
                "avoid": "sqlite-vec",
            ]),
            context: ctx())
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.hasPrefix("Decision logged"), result.content)
        let extra = MemoryUpdateReminder.extract(result.extras)
        XCTAssertNotNil(extra)
        XCTAssertTrue(extra!.contains("Action: log_decision"), extra ?? "")
        XCTAssertTrue(extra!.contains("extractive compact"), extra ?? "")
        XCTAssertTrue(extra!.contains("sqlite-vec"), extra ?? "")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("DECISIONS.md").path))
    }

    func testWriteHandoffSetsMemoryUpdateExtras() async throws {
        let tool = MemoryTool()
        let result = try await tool.execute(
            arguments: args([
                "action": "write_handoff",
                "summary": "Shipped 9-section compact.",
                "nextSteps": "memory_update reminder.",
            ]),
            context: ctx())
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.hasPrefix("Session handoff written"), result.content)
        let extra = MemoryUpdateReminder.extract(result.extras)
        XCTAssertNotNil(extra)
        XCTAssertTrue(extra!.contains("Action: write_handoff"), extra ?? "")
        XCTAssertTrue(extra!.contains("9-section compact"), extra ?? "")
    }

    // MARK: - No emit

    func testReadDoesNotSetMemoryUpdate() async throws {
        try "# Design Decisions\n\nplanted\n"
            .write(to: dir.appendingPathComponent("DECISIONS.md"), atomically: true, encoding: .utf8)
        let tool = MemoryTool()
        let result = try await tool.execute(
            arguments: args(["action": "read", "file": "decisions"]),
            context: ctx())
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("planted"), result.content)
        XCTAssertNil(MemoryUpdateReminder.extract(result.extras))
        XCTAssertFalse(result.content.contains(MemoryUpdateReminder.heading), result.content)
    }

    func testRememberMissingTextDoesNotSetExtras() async throws {
        let tool = MemoryTool()
        let result = try await tool.execute(
            arguments: args(["action": "remember"]),
            context: ctx())
        XCTAssertTrue(result.isError)
        XCTAssertNil(MemoryUpdateReminder.extract(result.extras))
        XCTAssertFalse(result.content.contains(MemoryUpdateReminder.heading))
    }

    func testLogDecisionMissingFieldsDoesNotSetExtras() async throws {
        let tool = MemoryTool()
        let result = try await tool.execute(
            arguments: args(["action": "log_decision", "decision": "only"]),
            context: ctx())
        XCTAssertTrue(result.isError)
        XCTAssertNil(MemoryUpdateReminder.extract(result.extras))
    }

    func testUnknownActionDoesNotSetExtras() async throws {
        let tool = MemoryTool()
        let result = try await tool.execute(
            arguments: args(["action": "explode"]),
            context: ctx())
        XCTAssertTrue(result.isError)
        XCTAssertNil(MemoryUpdateReminder.extract(result.extras))
    }
}
