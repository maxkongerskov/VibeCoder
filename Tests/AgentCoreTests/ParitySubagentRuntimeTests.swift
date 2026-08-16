//
//  ParitySubagentRuntimeTests.swift
//
//  Wave-2 subagents: catalog concurrent-launch copy, profileSettings
//  on spawn, mailbox drain / resume.
//

import XCTest
@testable import AgentCore

// MARK: - Scripted backends

private final class InstantReplyBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let reply: String

    init(reply: String = "subagent-done") {
        self.reply = reply
    }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "mock", displayName: "Mock", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        let text = reply
        return AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta(text))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }

    func cancel(streamID: UUID) async {}
}

private final class LoopingListBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let lock = NSLock()
    private var turn = 0

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "loop", displayName: "Loop", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        let i = turn
        turn += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.toolCallDelta(
                index: 0, id: "c\(i)", name: "list_directory",
                argumentsAppend: #"{"path":"./n\#(i)"}"#))
            continuation.yield(.done(finishReason: "tool_calls"))
            continuation.finish()
        }
    }

    func cancel(streamID: UUID) async {}
}

final class ParitySubagentRuntimeTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await BackgroundJobManager.shared.cleanup()
        await AgentMailbox.shared.reset()
        await SubAgentRunner.resetSpawnRegistryForTests()
    }

    override func tearDown() async throws {
        await BackgroundJobManager.shared.cleanup()
        await AgentMailbox.shared.reset()
        await SubAgentRunner.resetSpawnRegistryForTests()
    }

    // MARK: - Catalog / schema

    func testCatalogDescriptionMentionsConcurrentSingleMessage() {
        let text = SubagentCatalog.taskToolDescription
        let lower = text.lowercased()
        XCTAssertTrue(lower.contains("concurrent") || lower.contains("concurrently"), text)
        XCTAssertTrue(lower.contains("single"), text)
        XCTAssertTrue(lower.contains("message"), text)
        XCTAssertTrue(lower.contains("self-contained") || lower.contains("starts fresh"), text)
        XCTAssertTrue(lower.contains("run_in_background"), text)
        XCTAssertEqual(TaskTool.schema.description, SubagentCatalog.taskToolDescription)
        XCTAssertNotNil(TaskTool.schema.parameters.properties["resume_agent_id"])
    }

    // MARK: - Profile apply

    func testFrontmatterMaxTurnsAndPermissionModeApplied() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-sub-profile-\(UUID().uuidString)", isDirectory: true)
        let agents = root.appendingPathComponent(".vibecoder/agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let md = """
        ---
        name: tight-builder
        description: capped planner
        maxTurns: 4
        permissionMode: plan
        background: true
        thoughtLevel: high
        model: glm-4.7
        tools: read_file, list_directory
        ---
        Stay in plan mode and stay brief.
        """
        try md.write(to: agents.appendingPathComponent("tight-builder.md"), atomically: true, encoding: .utf8)

        let def = AgentDefinitionDiscovery.byName("tight-builder", projectRoot: root)
        XCTAssertNotNil(def)
        XCTAssertEqual(def?.maxTurns, 4)
        XCTAssertEqual(def?.permissionMode, .plan)
        XCTAssertEqual(def?.background, true)

        let parent = ModelDescriptor(id: "parent-model", displayName: "Parent", backend: .lmStudio)
        let applied = SubAgentRunner.applyProfileSettings(
            def!.profileSettings,
            defaultMaxIterations: 15,
            parentBackground: nil,
            parentExecutionMode: .yolo,
            parentModel: parent
        )
        XCTAssertEqual(applied.maxIterations, 4)
        XCTAssertEqual(applied.executionMode?.rawValue, ExecutionMode.plan.rawValue)
        XCTAssertTrue(applied.runInBackground)
        XCTAssertEqual(applied.model.id, "glm-4.7")
        XCTAssertEqual(applied.model.backend, .lmStudio)
        XCTAssertNotNil(applied.thinking)
        XCTAssertEqual(applied.thinking?.effort, .high)
    }

    func testParentBackgroundFlagWinsOverProfile() {
        let settings = AgentProfileSettings(maxTurns: 8, background: true)
        let parent = ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio)
        let forcedFg = SubAgentRunner.applyProfileSettings(
            settings,
            defaultMaxIterations: 15,
            parentBackground: false,
            parentExecutionMode: .build,
            parentModel: parent
        )
        XCTAssertFalse(forcedFg.runInBackground)
        XCTAssertEqual(forcedFg.maxIterations, 8)
        XCTAssertEqual(forcedFg.executionMode?.rawValue, ExecutionMode.build.rawValue)

        let omitted = SubAgentRunner.applyProfileSettings(
            settings,
            defaultMaxIterations: 12,
            parentBackground: nil,
            parentExecutionMode: .yolo,
            parentModel: parent
        )
        XCTAssertTrue(omitted.runInBackground)
    }

    func testMaxTurnsTightensNotWidens() {
        let settings = AgentProfileSettings(permissionMode: .edit, maxTurns: 20)
        let parent = ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio)
        let applied = SubAgentRunner.applyProfileSettings(
            settings,
            defaultMaxIterations: 12,
            parentBackground: nil,
            parentExecutionMode: .yolo,
            parentModel: parent
        )
        XCTAssertEqual(applied.maxIterations, 12)
        XCTAssertEqual(applied.executionMode?.rawValue, ExecutionMode.edit.rawValue)
    }

    func testSpawnAppliesFrontmatterMaxTurns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-sub-spawn-\(UUID().uuidString)", isDirectory: true)
        let agents = root.appendingPathComponent(".vibecoder/agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let md = """
        ---
        name: two-turn
        description: hits cap
        maxTurns: 2
        permissionMode: plan
        tools: list_directory
        ---
        Keep listing.
        """
        try md.write(to: agents.appendingPathComponent("two-turn.md"), atomically: true, encoding: .utf8)

        let backend = LoopingListBackend()
        let model = ModelDescriptor(id: "loop", displayName: "Loop", backend: .lmStudio)
        let result = try await TaskTool().execute(
            arguments: ToolArguments(dictionary: [
                "prompt": "list everything",
                "description": "cap test",
                "subagent_type": "two-turn",
            ]),
            context: ToolContext(
                projectRoot: root,
                conversationID: UUID(),
                inferenceBackend: backend,
                model: model,
                executionMode: .yolo
            )
        )
        XCTAssertTrue(result.content.contains("iterations: 2")
                      || result.content.contains("hit_cap: true")
                      || result.content.lowercased().contains("iteration cap"),
                      result.content)
        XCTAssertTrue(result.content.contains("agent_"), result.content)
    }

    // MARK: - Mailbox drain

    func testFormatCoordinatorMessages() {
        let id = AgentMailbox.makeAgentId()
        let msgs = [
            AgentMailbox.Message(to: id, summary: "steer auth", message: "look at Foo.swift"),
            AgentMailbox.Message(to: id, summary: "also bar", message: "then Bar.swift"),
        ]
        let text = SubAgentRunner.formatCoordinatorMessages(msgs)
        XCTAssertTrue(text.contains("Message from coordinator: look at Foo.swift"), text)
        XCTAssertTrue(text.contains("Message from coordinator: then Bar.swift"), text)
        XCTAssertEqual(SubAgentRunner.formatCoordinatorMessages([]), "")
    }

    func testMailboxDrainInjectsCoordinatorText() async {
        let agentId = AgentMailbox.makeAgentId()
        _ = await AgentMailbox.shared.send(
            to: agentId, summary: "steer review", message: "please inspect Auth.swift")

        let result = await SubAgentRunner.run(
            prompt: "explore the repo",
            allowedTools: ["list_directory"],
            backend: InstantReplyBackend(reply: "found-auth"),
            model: ModelDescriptor(id: "mock", displayName: "Mock", backend: .lmStudio),
            registry: ToolRegistry.shared,
            projectRoot: FileManager.default.temporaryDirectory,
            mailboxAgentId: agentId
        )
        XCTAssertTrue(result.finalText.contains("found-auth"), result.finalText)
        let userTexts = result.transcript.messages.filter { $0.role == .user }.map(\.content)
        XCTAssertTrue(
            userTexts.contains(where: {
                $0.contains("Message from coordinator:") && $0.contains("Auth.swift")
            }),
            "users=\(userTexts)"
        )
        let leftover = await AgentMailbox.shared.drain(agentId: agentId)
        XCTAssertTrue(leftover.isEmpty)
        let completed = await AgentMailbox.shared.isCompleted(agentId: agentId)
        XCTAssertTrue(completed)
    }

    func testTaskSpawnMarksMailboxRunningThenCompleted() async throws {
        let backend = InstantReplyBackend(reply: "ok-report")
        let model = ModelDescriptor(id: "mock", displayName: "Mock", backend: .lmStudio)
        let result = try await TaskTool().execute(
            arguments: ToolArguments(dictionary: [
                "prompt": "quick look",
                "description": "mailbox lifecycle",
                "subagent_type": "explore",
            ]),
            context: ToolContext(
                projectRoot: FileManager.default.temporaryDirectory,
                conversationID: UUID(),
                inferenceBackend: backend,
                model: model,
                executionMode: .yolo
            )
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("ok-report"), result.content)
        let line = result.content.split(separator: "\n").first { $0.contains("agent_id:") }
        XCTAssertNotNil(line, result.content)
        let idStr = line!.split(separator: ":", maxSplits: 1).last!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(idStr.hasPrefix("agent_"), idStr)
        let completed = await AgentMailbox.shared.isCompleted(agentId: idStr)
        XCTAssertTrue(completed)
    }

    func testResumeIfRequestedStartsBackgroundJob() async throws {
        let backend = InstantReplyBackend(reply: "first-pass")
        let model = ModelDescriptor(id: "mock", displayName: "Mock", backend: .lmStudio)
        let spawned = try await TaskTool().execute(
            arguments: ToolArguments(dictionary: [
                "prompt": "start work",
                "description": "resume later",
                "subagent_type": "explore",
            ]),
            context: ToolContext(
                projectRoot: FileManager.default.temporaryDirectory,
                conversationID: UUID(),
                inferenceBackend: backend,
                model: model,
                executionMode: .yolo
            )
        )
        let line = spawned.content.split(separator: "\n").first { $0.contains("agent_id:") }!
        let agentId = line.split(separator: ":", maxSplits: 1).last!
            .trimmingCharacters(in: .whitespacesAndNewlines)

        await AgentMailbox.shared.markCompleted(agentId)
        _ = await AgentMailbox.shared.send(
            to: agentId, summary: "continue work", message: "now check Tests/")
        let resumeFlag = await AgentMailbox.shared.resumeRequested(agentId: agentId)
        XCTAssertTrue(resumeFlag)

        let resumed = try await TaskTool().execute(
            arguments: ToolArguments(dictionary: [
                "resume_agent_id": agentId,
            ]),
            context: ToolContext(
                projectRoot: FileManager.default.temporaryDirectory,
                conversationID: UUID(),
                inferenceBackend: backend,
                model: model,
                executionMode: .yolo
            )
        )
        XCTAssertFalse(resumed.isError, resumed.content)
        XCTAssertTrue(resumed.content.lowercased().contains("resume"), resumed.content)
        XCTAssertTrue(resumed.content.contains("task_id:"), resumed.content)

        let jobLine = resumed.content.split(separator: "\n").first { $0.contains("task_id:") }!
        let jobStr = jobLine.split(separator: ":", maxSplits: 1).last!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let jobID = try XCTUnwrap(UUID(uuidString: jobStr))
        let snap = await BackgroundJobManager.shared.wait(id: jobID, timeoutMs: 10_000)
        XCTAssertNotNil(snap)
        XCTAssertTrue(
            snap?.status == .completed || snap?.status == .failed,
            "\(String(describing: snap?.status))")
    }

    func testResumeWithoutRequestIsError() async throws {
        let result = try await TaskTool().execute(
            arguments: ToolArguments(dictionary: [
                "resume_agent_id": AgentMailbox.makeAgentId(),
            ]),
            context: ToolContext(
                projectRoot: FileManager.default.temporaryDirectory,
                conversationID: UUID(),
                subagentDepth: 0
            )
        )
        XCTAssertTrue(result.isError, result.content)
        XCTAssertTrue(result.content.lowercased().contains("resume"), result.content)
    }

    func testDepthStillBlocksResume() async throws {
        let result = try await TaskTool().execute(
            arguments: ToolArguments(dictionary: [
                "resume_agent_id": AgentMailbox.makeAgentId(),
            ]),
            context: ToolContext(
                projectRoot: FileManager.default.temporaryDirectory,
                conversationID: UUID(),
                subagentDepth: 1
            )
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("depth"), result.content)
    }
}
