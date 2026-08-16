//
//  InspectorSubagentsUITests.swift
//
//  Wave U4 — Subagents inspector tab: directory merge, status map,
//  notification parse, open-in-side-pane keys.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class InspectorSubagentsUITests: XCTestCase {

    // MARK: - Tab

    func testTabEnumIncludesSubagents() {
        XCTAssertTrue(InspectorPanelTab.allCases.contains(.subagents))
        XCTAssertEqual(InspectorPanelTab.subagents.title, "Subagents")
        XCTAssertEqual(InspectorPanelTab.subagents.rawValue, "subagents")
        XCTAssertEqual(InspectorPanelTab.files.title, "Files")
        XCTAssertEqual(InspectorPanelTab.changes.title, "Changes")
        XCTAssertEqual(Set(InspectorPanelTab.allCases.map(\.rawValue)), ["files", "changes", "subagents"])
    }

    // MARK: - Empty

    func testEmptyConversationYieldsEmptyDirectory() {
        let dir = InspectorSubagentDirectory.build(conversation: Conversation(), jobs: [])
        XCTAssertTrue(dir.isEmpty)
        XCTAssertTrue(dir.running.isEmpty)
        XCTAssertTrue(dir.ended.isEmpty)

        XCTAssertTrue(InspectorSubagentDirectory.build(conversation: nil, jobs: []).isEmpty)
        XCTAssertEqual(InspectorSubagentDirectory.allEmptyMessage, "No subagents in this task")
        XCTAssertEqual(InspectorSubagentDirectory.runningEmptyMessage, "No running subagents")
        XCTAssertEqual(InspectorSubagentDirectory.loadFailedMessage, "Unable to load subagents.")
        XCTAssertEqual(InspectorSubagentDirectory.showMoreTitle, "Show 20 more")
        XCTAssertEqual(InspectorSubagentDirectory.runningTitle, "Running")
        XCTAssertEqual(InspectorSubagentDirectory.endedTitle, "Ended")
    }

    // MARK: - Transcript merge

    func testMergesTaskInvocationAndResultIntoEndedCompleted() throws {
        let taskID = UUID()
        let invocation = try taskInvocation(
            id: "call_task_1",
            type: "explore",
            description: "list downloads",
            prompt: "List the contents of ~/Downloads"
        )
        let result = """
        Listed 3 files.

        task_id: \(taskID.uuidString)
        type: explore
        description: list downloads
        """
        let conversation = Conversation(messages: turn(
            user: "look at downloads",
            assistantTools: [invocation],
            results: [("call_task_1", result)]
        ))

        let dir = InspectorSubagentDirectory.build(conversation: conversation, jobs: [])
        XCTAssertTrue(dir.running.isEmpty)
        XCTAssertEqual(dir.ended.count, 1)
        let entry = try XCTUnwrap(dir.ended.first)
        XCTAssertEqual(entry.status, .completed)
        XCTAssertEqual(entry.status.title, "Completed")
        XCTAssertEqual(entry.taskId, taskID)
        XCTAssertEqual(entry.toolCallId, "call_task_1")
        XCTAssertEqual(entry.type, "explore")
        XCTAssertEqual(entry.description, "list downloads")
        XCTAssertEqual(entry.prompt, "List the contents of ~/Downloads")
        XCTAssertTrue(entry.output.contains("Listed 3 files."))
        XCTAssertFalse(entry.canKill)
    }

    func testMergesSubagentMetaBlock() throws {
        let taskID = UUID()
        let invocation = try taskInvocation(
            id: "call_meta",
            type: "general-purpose",
            description: "summarize repo",
            prompt: "Summarize this repository"
        )
        let result = """
        Summary ready.

        <subagent_meta>
        id: agent_\(taskID.uuidString)
        task_id: \(taskID.uuidString)
        agent_id: agent_\(taskID.uuidString)
        type: general-purpose
        description: summarize repo
        cancelled: false
        background: false
        </subagent_meta>
        """
        let conversation = Conversation(messages: turn(
            user: "summarize",
            assistantTools: [invocation],
            results: [("call_meta", result)]
        ))
        let dir = InspectorSubagentDirectory.build(conversation: conversation, jobs: [])
        let entry = try XCTUnwrap(dir.ended.first)
        XCTAssertEqual(entry.taskId, taskID)
        XCTAssertEqual(entry.status, .completed)
        XCTAssertEqual(entry.output, "Summary ready.")
    }

    // MARK: - Jobs

    func testRunningSnapshotMapsToRunning() {
        let id = UUID()
        let job = BackgroundJobSnapshot(
            id: id,
            kind: .subagent,
            status: .running,
            command: "explore: list files",
            output: "scanning…",
            exitCode: nil,
            startedAt: Date(),
            finishedAt: nil
        )
        let dir = InspectorSubagentDirectory.build(conversation: Conversation(), jobs: [job])
        XCTAssertEqual(dir.running.count, 1)
        XCTAssertTrue(dir.ended.isEmpty)
        XCTAssertEqual(dir.running.first?.status, .running)
        XCTAssertEqual(dir.running.first?.status.title, "Running")
        XCTAssertEqual(dir.running.first?.taskId, id)
        XCTAssertEqual(dir.running.first?.type, "explore")
        XCTAssertEqual(dir.running.first?.description, "list files")
        XCTAssertEqual(dir.running.first?.output, "scanning…")
        XCTAssertTrue(dir.running.first?.canKill == true)
    }

    func testIgnoresNonSubagentJobs() {
        let job = BackgroundJobSnapshot(
            id: UUID(),
            kind: .shell,
            status: .running,
            command: "ls",
            output: "",
            exitCode: nil,
            startedAt: Date(),
            finishedAt: nil
        )
        let dir = InspectorSubagentDirectory.build(conversation: Conversation(), jobs: [job])
        XCTAssertTrue(dir.isEmpty)
    }

    func testJobOverlaysTranscriptByTaskID() throws {
        let taskID = UUID()
        let invocation = try taskInvocation(
            id: "call_live",
            type: "explore",
            description: "scan src",
            prompt: "Scan src"
        )
        let result = """
        Background subagent started.
        task_id: \(taskID.uuidString)
        type: explore
        description: scan src

        <subagent_meta>
        task_id: \(taskID.uuidString)
        type: explore
        description: scan src
        status: running
        background: true
        </subagent_meta>
        """
        let conversation = Conversation(messages: turn(
            user: "scan",
            assistantTools: [invocation],
            results: [("call_live", result)]
        ))
        let job = BackgroundJobSnapshot(
            id: taskID,
            kind: .subagent,
            status: .running,
            command: "explore: scan src",
            output: "file a\nfile b",
            exitCode: nil,
            startedAt: Date().addingTimeInterval(-12),
            finishedAt: nil
        )
        let dir = InspectorSubagentDirectory.build(conversation: conversation, jobs: [job])
        XCTAssertEqual(dir.running.count, 1)
        XCTAssertTrue(dir.ended.isEmpty)
        let entry = try XCTUnwrap(dir.running.first)
        XCTAssertEqual(entry.taskId, taskID)
        XCTAssertEqual(entry.toolCallId, "call_live")
        XCTAssertEqual(entry.prompt, "Scan src")
        XCTAssertEqual(entry.output, "file a\nfile b")
        XCTAssertEqual(entry.status, .running)
    }

    // MARK: - Status map

    func testJobStatusMap() {
        XCTAssertEqual(InspectorSubagentDirectory.status(from: .running), .running)
        XCTAssertEqual(InspectorSubagentDirectory.status(from: .completed), .completed)
        XCTAssertEqual(InspectorSubagentDirectory.status(from: .failed), .failed)
        XCTAssertEqual(InspectorSubagentDirectory.status(from: .killed), .cancelled)
        XCTAssertEqual(InspectorSubagentDirectory.status(from: .timedOut), .lost)

        XCTAssertEqual(InspectorSubagentStatus.cancelled.title, "Cancelled")
        XCTAssertEqual(InspectorSubagentStatus.failed.title, "Failed")
        XCTAssertEqual(InspectorSubagentStatus.lost.title, "Lost")
        XCTAssertEqual(InspectorSubagentStatus.waiting.title, "Waiting")
        XCTAssertEqual(InspectorSubagentStatus.blocked.title, "Blocked")

        let killed = snapshot(status: .killed)
        XCTAssertEqual(
            InspectorSubagentDirectory.build(conversation: Conversation(), jobs: [killed]).ended.first?.status,
            .cancelled
        )
        let failed = snapshot(status: .failed)
        XCTAssertEqual(
            InspectorSubagentDirectory.build(conversation: Conversation(), jobs: [failed]).ended.first?.status,
            .failed
        )
        let timedOut = snapshot(status: .timedOut)
        let timedOutStatus = InspectorSubagentDirectory.build(
            conversation: Conversation(),
            jobs: [timedOut]
        ).ended.first?.status
        XCTAssertTrue(
            timedOutStatus == .lost || timedOutStatus == .failed,
            "timedOut should map to Lost or Failed, got \(String(describing: timedOutStatus))"
        )
    }

    func testNamedStatusParse() {
        XCTAssertEqual(InspectorSubagentDirectory.status(named: "waiting"), .waiting)
        XCTAssertEqual(InspectorSubagentDirectory.status(named: "blocked"), .blocked)
        XCTAssertEqual(InspectorSubagentDirectory.status(named: "cancelled"), .cancelled)
        XCTAssertEqual(InspectorSubagentDirectory.status(named: "lost"), .lost)
    }

    // MARK: - Notifications

    func testOpenSubagentNotificationNameAndUserInfoParse() {
        XCTAssertEqual(
            Notification.Name.openSubagentInInspector.rawValue,
            "agentos.openSubagentInInspector"
        )
        let taskID = UUID()
        let note = Notification(
            name: .openSubagentInInspector,
            object: nil,
            userInfo: [
                "taskId": taskID.uuidString,
                "toolCallId": "call_9",
                "type": "explore",
                "description": "list files",
            ]
        )
        let parsed = InspectorSubagentOpenRequest.parse(note)
        XCTAssertEqual(parsed.taskId, taskID.uuidString)
        XCTAssertEqual(parsed.toolCallId, "call_9")
        XCTAssertEqual(parsed.type, "explore")
        XCTAssertEqual(parsed.description, "list files")

        let missing = InspectorSubagentOpenRequest.parse(
            Notification(name: .openSubagentInInspector, object: nil)
        )
        XCTAssertNil(missing.taskId)
        XCTAssertNil(missing.toolCallId)
    }

    func testOpenInSidePaneUserInfoKeys() {
        XCTAssertEqual(
            Set(InspectorSubagentOpenRequest.userInfoKeys),
            Set(["taskId", "toolCallId", "type", "description"])
        )
        let request = InspectorSubagentOpenRequest(
            taskId: "T1",
            toolCallId: "C1",
            type: "plan",
            description: "draft plan"
        )
        XCTAssertEqual(
            Set(request.userInfo().keys),
            Set(["taskId", "toolCallId", "type", "description"])
        )
        XCTAssertEqual(request.userInfo()["taskId"], "T1")
        XCTAssertEqual(request.userInfo()["toolCallId"], "C1")
        XCTAssertEqual(request.userInfo()["type"], "plan")
        XCTAssertEqual(request.userInfo()["description"], "draft plan")
    }

    func testOpenRequestMatchesMergedEntry() throws {
        let taskID = UUID()
        let invocation = try taskInvocation(
            id: "call_match",
            type: "explore",
            description: "find todos",
            prompt: "Find TODOs"
        )
        let conversation = Conversation(messages: turn(
            user: "find",
            assistantTools: [invocation],
            results: [("call_match", "done\ntask_id: \(taskID.uuidString)\n")]
        ))
        let dir = InspectorSubagentDirectory.build(conversation: conversation, jobs: [])
        let byTask = InspectorSubagentOpenRequest(taskId: taskID.uuidString)
        XCTAssertEqual(byTask.matchingID(in: dir), dir.ended.first?.id)
        let byCall = InspectorSubagentOpenRequest(toolCallId: "call_match")
        XCTAssertEqual(byCall.matchingID(in: dir), dir.ended.first?.id)
    }

    func testOutputFooterTruncation() {
        let long = (1...50).map { "row \($0)" }.joined(separator: "\n")
        let lines = InspectorSubagentDirectory.outputLines(long, maxVisible: 10)
        XCTAssertEqual(lines.total, 50)
        XCTAssertEqual(lines.visible.count, 10)
        XCTAssertEqual(lines.visible.first, "row 41")
        XCTAssertEqual(
            InspectorSubagentDirectory.outputFooter(visible: 10, total: 50),
            "Latest 10 rows / 50 total"
        )
        XCTAssertNil(InspectorSubagentDirectory.outputFooter(visible: 3, total: 3))
        XCTAssertEqual(InspectorSubagentDirectory.outputEmptyMessage, "No output yet")
        XCTAssertEqual(InspectorSubagentDirectory.promptTitle, "Prompt")
        XCTAssertEqual(InspectorSubagentDirectory.outputTitle, "SubAgent output")
        XCTAssertTrue(SubagentThreadBuilder.isHeartbeatOutput("[iter 5] tools: read_file"))
        XCTAssertTrue(SubagentThreadBuilder.isHeartbeatOutput("[running] list_directory"))
    }

    func testJobTranscriptBecomesDirectoryThreadNotSummary() {
        let id = UUID()
        let call = ToolCallInvocation(
            id: "c1",
            name: "list_directory",
            arguments: #"{"path":"/Users/maxkongerskov/Desktop"}"#
        )
        let transcript = [
            ChatMessage(role: .user, content: "List Desktop"),
            ChatMessage(role: .assistant, content: "", toolCalls: [call]),
            ChatMessage(role: .tool, content: "Typeset\nMapper", toolCallID: "c1"),
            ChatMessage(role: .assistant, content: "**Desktop: 20 items total**"),
        ]
        let job = BackgroundJobSnapshot(
            id: id,
            kind: .subagent,
            status: .completed,
            command: "explore: List Desktop items",
            output: "**Desktop: 20 items total** (12 files, 8 folders)",
            exitCode: 0,
            startedAt: Date().addingTimeInterval(-105),
            finishedAt: Date(),
            transcript: transcript
        )
        let dir = InspectorSubagentDirectory.build(conversation: Conversation(), jobs: [job])
        let entry = dir.ended.first
        XCTAssertEqual(entry?.threadItems.map(\.kind), [.tool, .assistant])
        XCTAssertEqual(entry?.threadItems.first?.toolName, "list_directory")
        XCTAssertNotEqual(entry?.threadItems.first?.text, job.output)
        XCTAssertTrue(entry?.output.contains("20 items") == true)
    }

    func testEndedPagination() {
        let jobs = (0..<25).map { i in
            snapshot(id: UUID(), status: .completed, command: "explore: job \(i)")
        }
        let dir = InspectorSubagentDirectory.build(conversation: Conversation(), jobs: jobs)
        XCTAssertEqual(dir.ended.count, 25)
        XCTAssertEqual(
            InspectorSubagentDirectory.pagedEnded(dir.ended, limit: 20).count,
            20
        )
        XCTAssertEqual(
            InspectorSubagentDirectory.pagedEnded(dir.ended, limit: 40).count,
            25
        )
    }

    func testLiveTaskStatesFillDirectoryWhenTranscriptIsStale() {
        let args = #"{"subagent_type":"explore","description":"survey repo","prompt":"look around"}"#
        let running = ToolCallUIState(
            id: "call_live",
            toolName: "task",
            status: .running,
            input: args,
            output: ""
        )
        let dir = InspectorSubagentDirectory.build(
            conversation: Conversation(),
            jobs: [],
            liveTaskStates: [running]
        )
        XCTAssertEqual(dir.running.count, 1)
        XCTAssertEqual(dir.running.first?.type, "explore")
        XCTAssertEqual(dir.running.first?.description, "survey repo")
        XCTAssertEqual(dir.running.first?.status, .running)
        XCTAssertTrue(dir.ended.isEmpty)
    }

    // MARK: - Fixtures

    private func taskInvocation(
        id: String,
        type: String,
        description: String,
        prompt: String
    ) throws -> ToolCallInvocation {
        let data = try JSONSerialization.data(withJSONObject: [
            "subagent_type": type,
            "description": description,
            "prompt": prompt,
        ])
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return ToolCallInvocation(id: id, name: "task", arguments: json)
    }

    private func turn(
        user: String,
        assistantTools: [ToolCallInvocation],
        results: [(id: String, content: String)]
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = [
            ChatMessage(role: .user, content: user),
            ChatMessage(role: .assistant, content: "", toolCalls: assistantTools),
        ]
        for result in results {
            messages.append(ChatMessage(role: .tool, content: result.content, toolCallID: result.id))
        }
        messages.append(ChatMessage(role: .assistant, content: "done"))
        return messages
    }

    private func snapshot(
        id: UUID = UUID(),
        status: BackgroundJobStatus,
        command: String = "explore: job"
    ) -> BackgroundJobSnapshot {
        BackgroundJobSnapshot(
            id: id,
            kind: .subagent,
            status: status,
            command: command,
            output: "",
            exitCode: status == .running ? nil : 0,
            startedAt: Date().addingTimeInterval(-5),
            finishedAt: status == .running ? nil : Date()
        )
    }
}
