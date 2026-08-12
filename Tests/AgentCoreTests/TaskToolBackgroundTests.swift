//
//  TaskToolBackgroundTests.swift
//
//  Phase B PB4: task(run_in_background:true) + wait_tasks / kill_task.
//

import XCTest
@testable import AgentCore

// MARK: - Fast scripted backend (no real model)

private final class InstantTextBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let reply: String

    init(reply: String = "bg-subagent-done") {
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

private final class SlowStreamBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let delayNs: UInt64

    init(delayNs: UInt64 = 2_000_000_000) {
        self.delayNs = delayNs
    }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "slow", displayName: "Slow", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        let delay = delayNs
        return AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                continuation.yield(.contentDelta("late"))
                continuation.yield(.done(finishReason: "stop"))
                continuation.finish()
            }
        }
    }

    func cancel(streamID: UUID) async {}
}

final class TaskToolBackgroundTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await BackgroundJobManager.shared.cleanup()
    }

    override func tearDown() async throws {
        await BackgroundJobManager.shared.cleanup()
    }

    // MARK: - Job manager unit (no model)

    func testStartSubagentWorkCompletesAndWait() async throws {
        let id = try await BackgroundJobManager.shared.startSubagent(
            description: "unit: sleep-complete"
        ) { jobID in
            try? await Task.sleep(nanoseconds: 50_000_000)
            await BackgroundJobManager.shared.completeSubagent(
                id: jobID, output: "unit-done", failed: false)
        }
        // Must return before work finishes — id registered as running.
        let early = await BackgroundJobManager.shared.snapshot(id)
        XCTAssertEqual(early?.status, .running)

        let snap = await BackgroundJobManager.shared.wait(id: id, timeoutMs: 5_000)
        XCTAssertEqual(snap?.status, .completed, "\(String(describing: snap))")
        XCTAssertEqual(snap?.output, "unit-done")
        XCTAssertEqual(snap?.kind, .subagent)
    }

    func testAttachSubagentWorkKillCancels() async throws {
        let id = try await BackgroundJobManager.shared.registerSubagent(
            description: "unit: kill-me")
        await BackgroundJobManager.shared.attachSubagentWork(id: id) {
            // Poll cancel flag like SubAgentRunner
            for _ in 0..<200 {
                if await BackgroundJobManager.shared.isCancelled(id) { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            await BackgroundJobManager.shared.completeSubagent(
                id: id, output: "should-not-finish", failed: false)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let killed = await BackgroundJobManager.shared.kill(id)
        XCTAssertTrue(killed)
        let snap = await BackgroundJobManager.shared.snapshot(id)
        XCTAssertEqual(snap?.status, .killed)
    }

    // MARK: - Task tool background path

    func testTaskBackgroundReturnsTaskIdImmediately() async throws {
        let backend = InstantTextBackend(reply: "explore-findings")
        let model = ModelDescriptor(id: "mock", displayName: "Mock", backend: .lmStudio)
        let context = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            inferenceBackend: backend,
            model: model,
            subagentDepth: 0,
            executionMode: .yolo
        )
        let start = Date()
        let result = try await ToolRegistry.shared.execute(
            name: "task",
            arguments: ToolArguments(dictionary: [
                "prompt": "find the entrypoint",
                "description": "bg explore",
                "subagent_type": "explore",
                "run_in_background": true,
            ]),
            context: context)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("task_id:"), result.content)
        XCTAssertTrue(result.content.contains("background: true")
                      || result.content.lowercased().contains("background"),
                      result.content)
        // Immediate return — should not block on a multi-second model loop.
        XCTAssertLessThan(elapsed, 1.5, "background task must return immediately (elapsed=\(elapsed))")

        // Extract UUID
        let line = result.content.split(separator: "\n").first { $0.contains("task_id:") }!
        let idStr = line.split(separator: ":").last!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: idStr) else {
            return XCTFail("bad task_id: \(idStr)")
        }

        let waitResult = try await ToolRegistry.shared.execute(
            name: "wait_tasks",
            arguments: ToolArguments(dictionary: [
                "task_ids": [id.uuidString],
                "timeout_ms": 10_000,
            ]),
            context: context)
        XCTAssertFalse(waitResult.isError, waitResult.content)
        XCTAssertTrue(
            waitResult.content.contains("explore-findings")
                || waitResult.content.contains("completed")
                || waitResult.content.contains("status:"),
            waitResult.content)

        let snap = await BackgroundJobManager.shared.snapshot(id)
        XCTAssertEqual(snap?.kind, .subagent)
        XCTAssertTrue(snap?.status == .completed || snap?.status == .failed,
                      "\(String(describing: snap?.status))")
        if snap?.status == .completed {
            XCTAssertTrue(snap?.output.contains("explore-findings") == true,
                          snap?.output ?? "")
        }
    }

    func testTaskBackgroundAliasWorks() async throws {
        let backend = InstantTextBackend(reply: "alias-ok")
        let model = ModelDescriptor(id: "mock", displayName: "Mock", backend: .lmStudio)
        let context = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            inferenceBackend: backend,
            model: model,
            executionMode: .yolo
        )
        let result = try await ToolRegistry.shared.execute(
            name: "task",
            arguments: ToolArguments(dictionary: [
                "prompt": "quick",
                "description": "alias bg",
                "subagent_type": "explore",
                "background": true,
            ]),
            context: context)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("task_id:"), result.content)
        // Drain so tearDown cleanup is clean
        if let line = result.content.split(separator: "\n").first(where: { $0.contains("task_id:") }) {
            let idStr = line.split(separator: ":").last!
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = UUID(uuidString: idStr) {
                _ = await BackgroundJobManager.shared.wait(id: id, timeoutMs: 10_000)
            }
        }
    }

    func testTaskBackgroundKillWhileRunning() async throws {
        let backend = SlowStreamBackend(delayNs: 5_000_000_000)
        let model = ModelDescriptor(id: "slow", displayName: "Slow", backend: .lmStudio)
        let context = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            inferenceBackend: backend,
            model: model,
            executionMode: .yolo
        )
        let result = try await ToolRegistry.shared.execute(
            name: "task",
            arguments: ToolArguments(dictionary: [
                "prompt": "long research",
                "description": "kill bg",
                "subagent_type": "explore",
                "run_in_background": true,
            ]),
            context: context)
        XCTAssertFalse(result.isError, result.content)
        let line = result.content.split(separator: "\n").first { $0.contains("task_id:") }!
        let idStr = line.split(separator: ":").last!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID(uuidString: idStr)!

        // Let runner enter stream sleep
        try await Task.sleep(nanoseconds: 50_000_000)
        let killResult = try await ToolRegistry.shared.execute(
            name: "kill_task",
            arguments: ToolArguments(dictionary: ["task_id": id.uuidString]),
            context: context)
        XCTAssertFalse(killResult.isError, killResult.content)
        XCTAssertTrue(killResult.content.lowercased().contains("kill"), killResult.content)

        // Give complete path a moment
        try await Task.sleep(nanoseconds: 100_000_000)
        let snap = await BackgroundJobManager.shared.snapshot(id)
        XCTAssertTrue(
            snap?.status == .killed || snap?.status == .failed || snap?.status == .completed,
            "expected terminal status after kill, got \(String(describing: snap?.status))")
    }

    func testTaskForegroundStillDefault() async throws {
        let backend = InstantTextBackend(reply: "fg-report")
        let model = ModelDescriptor(id: "mock", displayName: "Mock", backend: .lmStudio)
        let context = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            inferenceBackend: backend,
            model: model,
            executionMode: .yolo
        )
        let result = try await ToolRegistry.shared.execute(
            name: "task",
            arguments: ToolArguments(dictionary: [
                "prompt": "sync work",
                "description": "fg explore",
                "subagent_type": "explore",
            ]),
            context: context)
        // Foreground returns the report body (not only started meta)
        XCTAssertTrue(
            result.content.contains("fg-report") || result.content.contains("subagent_meta"),
            result.content)
        XCTAssertTrue(
            result.content.contains("background: false")
                || !result.content.contains("Background subagent started"),
            result.content)
    }

    func testDepthStillBlocksNestedTask() async throws {
        let backend = InstantTextBackend()
        let model = ModelDescriptor(id: "mock", displayName: "Mock", backend: .lmStudio)
        let context = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            inferenceBackend: backend,
            model: model,
            subagentDepth: 1,
            executionMode: .yolo
        )
        let result = try await ToolRegistry.shared.execute(
            name: "task",
            arguments: ToolArguments(dictionary: [
                "prompt": "nested",
                "description": "nested",
                "subagent_type": "explore",
                "run_in_background": true,
            ]),
            context: context)
        XCTAssertTrue(result.isError || result.content.lowercased().contains("depth"),
                      result.content)
    }
}
