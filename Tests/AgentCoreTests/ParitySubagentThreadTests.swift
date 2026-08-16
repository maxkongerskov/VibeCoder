//
//  ParitySubagentThreadTests.swift
//

import XCTest
@testable import AgentCore

final class ParitySubagentThreadTests: XCTestCase {

    func testBuilderSkipsSystemAndPromptUser() {
        let messages = [
            ChatMessage(role: .system, content: "rules"),
            ChatMessage(role: .user, content: "survey the repo"),
        ]
        XCTAssertTrue(SubagentThreadBuilder.items(from: messages).isEmpty)
    }

    func testBuilderTurnsToolPairIntoThreadSteps() {
        let call = ToolCallInvocation(
            id: "c1",
            name: "list_directory",
            arguments: #"{"path":"/Users/max/VibeCoder"}"#
        )
        let messages = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "look around"),
            ChatMessage(
                role: .assistant,
                content: "",
                reasoningContent: "I should list the root",
                toolCalls: [call]
            ),
            ChatMessage(role: .tool, content: "App\nSources", toolCallID: "c1"),
            ChatMessage(role: .assistant, content: "The repo has App and Sources."),
        ]
        let items = SubagentThreadBuilder.items(from: messages)
        XCTAssertEqual(items.map(\.kind), [.thought, .tool, .assistant])
        XCTAssertEqual(items[0].text, "I should list the root")
        XCTAssertEqual(items[1].toolName, "list_directory")
        XCTAssertEqual(items[1].status, .success)
        XCTAssertTrue(items[1].output.contains("App"))
        XCTAssertEqual(items[2].text, "The repo has App and Sources.")
    }

    func testUnpairedToolStaysRunning() {
        let call = ToolCallInvocation(
            id: "c2", name: "read_file", arguments: #"{"path":"README.md"}"#)
        let messages = [
            ChatMessage(role: .user, content: "read it"),
            ChatMessage(role: .assistant, content: "", toolCalls: [call]),
        ]
        let items = SubagentThreadBuilder.items(from: messages)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].status, .running)
        XCTAssertEqual(items[0].toolName, "read_file")
    }

    func testFailedToolMapsToFailure() {
        let call = ToolCallInvocation(id: "c3", name: "read_file", arguments: "{}")
        let messages = [
            ChatMessage(role: .user, content: "x"),
            ChatMessage(role: .assistant, content: "", toolCalls: [call]),
            ChatMessage(role: .tool, content: "Tool error: missing path", toolCallID: "c3"),
        ]
        let items = SubagentThreadBuilder.items(from: messages)
        XCTAssertEqual(items.single?.status, .failure)
    }

    func testDraftTranscriptAppendsLiveThoughtAndRunningTool() {
        let committed = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "survey the repo"),
        ]
        let draft = SubagentThreadBuilder.draftTranscript(
            committed: committed,
            reasoning: "I should list the root",
            content: "",
            toolCalls: [
                ToolCallInvocation(id: "c1", name: "list_directory", arguments: #"{"path":"."}"#)
            ]
        )
        let items = SubagentThreadBuilder.items(from: draft)
        XCTAssertEqual(items.map(\.kind), [.thought, .tool])
        XCTAssertEqual(items[0].text, "I should list the root")
        XCTAssertEqual(items[1].toolName, "list_directory")
        XCTAssertEqual(items[1].status, .running)
        XCTAssertEqual(committed.count, 2)
    }

    func testBuilderSkipsInjectedWakeUserLine() {
        let messages = [
            ChatMessage(role: .user, content: "list mapper"),
            ChatMessage(
                role: .user,
                content: "[system] Background job update for the parent agent:\noutput: done"
            ),
            ChatMessage(
                role: .assistant,
                content: "",
                toolCalls: [ToolCallInvocation(id: "c1", name: "list_directory", arguments: "{}")]
            ),
        ]
        let items = SubagentThreadBuilder.items(from: messages)
        XCTAssertEqual(items.map(\.kind), [.tool])
        XCTAssertFalse(items.contains { $0.text.contains("Background job") })
    }

    func testHeartbeatOutputIsNotAThread() {
        XCTAssertTrue(SubagentThreadBuilder.isHeartbeatOutput("[iter 5] tools: read_file, list_directory"))
        XCTAssertTrue(SubagentThreadBuilder.isHeartbeatOutput("[running] list_directory"))
        XCTAssertFalse(SubagentThreadBuilder.isHeartbeatOutput("Listed App and Sources."))
    }

    func testCompleteSubagentKeepsTranscriptThread() async throws {
        let id = UUID()
        _ = try await BackgroundJobManager.shared.registerSubagent(
            id: id, description: "explore: desktop")
        let call = ToolCallInvocation(
            id: "c1", name: "list_directory", arguments: #"{"path":"/Users/max/Desktop"}"#)
        let messages = [
            ChatMessage(role: .user, content: "list desktop"),
            ChatMessage(role: .assistant, content: "", toolCalls: [call]),
            ChatMessage(role: .tool, content: "Typeset\nMapper", toolCallID: "c1"),
            ChatMessage(role: .assistant, content: "**Desktop: 20 items total**"),
        ]
        await BackgroundJobManager.shared.updateSubagentTranscript(id: id, messages: messages)
        await BackgroundJobManager.shared.completeSubagent(
            id: id, output: "**Desktop: 20 items total**", failed: false)
        let items = await BackgroundJobManager.shared.threadItems(for: id)
        XCTAssertEqual(items.map(\.kind), [.tool, .assistant])
        XCTAssertEqual(items[0].toolName, "list_directory")
        XCTAssertTrue(items[0].output.contains("Typeset"))
        XCTAssertEqual(items[1].text, "**Desktop: 20 items total**")
        let snap = await BackgroundJobManager.shared.snapshot(id)
        XCTAssertEqual(snap?.status, .completed)
        XCTAssertEqual(snap?.transcript.count, 4)
    }

    func testStoreRoundTrip() async {
        await SubagentThreadStore.shared.removeAllForTests()
        let id = UUID()
        let messages = [
            ChatMessage(role: .user, content: "prompt"),
            ChatMessage(role: .assistant, content: "hello"),
        ]
        await SubagentThreadStore.shared.publish(jobID: id, messages: messages)
        let items = await SubagentThreadStore.shared.items(for: id)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "hello")
        await SubagentThreadStore.shared.removeAllForTests()
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
