//
//  BackgroundJobCompletionWakeTests.swift
//
//  Phase C PC4: background job completion auto-wake notices.
//

import XCTest
@testable import AgentCore

final class BackgroundJobCompletionWakeTests: XCTestCase {

    override func setUp() async throws {
        await BackgroundJobManager.shared.cleanup()
    }

    override func tearDown() async throws {
        await BackgroundJobManager.shared.cleanup()
    }

    func testCompleteSubagentPublishesPendingCompletion() async throws {
        let convo = UUID()
        let id = try await BackgroundJobManager.shared.registerSubagent(
            description: "explore: wake-test",
            conversationID: convo)
        await BackgroundJobManager.shared.completeSubagent(
            id: id, output: "found the bug in Foo.swift", failed: false)

        let pending = await BackgroundJobManager.shared.takePendingCompletions(
            conversationID: convo)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].taskId, id)
        XCTAssertEqual(pending[0].kind, .subagent)
        XCTAssertEqual(pending[0].status, .completed)
        XCTAssertTrue(pending[0].wakeMessage.lowercased().contains("completed"),
                      pending[0].wakeMessage)
        XCTAssertTrue(pending[0].outputPreview.contains("Foo.swift"),
                      pending[0].outputPreview)

        // Drained once
        let again = await BackgroundJobManager.shared.takePendingCompletions(
            conversationID: convo)
        XCTAssertTrue(again.isEmpty)
    }

    func testFailedSubagentWake() async throws {
        let id = try await BackgroundJobManager.shared.registerSubagent(
            description: "plan: fail")
        await BackgroundJobManager.shared.completeSubagent(
            id: id, output: "Sub-agent failed: boom", failed: true)
        let pending = await BackgroundJobManager.shared.takePendingCompletions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].status, .failed)
        XCTAssertTrue(pending[0].wakeMessage.lowercased().contains("fail"),
                      pending[0].wakeMessage)
    }

    func testKillPublishesKilledWake() async throws {
        let id = try await BackgroundJobManager.shared.startSubagent(
            description: "explore: kill-wake"
        ) { jobID in
            for _ in 0..<100 {
                if await BackgroundJobManager.shared.isCancelled(jobID) { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let killed = await BackgroundJobManager.shared.kill(id)
        XCTAssertTrue(killed)
        let pending = await BackgroundJobManager.shared.takePendingCompletions()
        XCTAssertTrue(pending.contains { $0.taskId == id && $0.status == .killed },
                      "\(pending)")
    }

    func testSubscribeCompletionsReceivesPush() async throws {
        let stream = await BackgroundJobManager.shared.subscribeCompletions()
        let id = try await BackgroundJobManager.shared.registerSubagent(
            description: "explore: stream")

        let expectation = expectation(description: "stream yield")
        let task = Task {
            for await notice in stream {
                if notice.taskId == id {
                    expectation.fulfill()
                    break
                }
            }
        }
        await BackgroundJobManager.shared.completeSubagent(
            id: id, output: "stream-ok", failed: false)
        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()
    }

    func testAgentEventMappingFromCompletion() async throws {
        let id = try await BackgroundJobManager.shared.registerSubagent(
            description: "explore: event")
        await BackgroundJobManager.shared.completeSubagent(
            id: id, output: "event-ok", failed: false)
        let pending = await BackgroundJobManager.shared.takePendingCompletions()
        XCTAssertEqual(pending.count, 1)
        let event = pending[0].agentEvent
        guard case .backgroundJobCompleted(let taskId, let kind, let status, let summary, _) = event else {
            return XCTFail("expected backgroundJobCompleted, got \(event)")
        }
        XCTAssertEqual(taskId, id)
        XCTAssertEqual(kind, "subagent")
        XCTAssertEqual(status, "completed")
        XCTAssertFalse(summary.isEmpty)
    }

    func testConversationScopedDrain() async throws {
        let a = UUID()
        let b = UUID()
        let idA = try await BackgroundJobManager.shared.registerSubagent(
            description: "a", conversationID: a)
        let idB = try await BackgroundJobManager.shared.registerSubagent(
            description: "b", conversationID: b)
        await BackgroundJobManager.shared.completeSubagent(
            id: idA, output: "A", failed: false)
        await BackgroundJobManager.shared.completeSubagent(
            id: idB, output: "B", failed: false)

        let onlyA = await BackgroundJobManager.shared.takePendingCompletions(conversationID: a)
        XCTAssertEqual(onlyA.map(\.taskId), [idA])
        let onlyB = await BackgroundJobManager.shared.takePendingCompletions(conversationID: b)
        XCTAssertEqual(onlyB.map(\.taskId), [idB])
    }

    func testShellFinalizeAlsoWakes() async throws {
        let id = try await BackgroundJobManager.shared.startShell(
            command: "echo wake-shell",
            workingDirectory: nil,
            timeout: 10)
        let snap = await BackgroundJobManager.shared.wait(id: id, timeoutMs: 5_000)
        XCTAssertEqual(snap?.status, .completed)
        // Allow publish from finalizeShell
        try await Task.sleep(nanoseconds: 50_000_000)
        let pending = await BackgroundJobManager.shared.takePendingCompletions()
        XCTAssertTrue(pending.contains { $0.taskId == id && $0.kind == .shell },
                      "shell complete should publish wake, got \(pending)")
    }

    func testWakeMessageIncludesTaskId() {
        let id = UUID()
        let c = BackgroundJobCompletion(
            taskId: id,
            kind: .subagent,
            status: .completed,
            command: "explore: x",
            outputPreview: "hello",
            conversationID: nil)
        XCTAssertTrue(c.wakeMessage.contains(id.uuidString))
        XCTAssertTrue(c.wakeMessage.contains("explore"))
    }
}
