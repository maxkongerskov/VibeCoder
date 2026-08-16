//
//  MonitorJobsAndWakeInjectTests.swift
//
//  Depth D4: list_background_jobs / monitor_jobs + next-turn wake inject.
//

import XCTest
@testable import AgentCore

final class MonitorJobsAndWakeInjectTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await BackgroundJobManager.shared.cleanup()
        await PendingWakeInject.shared.clearAll()
    }

    override func tearDown() async throws {
        await BackgroundJobManager.shared.cleanup()
        await PendingWakeInject.shared.clearAll()
    }

    // MARK: - JobMonitor / tools

    func testJobMonitorFormatEmpty() {
        let text = JobMonitor.formatList([])
        XCTAssertTrue(text.lowercased().contains("none"), text)
        XCTAssertTrue(text.lowercased().contains("not") || text.contains("Grok"), text)
    }

    func testListBackgroundJobsToolRegistered() async {
        let names = await ToolRegistry.shared.registeredNames()
        XCTAssertTrue(names.contains("list_background_jobs"))
        XCTAssertTrue(names.contains("monitor_jobs"))
    }

    func testListBackgroundJobsToolEmpty() async throws {
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            executionMode: .yolo)
        let result = try await ToolRegistry.shared.execute(
            name: "list_background_jobs",
            arguments: ToolArguments(dictionary: [:]),
            context: ctx)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.lowercased().contains("none")
                      || result.content.lowercased().contains("job"),
                      result.content)
    }

    func testListBackgroundJobsShowsRunningSubagent() async throws {
        let convo = UUID()
        let id = try await BackgroundJobManager.shared.registerSubagent(
            description: "explore: find-foo",
            conversationID: convo)
        await BackgroundJobManager.shared.updateSubagentOutput(
            id: id, output: "still working")
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: convo,
            executionMode: .yolo)
        let result = try await ToolRegistry.shared.execute(
            name: "monitor_jobs",
            arguments: ToolArguments(dictionary: [
                "running_only": true,
                "conversation_scoped": true,
            ]),
            context: ctx)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.lowercased().contains("subagent")
                      || result.content.contains("explore"),
                      result.content)
        XCTAssertTrue(result.content.contains(String(id.uuidString.prefix(8)).lowercased())
                      || result.content.contains("id"),
                      result.content)
        await BackgroundJobManager.shared.completeSubagent(
            id: id, output: "done", failed: false)
    }

    // MARK: - Wake inject

    func testCompleteSubagentQueuesPendingWakeInject() async throws {
        let convo = UUID()
        let id = try await BackgroundJobManager.shared.registerSubagent(
            description: "explore: wake",
            conversationID: convo)
        await BackgroundJobManager.shared.completeSubagent(
            id: id, output: "found bar.swift", failed: false)
        // publishCompletion schedules Task { enqueue } — wait briefly
        try await Task.sleep(nanoseconds: 50_000_000)
        let count = await PendingWakeInject.shared.peekCount(conversationID: convo)
        XCTAssertGreaterThanOrEqual(count, 1, "wake should be queued for conversation")
        let drained = await PendingWakeInject.shared.drain(conversationID: convo)
        XCTAssertFalse(drained.isEmpty)
        XCTAssertTrue(drained[0].contains(id.uuidString)
                      || drained[0].contains("Background job"),
                      drained[0])
        XCTAssertTrue(drained[0].contains("found bar") || drained[0].contains("completed"),
                      drained[0])
    }

    func testApplyWakeInjectsAddsTranscriptAndNudge() async throws {
        let convoID = UUID()
        await PendingWakeInject.shared.enqueue(
            conversationID: convoID,
            message: "[Background job completed] kind=subagent task_id=TEST-ID\noutput: hello-wake")
        var convo = Conversation(id: convoID, title: "t")
        var nudges: [String] = []
        var sawUser = false
        let n = await AgentLoop.applyWakeInjects(
            conversationId: convoID,
            convo: &convo,
            pendingNudges: &nudges,
            events: { event in
                if case .userMessage = event { sawUser = true }
            }
        )
        XCTAssertEqual(n, 1)
        XCTAssertTrue(sawUser)
        XCTAssertEqual(convo.messages.filter { $0.role == .user }.count, 1)
        let wake = try XCTUnwrap(convo.messages.first { $0.role == .user })
        XCTAssertTrue(wake.content.contains("hello-wake"))
        XCTAssertTrue(wake.isWireOnlySystemReminder)
        XCTAssertFalse(wake.appearsInTranscript)
        XCTAssertFalse(nudges.isEmpty)
        let remaining = await PendingWakeInject.shared.peekCount(conversationID: convoID)
        XCTAssertEqual(remaining, 0)
    }

    func testWakeSurvivesInterjectionBufferClear() async throws {
        let convo = UUID()
        let id = try await BackgroundJobManager.shared.registerSubagent(
            description: "shell-like",
            conversationID: convo)
        await BackgroundJobManager.shared.completeSubagent(
            id: id, output: "survive-clear", failed: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        // Hard-stop clear must NOT drop PendingWakeInject
        await InterjectionBuffer.shared.clear(conversationId: convo)
        let count = await PendingWakeInject.shared.peekCount(conversationID: convo)
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testFormatWakeMessageIncludesTaskId() {
        let id = UUID()
        let notice = BackgroundJobCompletion(
            taskId: id,
            kind: .subagent,
            status: .completed,
            command: "explore: x",
            outputPreview: "ok",
            conversationID: nil)
        let msg = PendingWakeInject.formatWakeMessage(notice)
        XCTAssertTrue(msg.contains(id.uuidString))
        XCTAssertTrue(msg.contains("subagent") || msg.contains("Background"))
    }
}
