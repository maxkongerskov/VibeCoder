//
//  ParityParentChildSpawnTests.swift
//
//  Child ToolContext uses parentConversationID, so SkillToolGate
//  recorded on the parent conversation applies to task/subagent tools.
//

import XCTest
@testable import AgentCore

private final class OneToolThenStopBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let lock = NSLock()
    private var turn = 0
    private let toolName: String
    private let argumentsJSON: String

    init(toolName: String, argumentsJSON: String) {
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "spawn-mock", displayName: "Spawn", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        let i = turn
        turn += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if i == 0 {
                continuation.yield(.toolCallDelta(
                    index: 0, id: "child-1", name: toolName,
                    argumentsAppend: argumentsJSON))
                continuation.yield(.done(finishReason: "tool_calls"))
            } else {
                continuation.yield(.contentDelta("child-done"))
                continuation.yield(.done(finishReason: "stop"))
            }
            continuation.finish()
        }
    }

    func cancel(streamID: UUID) async {}
}

final class ParityParentChildSpawnTests: XCTestCase {

    private var root: URL!
    private var parentID: UUID!
    private let model = ModelDescriptor(id: "spawn-mock", displayName: "Spawn", backend: .lmStudio)

    override func setUp() async throws {
        parentID = UUID()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parent-child-\(parentID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await ToolRegistry.shared.registerBuiltins()
        await BackgroundJobManager.shared.cleanup()
        await AgentMailbox.shared.reset()
        await SubAgentRunner.resetSpawnRegistryForTests()
    }

    override func tearDown() async throws {
        if let parentID {
            await SkillToolGate.shared.clear(conversationID: parentID)
        }
        await BackgroundJobManager.shared.cleanup()
        await AgentMailbox.shared.reset()
        await SubAgentRunner.resetSpawnRegistryForTests()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func parentContext(disabled: Set<String> = []) -> ToolContext {
        ToolContext(
            projectRoot: root,
            conversationID: parentID,
            inferenceBackend: InstantStopBackend(),
            model: model,
            executionMode: .yolo,
            disabledToolNames: disabled
        )
    }

    private func writeSkill(name: String, allowedToolsLine: String) throws {
        let dir = root.appendingPathComponent(".vibecoder/skills/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: \(name)
        \(allowedToolsLine)
        ---
        Body
        """.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func loadSkill(_ name: String, conversationID: UUID? = nil) async throws -> ToolResult {
        try await ToolRegistry.shared.execute(
            name: "load_skill",
            arguments: ToolArguments(dictionary: ["skill": name]),
            context: ToolContext(
                projectRoot: root,
                conversationID: conversationID ?? parentID,
                executionMode: .yolo))
    }

    private func childAllowed() -> Set<String> {
        SubagentType.generalPurpose.allowedTools(capability: .all)
    }

    // MARK: - Shared conversation key

    func testChildRunnerUsesParentConversationIDForSkillGate() async throws {
        try writeSkill(name: "gated", allowedToolsLine: "allowed-tools: list_directory, task")
        let loaded = try await loadSkill("gated")
        XCTAssertFalse(loaded.isError, loaded.content)

        let marker = root.appendingPathComponent("child-must-not-create")
        let backend = OneToolThenStopBackend(
            toolName: "create_directory",
            argumentsJSON: #"{"path":"child-must-not-create"}"#)
        let result = await SubAgentRunner.run(
            prompt: "make a folder",
            allowedTools: childAllowed(),
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            projectRoot: root,
            executionMode: .yolo,
            parentConversationID: parentID
        )
        let tool = try XCTUnwrap(result.transcript.messages.first {
            $0.role == .tool && $0.toolCallID == "child-1"
        })
        XCTAssertTrue(tool.content.contains("not permitted") || tool.content.contains("allowlist"),
                      tool.content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testChildListDirectoryStillAllowedUnderParentGate() async throws {
        try writeSkill(name: "gated", allowedToolsLine: "allowed-tools: list_directory, task")
        _ = try await loadSkill("gated")

        let backend = OneToolThenStopBackend(
            toolName: "list_directory",
            argumentsJSON: #"{"path":"."}"#)
        let result = await SubAgentRunner.run(
            prompt: "list",
            allowedTools: childAllowed(),
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            projectRoot: root,
            executionMode: .yolo,
            parentConversationID: parentID
        )
        let tool = try XCTUnwrap(result.transcript.messages.first {
            $0.role == .tool && $0.toolCallID == "child-1"
        })
        XCTAssertFalse(tool.content.lowercased().contains("not permitted"), tool.content)
        XCTAssertFalse(tool.content.lowercased().contains("allowlist"), tool.content)
    }

    func testOtherConversationChildIsNotGated() async throws {
        try writeSkill(name: "gated", allowedToolsLine: "allowed-tools: list_directory, task")
        _ = try await loadSkill("gated")

        let other = UUID()
        defer { Task { await SkillToolGate.shared.clear(conversationID: other) } }

        let backend = OneToolThenStopBackend(
            toolName: "create_directory",
            argumentsJSON: #"{"path":"other-ok"}"#)
        let result = await SubAgentRunner.run(
            prompt: "make folder",
            allowedTools: childAllowed(),
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            projectRoot: root,
            executionMode: .yolo,
            parentConversationID: other
        )
        let tool = try XCTUnwrap(result.transcript.messages.first {
            $0.role == .tool && $0.toolCallID == "child-1"
        })
        XCTAssertFalse(tool.content.lowercased().contains("not permitted"), tool.content)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("other-ok").path),
            tool.content)
    }

    // MARK: - TaskTool spawn

    func testTaskSpawnDeniedWhenTaskNotOnAllowlist() async throws {
        try writeSkill(name: "no-task", allowedToolsLine: "allowed-tools: list_directory")
        _ = try await loadSkill("no-task")

        let denied = try await ToolRegistry.shared.execute(
            name: "task",
            arguments: ToolArguments(dictionary: [
                "prompt": "explore",
                "description": "blocked spawn",
                "subagent_type": "explore",
            ]),
            context: parentContext())
        XCTAssertTrue(denied.isError, denied.content)
        XCTAssertTrue(
            denied.content.contains("not permitted") || denied.content.contains("allowlist"),
            denied.content)
    }

    func testTaskSpawnChildHonorsParentGate() async throws {
        try writeSkill(name: "spawn-ok", allowedToolsLine: "allowed-tools: list_directory, task")
        _ = try await loadSkill("spawn-ok")

        let backend = OneToolThenStopBackend(
            toolName: "create_directory",
            argumentsJSON: #"{"path":"task-spawn-blocked"}"#)
        let result = try await TaskTool().execute(
            arguments: ToolArguments(dictionary: [
                "prompt": "mkdir",
                "description": "gated child",
                "subagent_type": "general-purpose",
            ]),
            context: ToolContext(
                projectRoot: root,
                conversationID: parentID,
                inferenceBackend: backend,
                model: model,
                executionMode: .yolo
            )
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("task-spawn-blocked").path),
            result.content)
    }
}

private final class InstantStopBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "spawn-mock", displayName: "Spawn", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta("unused"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }

    func cancel(streamID: UUID) async {}
}
