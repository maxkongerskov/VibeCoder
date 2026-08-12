//
//  ChronologicalTurnScopeTests.swift
//
//  Ensures live-turn tool UI does not include tools from earlier user turns.
//

import XCTest
@testable import VibeCoderApp
import AgentCore

@MainActor
final class ChronologicalTurnScopeTests: XCTestCase {

    func testLiveTurnToolStatesOnlyIncludesCurrentUserTurn() {
        var convo = Conversation(title: "t")
        let user1 = ChatMessage(role: .user, content: "list /tmp")
        let asst1 = ChatMessage(
            role: .assistant,
            content: "Listed.",
            toolCalls: [ToolCallInvocation(id: "call_0", name: "list_directory", arguments: "{\"path\":\"/tmp\"}")]
        )
        let user2 = ChatMessage(role: .user, content: "now list Downloads")
        let asst2 = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [ToolCallInvocation(id: "call_0", name: "list_directory", arguments: "{\"path\":\"~/Downloads\"}")]
        )
        convo.messages = [user1, asst1, user2, asst2]

        let app = AppViewModel()
        let vm = ChatViewModel(conversation: convo, app: app)
        // Seed tool maps as the loop would.
        vm.toolCallsByMessage[asst1.id] = [
            ToolCallUIState(id: "call_0", toolName: "list_directory", status: .success,
                            input: "{\"path\":\"/tmp\"}", output: "a b c")
        ]
        vm.toolCallsByMessage[asst2.id] = [
            ToolCallUIState(id: "call_0", toolName: "list_directory", status: .running,
                            input: "{\"path\":\"~/Downloads\"}", output: "")
        ]
        vm.isRunning = true

        let live = vm.liveTurnToolStates
        XCTAssertEqual(live.count, 1, "should not include turn-1 tools")
        XCTAssertEqual(live.first?.input, "{\"path\":\"~/Downloads\"}")
        XCTAssertEqual(live.first?.status, .running)
    }

    func testCodeTimelineKeepsUniqueIdsAcrossTurnsWithSameToolCallId() {
        var convo = Conversation(title: "t")
        let u1 = ChatMessage(role: .user, content: "edit a")
        let a1 = ChatMessage(
            role: .assistant,
            content: "done",
            toolCalls: [ToolCallInvocation(id: "call_0", name: "list_directory", arguments: "{\"path\":\"/a\"}")]
        )
        let u2 = ChatMessage(role: .user, content: "edit b")
        let a2 = ChatMessage(
            role: .assistant,
            content: "done",
            toolCalls: [ToolCallInvocation(id: "call_0", name: "list_directory", arguments: "{\"path\":\"/b\"}")]
        )
        convo.messages = [u1, a1, u2, a2]

        let states: [UUID: [ToolCallUIState]] = [
            a1.id: [ToolCallUIState(id: "call_0", toolName: "list_directory", status: .success,
                                    input: "{\"path\":\"/a\"}", output: "ok")],
            a2.id: [ToolCallUIState(id: "call_0", toolName: "list_directory", status: .success,
                                    input: "{\"path\":\"/b\"}", output: "ok")],
        ]
        let timeline = CodeSessionBuilder.build(conversation: convo, toolStates: states)
        let activityIDs = timeline.compactMap { entry -> String? in
            if case .activity(let s) = entry { return s.id }
            return nil
        }
        XCTAssertEqual(activityIDs.count, 2)
        XCTAssertEqual(Set(activityIDs).count, 2, "activity ids must be unique across turns")
        // Chronological per assistant message: prose then tools for that step
        // (not all tools first, one prose last).
        let kinds = timeline.map { entry -> String in
            switch entry {
            case .userPrompt: return "user"
            case .activity: return "activity"
            case .assistantProse: return "prose"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["user", "prose", "activity", "user", "prose", "activity"])
    }

    func testCodeTimelineInterleavesProseBeforeToolsWithinAMultiStepTurn() {
        var convo = Conversation(title: "t")
        let user = ChatMessage(role: .user, content: "fix the bug")
        let intro = ChatMessage(
            role: .assistant,
            content: "I'll inspect the file and patch it.",
            toolCalls: [
                ToolCallInvocation(id: "c1", name: "read_file", arguments: "{\"path\":\"a.swift\"}"),
                ToolCallInvocation(id: "c2", name: "edit_file", arguments: "{\"path\":\"a.swift\",\"old_string\":\"x\",\"new_string\":\"y\"}"),
            ]
        )
        let mid = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                ToolCallInvocation(id: "c3", name: "run_shell", arguments: "{\"command\":\"swift test\"}"),
            ]
        )
        let finale = ChatMessage(role: .assistant, content: "Patched and verified.")
        convo.messages = [user, intro, mid, finale]

        let states: [UUID: [ToolCallUIState]] = [
            intro.id: [
                ToolCallUIState(id: "c1", toolName: "read_file", status: .success, input: "{}", output: "ok"),
                ToolCallUIState(id: "c2", toolName: "edit_file", status: .success,
                                input: "{\"path\":\"a.swift\",\"old_string\":\"x\",\"new_string\":\"y\"}", output: "ok"),
            ],
            mid.id: [
                ToolCallUIState(id: "c3", toolName: "run_shell", status: .success, input: "{}", output: "ok"),
            ],
        ]

        let timeline = CodeSessionBuilder.build(conversation: convo, toolStates: states)
        let kinds = timeline.map { entry -> String in
            switch entry {
            case .userPrompt: return "user"
            case .assistantProse(let text, _, _): return "prose:\(text.prefix(12))"
            case .activity(let s): return "act:\(s.toolName)"
            case .fileEdit(let e): return "edit:\(e.toolName)"
            default: return "other"
            }
        }

        // Expected chronological: plan prose → tools → shell → final prose.
        XCTAssertEqual(kinds.first, "user")
        XCTAssertTrue(kinds[1].hasPrefix("prose:I'll inspect"), kinds[1])
        // read + edit (edit may be fileEdit if parseable)
        XCTAssertTrue(kinds[2].hasPrefix("act:read_file") || kinds[2].hasPrefix("edit:"), kinds[2])
        XCTAssertTrue(
            kinds.contains(where: { $0.hasPrefix("act:run_shell") }),
            "shell activity should appear after intro tools, not after final prose"
        )
        XCTAssertTrue(kinds.last?.hasPrefix("prose:Patched") == true, kinds.last ?? "nil")

        // Final prose must be after all tool rows.
        let lastProseIdx = kinds.lastIndex(where: { $0.hasPrefix("prose:") })!
        let lastToolIdx = kinds.lastIndex(where: { $0.hasPrefix("act:") || $0.hasPrefix("edit:") })!
        XCTAssertGreaterThan(lastProseIdx, lastToolIdx,
                             "final answer must sit below code generation")
        // Intro prose must be before tools.
        let introProseIdx = kinds.firstIndex(where: { $0.hasPrefix("prose:I'll") })!
        let firstToolIdx = kinds.firstIndex(where: { $0.hasPrefix("act:") || $0.hasPrefix("edit:") })!
        XCTAssertLessThan(introProseIdx, firstToolIdx,
                          "opening plan prose must sit above tools")
    }
}
