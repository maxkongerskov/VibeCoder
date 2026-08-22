//
//  ChatCompletionsWireAssemblyTests.swift
//
//  llama-server 400: "Cannot have 2 or more assistant messages at the
//  end of the list." Gating test for Unsloth / OpenAI-compat wire tail.
//

import XCTest
@testable import AgentCore

final class ChatCompletionsWireAssemblyTests: XCTestCase {

    private func call(_ id: String, _ name: String, args: String = "{}") -> ToolCallInvocation {
        ToolCallInvocation(id: id, name: name, arguments: args)
    }

    /// The 400 shape: naive `WireMessage.from` leaves two trailing assistants.
    func testNaiveFromLeavesTwoTrailingAssistantsOn400Shape() {
        let msgs = twoTrailingAssistantTranscript()
        let naive = msgs.map { ChatCompletionRequestBody.WireMessage.from($0) }
        XCTAssertEqual(naive.suffix(2).map(\.role), ["assistant", "assistant"])
    }

    /// Shipped assembly used by UnslothStudioBackend.encode.
    func testAssembledWireTailIsNotTwoAssistants() {
        let msgs = twoTrailingAssistantTranscript()
        let wire = ChatCompletionRequestBody.assembledWireMessages(from: msgs)
        XCTAssertGreaterThanOrEqual(wire.count, 2)
        let tail = wire.suffix(2).map(\.role)
        XCTAssertFalse(
            tail == ["assistant", "assistant"],
            "llama-server 400s when the last two wire roles are assistant; got \(tail)")
        XCTAssertEqual(wire.last?.role, "assistant")
    }

    /// Day-0 013: apply_patch then blocked identical read_file, then a
    /// follow-up assistant (the turn that 400'd). Next request must not
    /// end in two assistants.
    func testBlockedIdenticalReadFileThenFollowUpAssistant() {
        let read = call("r1", "read_file", args: #"{"path":"hello.swift"}"#)
        let patch = call("p1", "apply_patch")
        let read2 = call("r2", "read_file", args: #"{"path":"hello.swift"}"#)
        let dup = call("r3", "read_file", args: #"{"path":"hello.swift"}"#)
        let blocked = IdenticalConsecutiveToolCall.failClosedResult(toolName: "read_file")
        let msgs: [ChatMessage] = [
            .init(role: .user, content: "patch hello.swift with apply_patch"),
            .init(role: .assistant, content: "", toolCalls: [read]),
            .toolResult(ToolResult(content: "print(\"hello\")"), callID: "r1"),
            .init(role: .assistant, content: "", toolCalls: [patch]),
            .toolResult(ToolResult(content: "Patched hello.swift"), callID: "p1"),
            .init(role: .assistant, content: "", toolCalls: [read2]),
            .toolResult(ToolResult(content: "print(\"hello, world\")"), callID: "r2"),
            .init(role: .assistant, content: "Done. The unified diff was applied.", toolCalls: [dup]),
            .toolResult(blocked, callID: "r3"),
            .init(role: .assistant, content: "The edit is complete."),
        ]
        let naive = msgs.map { ChatCompletionRequestBody.WireMessage.from($0) }
        XCTAssertEqual(naive.last?.role, "assistant")

        let wire = ChatCompletionRequestBody.assembledWireMessages(from: msgs)
        XCTAssertNotEqual(wire.suffix(2).map(\.role), ["assistant", "assistant"])
        XCTAssertTrue(wire.contains { $0.role == "tool" && $0.toolCallId == "r3" })
        XCTAssertEqual(wire.first { $0.toolCallId == "r3" }?.name, "read_file")
    }

    func testToolRoleCarriesNameAndCallId() {
        let inv = call("abc", "read_file")
        let msgs: [ChatMessage] = [
            .init(role: .user, content: "read"),
            .init(role: .assistant, content: "", toolCalls: [inv]),
            .toolResult(ToolResult(content: "ok"), callID: "abc"),
        ]
        let wire = ChatCompletionRequestBody.assembledWireMessages(from: msgs)
        let tool = wire.last
        XCTAssertEqual(tool?.role, "tool")
        XCTAssertEqual(tool?.toolCallId, "abc")
        XCTAssertEqual(tool?.name, "read_file")
    }

    private func twoTrailingAssistantTranscript() -> [ChatMessage] {
        let inv = call("c1", "read_file")
        return [
            .init(role: .user, content: "go"),
            .init(role: .assistant, content: "", toolCalls: [inv]),
            .toolResult(ToolResult(content: "ok"), callID: "c1"),
            .init(role: .assistant, content: "Done."),
            .init(role: .assistant, content: "The edit is complete."),
        ]
    }
}
