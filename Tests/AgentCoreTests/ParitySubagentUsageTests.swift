//
//  ParitySubagentUsageTests.swift
//
//  Child usage telemetry + transcript JSONL persist.
//

import XCTest
@testable import AgentCore

private final class MidRunInspectBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let lock = NSLock()
    private var turnIndex = 0
    private let turns: [[ChatChunk]]
    private let parent: UUID
    private let agentId: String
    private(set) var metaAtStreamStart: SubagentSessionMetadata?
    private(set) var metaBeforeSecondTurn: SubagentSessionMetadata?

    init(parent: UUID, agentId: String, turns: [[ChatChunk]]) {
        self.parent = parent
        self.agentId = agentId
        self.turns = turns
    }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "usage-test", displayName: "Usage", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        let i = turnIndex
        let chunks: [ChatChunk]
        if turnIndex < turns.count {
            chunks = turns[turnIndex]
        } else {
            chunks = [.contentDelta("done"), .done(finishReason: "stop")]
        }
        turnIndex += 1
        lock.unlock()
        let parent = self.parent
        let agentId = self.agentId
        return AsyncThrowingStream { continuation in
            Task {
                let snap = await SubagentSessionStore.shared.loadMetadata(
                    parentConversationID: parent, agentId: agentId)
                if i == 0 {
                    self.metaAtStreamStart = snap
                } else if i == 1 {
                    self.metaBeforeSecondTurn = snap
                }
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }

    func cancel(streamID: UUID) async {}
}

private final class ScriptedUsageBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let lock = NSLock()
    private var turnIndex = 0
    private let turns: [[ChatChunk]]

    init(turns: [[ChatChunk]]) {
        self.turns = turns
    }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "usage-test", displayName: "Usage", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        let chunks: [ChatChunk]
        if turnIndex < turns.count {
            chunks = turns[turnIndex]
        } else {
            chunks = [.contentDelta("done"), .done(finishReason: "stop")]
        }
        turnIndex += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    func cancel(streamID: UUID) async {}
}

final class ParitySubagentUsageTests: XCTestCase {

