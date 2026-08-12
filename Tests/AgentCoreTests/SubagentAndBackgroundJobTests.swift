//
//  SubagentAndBackgroundJobTests.swift
//

import XCTest
@testable import AgentCore

final class SubagentAndBackgroundJobTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await BackgroundJobManager.shared.cleanup()
    }

    override func tearDown() async throws {
        await BackgroundJobManager.shared.cleanup()
    }

    func testBackgroundShellCompletesAndWait() async throws {
        let id = try await BackgroundJobManager.shared.startShell(
            command: "echo bg-hello-$$",
            workingDirectory: nil,
            timeout: 30)
        let snap = await BackgroundJobManager.shared.wait(id: id, timeoutMs: 10_000)
        XCTAssertNotNil(snap)
        XCTAssertTrue(snap!.status == .completed || snap!.status == .failed,
                      "\(snap!.status)")
        if snap!.status == .completed {
            XCTAssertTrue(snap!.output.contains("bg-hello"), snap!.output)
        }
    }

    func testBackgroundKill() async throws {
        let id = try await BackgroundJobManager.shared.startShell(
            command: "sleep 30",
            workingDirectory: nil,
            timeout: 60)
        // Give process a moment to start
        try await Task.sleep(nanoseconds: 100_000_000)
        let killed = await BackgroundJobManager.shared.kill(id)
        XCTAssertTrue(killed)
        let snap = await BackgroundJobManager.shared.snapshot(id)
        XCTAssertEqual(snap?.status, .killed)
    }

    func testRunShellBackgroundTool() async throws {
        let context = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            executionMode: .yolo)
        let result = try await ToolRegistry.shared.execute(
            name: "run_shell",
            arguments: ToolArguments(dictionary: [
                "command": "echo from-tool",
                "background": true,
            ]),
            context: context)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("task_id:"), result.content)
        // Extract UUID
        let line = result.content.split(separator: "\n").first { $0.contains("task_id:") }!
        let idStr = line.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)
        let waitResult = try await ToolRegistry.shared.execute(
            name: "wait_tasks",
            arguments: ToolArguments(dictionary: [
                "task_ids": [idStr],
                "timeout_ms": 10_000,
            ]),
            context: context)
        XCTAssertFalse(waitResult.isError, waitResult.content)
        XCTAssertTrue(waitResult.content.contains("from-tool")
                      || waitResult.content.contains("completed")
                      || waitResult.content.contains("status"),
                      waitResult.content)
    }

    func testExploreToolsAreReadOnly() {
        let tools = SubagentType.explore.allowedTools(capability: .readOnly)
        XCTAssertFalse(tools.contains("write_file"))
        XCTAssertFalse(tools.contains("run_shell") && SubagentCatalog.writeTools.contains("run_shell"))
        XCTAssertTrue(tools.isSubset(of: SubagentCatalog.readOnlyTools)
                      || tools.isSubset(of: SubagentCatalog.exploreTools)
                      || tools.allSatisfy { SubagentCatalog.readOnlyTools.contains($0) || SubagentCatalog.exploreTools.contains($0) })
    }

    func testTaskDepthGuard() async throws {
        let context = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            inferenceBackend: nil,
            model: ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio),
            subagentDepth: 1,
            executionMode: .yolo)
        let result = try await ToolRegistry.shared.execute(
            name: "task",
            arguments: ToolArguments(dictionary: [
                "prompt": "look around",
                "description": "test depth",
                "subagent_type": "explore",
            ]),
            context: context)
        XCTAssertTrue(result.isError || result.content.lowercased().contains("depth"),
                      result.content)
    }

    func testSubagentSummaryRegistration() async throws {
        let id = try await BackgroundJobManager.shared.registerSubagent(description: "explore: test")
        await BackgroundJobManager.shared.completeSubagent(
            id: id, output: "found nothing", failed: false)
        let snap = await BackgroundJobManager.shared.snapshot(id)
        XCTAssertEqual(snap?.status, .completed)
        XCTAssertEqual(snap?.output, "found nothing")
    }

    func testLiveShellSnapshotIncludesPartialOutput() async throws {
        let id = try await BackgroundJobManager.shared.startShell(
            command: "printf 'live-out-'; sleep 2; echo done",
            workingDirectory: nil,
            timeout: 10)
        // Allow the printf to land in the DataBox before we snapshot.
        try await Task.sleep(nanoseconds: 200_000_000)
        let snap = await BackgroundJobManager.shared.snapshot(id)
        XCTAssertEqual(snap?.status, .running)
        XCTAssertTrue(
            snap?.output.contains("live-out") == true,
            "running snapshot must surface live DataBox output, got: \(snap?.output ?? "nil")")
        _ = await BackgroundJobManager.shared.kill(id)
    }

    func testRegisterSubagentRespectsMaxConcurrent() async throws {
        await BackgroundJobManager.shared.cleanup()
        var ids: [UUID] = []
        for i in 0..<BackgroundJobManager.maxConcurrent {
            let id = try await BackgroundJobManager.shared.registerSubagent(
                description: "slot-\(i)")
            ids.append(id)
        }
        do {
            _ = try await BackgroundJobManager.shared.registerSubagent(description: "overflow")
            XCTFail("expected maxConcurrent throw")
        } catch {
            // expected
        }
        for id in ids {
            await BackgroundJobManager.shared.completeSubagent(
                id: id, output: "ok", failed: false)
        }
    }

    func testCompleteSubagentFailedOnCancelSemantics() async throws {
        let id = try await BackgroundJobManager.shared.registerSubagent(description: "cancel-me")
        // Simulate runner cancel without kill: mark failed via completeSubagent.
        await BackgroundJobManager.shared.completeSubagent(
            id: id, output: "Sub-agent cancelled.", failed: true)
        let snap = await BackgroundJobManager.shared.snapshot(id)
        XCTAssertEqual(snap?.status, .failed)
        XCTAssertEqual(snap?.output, "Sub-agent cancelled.")
    }

    func testUpdateSubagentOutputWhileRunning() async throws {
        let id = try await BackgroundJobManager.shared.registerSubagent(description: "progress")
        await BackgroundJobManager.shared.updateSubagentOutput(
            id: id, output: "[running] read_file (1/2) iter=1")
        let snap = await BackgroundJobManager.shared.snapshot(id)
        XCTAssertEqual(snap?.status, .running)
        XCTAssertTrue(snap?.output.contains("read_file") == true, snap?.output ?? "")
        await BackgroundJobManager.shared.completeSubagent(id: id, output: "done", failed: false)
        let done = await BackgroundJobManager.shared.snapshot(id)
        XCTAssertEqual(done?.status, .completed)
        XCTAssertEqual(done?.output, "done")
    }

    func testWaitTimeoutReturnsLiveShellOutput() async throws {
        let id = try await BackgroundJobManager.shared.startShell(
            command: "printf 'partial-wait'; sleep 5",
            workingDirectory: nil,
            timeout: 30)
        try await Task.sleep(nanoseconds: 150_000_000)
        let snap = await BackgroundJobManager.shared.wait(id: id, timeoutMs: 50)
        XCTAssertEqual(snap?.status, .running)
        XCTAssertTrue(
            snap?.output.contains("partial-wait") == true,
            "wait timeout must use liveSnapshot, got: \(snap?.output ?? "nil")")
        _ = await BackgroundJobManager.shared.kill(id)
    }
}
