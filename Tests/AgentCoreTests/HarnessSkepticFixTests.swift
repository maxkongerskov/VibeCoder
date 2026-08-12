//
//  HarnessSkepticFixTests.swift
//
//  Closes verifier gaps: remembered-allow, replace_all, live subagent
//  kill cancel, explore write denial via SubAgentRunner.
//

import XCTest
@testable import AgentCore

// MARK: - Scripted backends

/// Emits tool_call then optional slow content for cancel tests.
private final class ScriptedBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let lock = NSLock()
    private var turnIndex = 0
    private let turns: [[ChatChunk]]
    private let interChunkDelayNs: UInt64

    init(turns: [[ChatChunk]], interChunkDelayNs: UInt64 = 0) {
        self.turns = turns
        self.interChunkDelayNs = interChunkDelayNs
    }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "test", displayName: "Test", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        let chunks = turns.isEmpty ? [] : turns[min(turnIndex, turns.count - 1)]
        turnIndex += 1
        let delay = interChunkDelayNs
        lock.unlock()
        return AsyncThrowingStream { continuation in
            Task {
                for c in chunks {
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.yield(c)
                }
                continuation.finish()
            }
        }
    }

    func cancel(streamID: UUID) async {}
}

final class HarnessSkepticFixTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await RememberedGrants.shared.clear()
        await BackgroundJobManager.shared.cleanup()
    }

    override func tearDown() async throws {
        await BackgroundJobManager.shared.cleanup()
        await RememberedGrants.shared.clear()
    }

    // MARK: - Remembered allow actually allows (Ask without reviewer)

    func testRememberedAllowSkipsAskModeGate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rem-allow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = GrantKey(projectKey: root.path, toolName: "write_file")
        await RememberedGrants.shared.remember(.allow, for: key)

        // Ask mode, no patch reviewer — would deny without remembered allow.
        let context = ToolContext(
            projectRoot: root,
            conversationID: UUID(),
            executionMode: .build)
        let file = root.appendingPathComponent("ok.txt")
        let result = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": file.path,
                "content": "granted",
            ]),
            context: context)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "granted")
    }

    func testMutationReviewDoesNotAutoRememberAllowOrNever() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mut-rem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Same conversation for RBE: overwrite path requires a prior read
        // in-session before MutationReview runs.
        let convoID = UUID()
        // Accept once — must NOT permanently allow.
        let acceptReviewer = PatchReviewer { _ in .acceptAll }
        let acceptCtx = ToolContext(
            projectRoot: root,
            patchReviewer: acceptReviewer,
            conversationID: convoID,
            executionMode: .build)
        let file = root.appendingPathComponent("a.txt")
        _ = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": file.path,
                "content": "v1",
            ]),
            context: acceptCtx)
        let key = GrantKey(projectKey: root.path, toolName: "write_file")
        let afterAccept = await RememberedGrants.shared.decision(for: key)
        XCTAssertNil(afterAccept, "one-shot accept must not record remembered allow")

        // Seed session read so overwrite is not blocked by RBE before review.
        await SessionReadTracker.shared.recordRead(
            path: file.path, conversationID: convoID)

        // Reject once — must NOT permanently never.
        let rejectReviewer = PatchReviewer { _ in .rejectAll }
        let rejectCtx = ToolContext(
            projectRoot: root,
            patchReviewer: rejectReviewer,
            conversationID: convoID,
            executionMode: .build)
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "write_file",
                arguments: ToolArguments(dictionary: [
                    "path": file.path,
                    "content": "nope",
                ]),
                context: rejectCtx)
            XCTFail("reject should throw")
        } catch {
            // expected — MutationReview maps rejectAll → ToolError.permissionDenied
        }
        let afterReject = await RememberedGrants.shared.decision(for: key)
        XCTAssertNil(afterReject, "one-shot reject must not record remembered never")

        // Explicit remember only via RememberedGrants API (Always allow UI).
        await RememberedGrants.shared.remember(.allow, for: key)
        let explicit = await RememberedGrants.shared.decision(for: key)
        XCTAssertEqual(explicit, .allow)
    }

    func testConversationScopedCleanupDoesNotKillOtherChats() async throws {
        let convoA = UUID()
        let convoB = UUID()
        let idA = try await BackgroundJobManager.shared.startShell(
            command: "sleep 30",
            workingDirectory: nil,
            timeout: 60,
            conversationID: convoA)
        let idB = try await BackgroundJobManager.shared.startShell(
            command: "sleep 30",
            workingDirectory: nil,
            timeout: 60,
            conversationID: convoB)
        try await Task.sleep(nanoseconds: 50_000_000)

        await BackgroundJobManager.shared.cleanup(conversationID: convoA)

        let aSnap = await BackgroundJobManager.shared.snapshot(idA)
        XCTAssertNil(aSnap, "convo A job must be removed")
        let b = await BackgroundJobManager.shared.snapshot(idB)
        XCTAssertNotNil(b, "convo B job must survive")
        XCTAssertEqual(b?.status, .running)
        XCTAssertEqual(b?.conversationID, convoB)

        _ = await BackgroundJobManager.shared.kill(idB)
    }

    // MARK: - replace_all

    func testEditFileReplaceAll() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repl-all-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("x.swift")
        try "foo\nbar\nfoo\n".write(to: file, atomically: true, encoding: .utf8)
        let path = SafeModeConfig.normalizePath(file.path)
        let context = ToolContext(
            projectRoot: root,
            conversationID: UUID(),
            executionMode: .yolo,
            sessionReadPaths: [path])

        let edits = """
        <<<<<<< SEARCH
        foo
        =======
        baz
        >>>>>>> REPLACE
        """
        let result = try await ToolRegistry.shared.execute(
            name: "edit_file",
            arguments: ToolArguments(dictionary: [
                "path": file.path,
                "edits": edits,
                "replace_all": true,
            ]),
            context: context)
        XCTAssertFalse(result.isError, result.content)
        let body = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(body.contains("foo"))
        XCTAssertEqual(body.components(separatedBy: "baz").count - 1, 2)
    }

    // MARK: - Explore subagent cannot write (via SubAgentRunner allowlist)

    func testExploreSubagentRefusesWriteFile() async throws {
        let backend = ScriptedBackend(turns: [[
            .toolCallDelta(index: 0, id: "t1", name: "write_file",
                           argumentsAppend: "{\"path\":\"pwn.txt\",\"content\":\"nope\"}"),
            .done(finishReason: "tool_calls"),
        ], [
            .contentDelta("I could not write."),
            .done(finishReason: "stop"),
        ]])
        let model = ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio)
        let allowed = SubagentType.explore.allowedTools(capability: .readOnly)
        XCTAssertFalse(allowed.contains("write_file"))

        let result = await SubAgentRunner.run(
            prompt: "write a file",
            systemPromptOverride: SubagentType.explore.systemPrompt,
            allowedTools: allowed,
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            maxIterations: 4
        )
        // Tool refusal must appear in transcript
        let toolMsgs = result.transcript.messages.filter { $0.role == ChatMessage.Role.tool }
        XCTAssertTrue(
            toolMsgs.contains(where: {
                $0.content.contains("not available") || $0.content.contains("write_file")
            }),
            "expected write refusal in \(toolMsgs.map { $0.content })"
        )
    }

    // MARK: - Kill cancels a live SubAgentRunner

    func testKillCancelsLiveSubagent() async throws {
        // Many slow chunks so kill has time to land mid-stream.
        var slowChunks: [ChatChunk] = []
        for i in 0..<40 {
            slowChunks.append(.contentDelta("tick\(i) "))
        }
        slowChunks.append(.done(finishReason: "stop"))

        let backend = ScriptedBackend(turns: [slowChunks], interChunkDelayNs: 40_000_000)
        let model = ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio)
        let jobID = try await BackgroundJobManager.shared.registerSubagent(
            description: "explore: kill-test")

        let runTask = Task {
            await SubAgentRunner.run(
                prompt: "count slowly",
                systemPromptOverride: SubagentType.explore.systemPrompt,
                allowedTools: SubagentType.explore.allowedTools(capability: .readOnly),
                backend: backend,
                model: model,
                registry: ToolRegistry.shared,
                maxIterations: 8,
                jobID: jobID
            )
        }

        // Let a few ticks stream, then kill.
        try? await Task.sleep(nanoseconds: 120_000_000)
        let killed = await BackgroundJobManager.shared.kill(jobID)
        XCTAssertTrue(killed)

        let result = await runTask.value
        XCTAssertTrue(
            result.finalText.lowercased().contains("cancel"),
            "expected cancelled finalText, got: \(result.finalText)"
        )
        let snap = await BackgroundJobManager.shared.snapshot(jobID)
        XCTAssertEqual(snap?.status, .killed)
    }

    // MARK: - TaskTool wires jobID (depth + missing backend still real path)

    func testTaskToolRegistersAndReturnsSummaryMeta() async throws {
        // One-shot finish backend so TaskTool completes quickly.
        let backend = ScriptedBackend(turns: [[
            .contentDelta("explored: nothing found"),
            .done(finishReason: "stop"),
        ]])
        let model = ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio)
        let context = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            inferenceBackend: backend,
            model: model,
            subagentDepth: 0,
            executionMode: .yolo)

        let result = try! await ToolRegistry.shared.execute(
            name: "task",
            arguments: ToolArguments(dictionary: [
                "prompt": "Scan for TODOs",
                "description": "explore todos",
                "subagent_type": "explore",
            ]),
            context: context)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("explored") || result.content.contains("nothing"),
                      result.content)
        XCTAssertTrue(result.content.contains("task_id:"), result.content)
        XCTAssertTrue(result.content.contains("summary_only: true"), result.content)
        XCTAssertTrue(result.content.contains("type: explore"), result.content)
    }
}