    private var scratch: URL!

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await BackgroundJobManager.shared.cleanup()
        await AgentMailbox.shared.reset()
        await SubAgentRunner.resetSpawnRegistryForTests()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagent-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        await SubagentSessionStore.shared.resetForTests()
        await SubagentSessionStore.shared.setDirectoryOverride(scratch)
    }

    override func tearDown() async throws {
        await SubagentSessionStore.shared.resetForTests()
        await BackgroundJobManager.shared.cleanup()
        await AgentMailbox.shared.reset()
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    private var model: ModelDescriptor {
        ModelDescriptor(id: "usage-test", displayName: "Usage", backend: .lmStudio)
    }

    // MARK: - Usage accumulation

    func testUsageChunksAreSummed() async {
        let backend = ScriptedUsageBackend(turns: [[
            .contentDelta("ok"),
            .usage(promptTokens: 10, completionTokens: 4),
            .usage(promptTokens: 3, completionTokens: 2),
            .done(finishReason: "stop"),
        ]])
        let result = await SubAgentRunner.run(
            prompt: "sum tokens",
            allowedTools: ["list_directory"],
            backend: backend,
            model: model,
            registry: ToolRegistry.shared
        )
        XCTAssertEqual(result.usage.inputTokens, 13)
        XCTAssertEqual(result.usage.outputTokens, 6)
        XCTAssertEqual(result.usage.totalTokens, 19)
        XCTAssertEqual(result.usage.cacheReadTokens, 0)
        XCTAssertEqual(result.usage.cacheWriteTokens, 0)
        XCTAssertEqual(result.finishReason, "stop")
        XCTAssertEqual(result.toolCount, 0)
        XCTAssertTrue(result.finalText.contains("ok"), result.finalText)
    }

    func testDoneDoesNotHaltToolDispatch() async {
        let backend = ScriptedUsageBackend(turns: [
            [
                .toolCallDelta(
                    index: 0, id: "c1", name: "list_directory",
                    argumentsAppend: #"{"path":"."}"#),
                .usage(promptTokens: 10, completionTokens: 2),
                .done(finishReason: "tool_calls"),
            ],
            [
                .contentDelta("listed-root"),
                .usage(promptTokens: 5, completionTokens: 8),
                .done(finishReason: "stop"),
            ],
        ])
        let result = await SubAgentRunner.run(
            prompt: "list then stop",
            allowedTools: ["list_directory"],
            backend: backend,
            model: model,
            registry: ToolRegistry.shared
        )
        XCTAssertEqual(result.finishReason, "stop")
        XCTAssertEqual(result.usage.inputTokens, 15)
        XCTAssertEqual(result.usage.outputTokens, 10)
        XCTAssertEqual(result.toolCount, 1)
        XCTAssertTrue(
            result.transcript.messages.contains(where: { $0.role == .tool && $0.toolCallID == "c1" }),
            "done(tool_calls) must not skip dispatch: \(result.transcript.messages.map(\.role))"
        )
        XCTAssertTrue(result.finalText.contains("listed-root"), result.finalText)
    }

    func testCacheTokensStayZero() async {
        let backend = ScriptedUsageBackend(turns: [[
            .contentDelta("hi"),
            .usage(promptTokens: 1, completionTokens: 1),
            .done(finishReason: "stop"),
        ]])
        let result = await SubAgentRunner.run(
            prompt: "cache zero",
            backend: backend,
            model: model,
            registry: ToolRegistry.shared
        )
        XCTAssertEqual(result.usage.cacheReadTokens, 0)
        XCTAssertEqual(result.usage.cacheWriteTokens, 0)
    }

    // MARK: - Persist

    func testPersistsTranscriptMetadataAndOutput() async throws {
        let parent = UUID()
        let agentId = AgentMailbox.makeAgentId()
        let backend = ScriptedUsageBackend(turns: [[
            .contentDelta("report-body"),
            .usage(promptTokens: 20, completionTokens: 7),
            .done(finishReason: "stop"),
        ]])
        let result = await SubAgentRunner.run(
            prompt: "write artifacts",
            allowedTools: ["list_directory"],
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            parentConversationID: parent,
            mailboxAgentId: agentId
        )
        XCTAssertTrue(result.finalText.contains("report-body"), result.finalText)

        let store = SubagentSessionStore.shared
        let dir = await store.sessionDirectory(parentConversationID: parent, agentId: agentId)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcript.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("metadata.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("output.txt").path))

        let messages = await store.loadTranscript(parentConversationID: parent, agentId: agentId)
        XCTAssertTrue(messages.contains(where: { $0.role == .system }))
        XCTAssertTrue(messages.contains(where: { $0.role == .user && $0.content.contains("write artifacts") }))
        XCTAssertTrue(messages.contains(where: { $0.role == .assistant && $0.content.contains("report-body") }))

        let loadedMeta = await store.loadMetadata(parentConversationID: parent, agentId: agentId)
        let meta = try XCTUnwrap(loadedMeta)
        XCTAssertEqual(meta.agentId, agentId)
        XCTAssertEqual(meta.parentConversationId, parent)
        XCTAssertEqual(meta.usage.inputTokens, 20)
        XCTAssertEqual(meta.usage.outputTokens, 7)
        XCTAssertEqual(meta.usage.cacheReadTokens, 0)
        XCTAssertEqual(meta.usage.cacheWriteTokens, 0)
        XCTAssertEqual(meta.totalTokens, 27)
        XCTAssertEqual(meta.totalToolUseCount, 0)
        XCTAssertEqual(meta.finishReason, "stop")
        XCTAssertEqual(meta.status, "completed")
        XCTAssertGreaterThanOrEqual(meta.totalDurationMs, 0)

        let loadedOutput = await store.loadOutput(parentConversationID: parent, agentId: agentId)
        let output = try XCTUnwrap(loadedOutput)
        XCTAssertTrue(output.contains("report-body"), output)
    }

    func testResumeAppendsSameAgentJSONLAndSumsUsage() async {
        let parent = UUID()
        let agentId = AgentMailbox.makeAgentId()

        _ = await SubAgentRunner.run(
            prompt: "first pass",
            backend: ScriptedUsageBackend(turns: [[
                .contentDelta("pass-one"),
                .usage(promptTokens: 10, completionTokens: 5),
                .done(finishReason: "stop"),
            ]]),
            model: model,
            registry: ToolRegistry.shared,
            parentConversationID: parent,
            mailboxAgentId: agentId
        )
        let store = SubagentSessionStore.shared
        let first = await store.loadTranscript(parentConversationID: parent, agentId: agentId)
        XCTAssertFalse(first.isEmpty)

        _ = await SubAgentRunner.run(
            prompt: "second pass",
            backend: ScriptedUsageBackend(turns: [[
                .contentDelta("pass-two"),
                .usage(promptTokens: 3, completionTokens: 2),
                .done(finishReason: "stop"),
            ]]),
            model: model,
            registry: ToolRegistry.shared,
            parentConversationID: parent,
            mailboxAgentId: agentId
        )
        let second = await store.loadTranscript(parentConversationID: parent, agentId: agentId)
        XCTAssertGreaterThan(second.count, first.count)
        XCTAssertTrue(second.contains(where: { $0.content.contains("pass-one") }))
        XCTAssertTrue(second.contains(where: { $0.content.contains("pass-two") }))

        let meta = await store.loadMetadata(parentConversationID: parent, agentId: agentId)
        XCTAssertEqual(meta?.usage.inputTokens, 13)
        XCTAssertEqual(meta?.usage.outputTokens, 7)
        XCTAssertEqual(meta?.totalTokens, 20)
        let output = await store.loadOutput(parentConversationID: parent, agentId: agentId)
        XCTAssertEqual(output, "pass-two")
    }

    func testDraftsAreNotPersistedAsExtraMessages() async {
        let parent = UUID()
        let agentId = AgentMailbox.makeAgentId()
        let backend = ScriptedUsageBackend(turns: [[
            .reasoningDelta("thinking"),
            .contentDelta("final-only"),
            .usage(promptTokens: 2, completionTokens: 2),
            .done(finishReason: "stop"),
        ]])
        _ = await SubAgentRunner.run(
            prompt: "no drafts on disk",
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            parentConversationID: parent,
            mailboxAgentId: agentId
        )
        let messages = await SubagentSessionStore.shared.loadTranscript(
            parentConversationID: parent, agentId: agentId)
        let assistants = messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1)
        XCTAssertEqual(assistants.first?.content, "final-only")
    }

    func testMidRunMetadataWrittenBeforeFinish() async {
        let parent = UUID()
        let agentId = AgentMailbox.makeAgentId()
        let backend = MidRunInspectBackend(
            parent: parent,
            agentId: agentId,
            turns: [
                [
                    .toolCallDelta(
                        index: 0, id: "c1", name: "list_directory",
                        argumentsAppend: #"{"path":"."}"#),
                    .usage(promptTokens: 11, completionTokens: 3),
                    .done(finishReason: "tool_calls"),
                ],
                [
                    .contentDelta("after-tools"),
                    .usage(promptTokens: 2, completionTokens: 1),
                    .done(finishReason: "stop"),
                ],
            ]
        )
        let result = await SubAgentRunner.run(
            prompt: "mid-run telemetry",
            allowedTools: ["list_directory"],
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            parentConversationID: parent,
            mailboxAgentId: agentId
        )
        XCTAssertTrue(result.finalText.contains("after-tools"), result.finalText)

        let atStart = backend.metaAtStreamStart
        XCTAssertEqual(atStart?.status, "running")
        XCTAssertNil(atStart?.completedAt)
        XCTAssertEqual(atStart?.usage.inputTokens, 0)

        let mid = backend.metaBeforeSecondTurn
        XCTAssertEqual(mid?.status, "running")
        XCTAssertNil(mid?.completedAt)
        XCTAssertEqual(mid?.usage.inputTokens, 11)
        XCTAssertEqual(mid?.usage.outputTokens, 3)
        XCTAssertEqual(mid?.totalToolUseCount, 1)
        XCTAssertEqual(mid?.iterations, 1)

        let done = await SubagentSessionStore.shared.loadMetadata(
            parentConversationID: parent, agentId: agentId)
        XCTAssertEqual(done?.status, "completed")
        XCTAssertNotNil(done?.completedAt)
        XCTAssertEqual(done?.usage.inputTokens, 13)
        XCTAssertEqual(done?.totalToolUseCount, 1)
    }

    func testPruneConversationRemovesOnlyThatParent() async {
        let parentA = UUID()
        let parentB = UUID()
        let agentA = AgentMailbox.makeAgentId()
        let agentB = AgentMailbox.makeAgentId()
        let store = SubagentSessionStore.shared
        await store.begin(parentConversationID: parentA, agentId: agentA)
        await store.updateProgress(
            parentConversationID: parentA, agentId: agentA,
            usage: SubagentUsage(inputTokens: 4, outputTokens: 1),
            toolCount: 1, durationMs: 10, finishReason: nil, iterations: 1)
        await store.finish(
            parentConversationID: parentA, agentId: agentA,
            output: "a", usage: SubagentUsage(inputTokens: 4, outputTokens: 1),
            toolCount: 1, durationMs: 10, finishReason: "stop",
            iterations: 1, status: "completed")
        await store.begin(parentConversationID: parentB, agentId: agentB)
        await store.updateProgress(
            parentConversationID: parentB, agentId: agentB,
            usage: SubagentUsage(inputTokens: 9, outputTokens: 2),
            toolCount: 0, durationMs: 5, finishReason: nil, iterations: 1)
        await store.finish(
            parentConversationID: parentB, agentId: agentB,
            output: "b", usage: SubagentUsage(inputTokens: 9, outputTokens: 2),
            toolCount: 0, durationMs: 5, finishReason: "stop",
            iterations: 1, status: "completed")

        let dirA = await store.conversationDirectory(parentConversationID: parentA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirA.path))
        let pruned = await store.pruneConversation(parentA)
        XCTAssertTrue(pruned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirA.path))
        let gone = await store.loadMetadata(parentConversationID: parentA, agentId: agentA)
        XCTAssertNil(gone)

        let metaB = await store.loadMetadata(parentConversationID: parentB, agentId: agentB)
        XCTAssertEqual(metaB?.usage.inputTokens, 9)
        XCTAssertEqual(metaB?.status, "completed")
        let prunedAgain = await store.pruneConversation(parentA)
        XCTAssertFalse(prunedAgain, "second prune of missing dir")
    }

    // MARK: - TaskTool meta

    func testTaskToolMetaIncludesUsageAndToolCount() async throws {
        let backend = ScriptedUsageBackend(turns: [
            [
                .toolCallDelta(
                    index: 0, id: "t1", name: "list_directory",
                    argumentsAppend: #"{"path":"."}"#),
                .usage(promptTokens: 8, completionTokens: 1),
                .done(finishReason: "tool_calls"),
            ],
            [
                .contentDelta("task-report"),
                .usage(promptTokens: 4, completionTokens: 6),
                .done(finishReason: "stop"),
            ],
        ])
        let parent = UUID()
        let result = try await TaskTool().execute(
            arguments: ToolArguments(dictionary: [
                "prompt": "explore quickly",
                "description": "usage meta",
                "subagent_type": "explore",
            ]),
            context: ToolContext(
                projectRoot: FileManager.default.temporaryDirectory,
                conversationID: parent,
                inferenceBackend: backend,
                model: model,
                executionMode: .yolo
            )
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("prompt_tokens: 12"), result.content)
        XCTAssertTrue(result.content.contains("completion_tokens: 7"), result.content)
        XCTAssertTrue(result.content.contains("total_tokens: 19"), result.content)
        XCTAssertTrue(result.content.contains("cache_read_tokens: 0"), result.content)
        XCTAssertTrue(result.content.contains("cache_write_tokens: 0"), result.content)
        XCTAssertTrue(result.content.contains("tool_count: 1"), result.content)
        XCTAssertTrue(result.content.contains("duration_ms:"), result.content)
        XCTAssertTrue(result.content.contains("task-report"), result.content)

        let line = result.content.split(separator: "\n").first { $0.contains("agent_id:") }
        let agentId = line!.split(separator: ":", maxSplits: 1).last!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = await SubagentSessionStore.shared.loadMetadata(
            parentConversationID: parent, agentId: agentId)
        XCTAssertEqual(meta?.usage.inputTokens, 12)
        XCTAssertEqual(meta?.totalToolUseCount, 1)
        XCTAssertEqual(meta?.status, "completed")
    }
}
