//
//  ArtifactTests.swift
//

import Testing
import Foundation
import AgentCore
@testable import VibeCoderApp

@Suite("Artifact label + rebuild")
struct ArtifactTests {

    @Test("read_file produces human title with filename")
    func readFileLabel() {
        let d = ArtifactLabel.make(
            toolName: "read_file",
            argsJSON: #"{"path":"/Users/me/proj/App/ChatViewModel.swift"}"#,
            output: "import SwiftUI\n"
        )
        #expect(d.title == "Reading ChatViewModel.swift")
        #expect(d.kind == .filePreview(path: "/Users/me/proj/App/ChatViewModel.swift"))
    }

    @Test("edit_file produces editing title")
    func editFileLabel() {
        let d = ArtifactLabel.make(
            toolName: "edit_file",
            argsJSON: #"{"path":"Sources/Foo.swift","old_string":"a","new_string":"b"}"#,
            output: "@@ -1,3 +1,3 @@\n-a\n+b\n"
        )
        #expect(d.title == "Editing Foo.swift")
        #expect(d.kind == .diff(path: "Sources/Foo.swift"))
    }

    @Test("run_shell uses command in title")
    func shellLabel() {
        let d = ArtifactLabel.make(
            toolName: "run_shell",
            argsJSON: #"{"command":"swift test"}"#,
            output: "Test Suite passed\n"
        )
        #expect(d.title == "Running swift test")
        #expect(d.kind == .terminal(command: "swift test"))
    }

    @Test("malformed JSON args fall back gracefully")
    func malformedArgs() {
        let d = ArtifactLabel.make(toolName: "read_file", argsJSON: "not json", output: "")
        #expect(d.title == "Reading file")
        let activity = ArtifactLabel.activityLabel(toolName: "read_file", argsJSON: "{")
        #expect(activity == "Reading file")
    }

    @Test("plan meta-tools excluded from rail")
    func excludedTools() {
        #expect(!ArtifactLabel.shouldShowInRail(toolName: "create_plan"))
        #expect(!ArtifactLabel.shouldShowInRail(toolName: "update_todo"))
        #expect(ArtifactLabel.shouldShowInRail(toolName: "read_file"))
    }

    @Test("rebuild reconstructs cards from tool states")
    func rebuildFromMessages() {
        let assistantID = UUID()
        let assistant = ChatMessage(
            id: assistantID,
            role: .assistant,
            content: "",
            toolCalls: [
                ToolCallInvocation(id: "tc-1", name: "read_file", arguments: #"{"path":"Foo.swift"}"#),
                ToolCallInvocation(id: "tc-2", name: "create_plan", arguments: #"{"goal":"test"}"#),
            ]
        )
        let states: [UUID: [ToolCallUIState]] = [
            assistantID: [
                ToolCallUIState(id: "tc-1", toolName: "read_file", status: .success,
                                input: #"{"path":"Foo.swift"}"#, output: "let x = 1"),
                ToolCallUIState(id: "tc-2", toolName: "create_plan", status: .success,
                                input: #"{"goal":"test"}"#, output: "ok"),
            ]
        ]
        let cards = ArtifactRebuild.rebuild(
            from: [ChatMessage(role: .user, content: "hi"), assistant],
            toolStates: states
        )
        #expect(cards.count == 1)
        #expect(cards[0].id == "tc-1")
        #expect(cards[0].title == "Reading Foo.swift")
        #expect(cards[0].body == "let x = 1")
    }

    @Test("synthesized error output is not marked success")
    func rebuildErrorOutputIsFailure() {
        let assistantID = UUID()
        let assistant = ChatMessage(
            id: assistantID,
            role: .assistant,
            content: "",
            toolCalls: [
                ToolCallInvocation(id: "tc-err", name: "read_file", arguments: #"{"path":"Missing.swift"}"#),
            ]
        )
        let tool = ChatMessage(
            role: .tool,
            content: "Error: file not found",
            toolCallID: "tc-err"
        )
        let cards = ArtifactRebuild.rebuild(from: [assistant, tool])
        #expect(cards.count == 1)
        #expect(cards[0].status == .failure)
        #expect(cards[0].body.contains("file not found"))
    }

    @Test("activityLabel matches make title for running tools")
    func activityLabelMatches() {
        let args = #"{"path":"Bar.swift"}"#
        let title = ArtifactLabel.make(toolName: "edit_file", argsJSON: args, output: "").title
        #expect(ArtifactLabel.activityLabel(toolName: "edit_file", argsJSON: args) == title)
    }
}