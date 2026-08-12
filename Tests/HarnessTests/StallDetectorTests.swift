//
//  StallDetectorTests.swift  (Harness)
//
//  Pins stall-detection via AgentCore.ChatLoop (shared with production).
//

import XCTest
import AgentCore

final class StallDetectorTests: XCTestCase {

    private func assistant(_ calls: [(String, String)]) -> ChatMessage {
        ChatMessage(role: .assistant, content: "",
                    toolCalls: calls.map {
                        ToolCallInvocation(id: UUID().uuidString, name: $0.0, arguments: $0.1)
                    })
    }

    func testSignatureIsOrderIndependent() {
        let a = ChatLoop.turnToolSignature(messages: [
            assistant([("read_file", #"{"path":"a"}"#), ("read_file", #"{"path":"b"}"#)])
        ])
        let b = ChatLoop.turnToolSignature(messages: [
            assistant([("read_file", #"{"path":"b"}"#), ("read_file", #"{"path":"a"}"#)])
        ])
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func testSignatureNilWhenNoToolCalls() {
        XCTAssertNil(ChatLoop.turnToolSignature(messages: [
            ChatMessage(role: .assistant, content: "done")
        ]))
    }

    func testSignatureExcludesPlanAuthoringTools() {
        XCTAssertNil(ChatLoop.turnToolSignature(messages: [
            assistant([("update_todo", "{}")])
        ]))
    }

    func testDetectsThreeInARowRepetition() {
        let sig = "read_file({\"path\":\"a\"})"
        XCTAssertNotNil(ChatLoop.detectStuckPattern([sig, sig, sig], repetitionThreshold: 3))
    }

    func testStallWindowControlsRepetitionThreshold() {
        let sig = "read_file({\"path\":\"a\"})"
        XCTAssertNil(ChatLoop.detectStuckPattern([sig, sig, sig], repetitionThreshold: 4))
        XCTAssertNotNil(ChatLoop.detectStuckPattern([sig, sig, sig, sig], repetitionThreshold: 4))
    }

    func testDetectsPingPong() {
        let a = "read_file(a)", b = "grep(b)"
        XCTAssertNotNil(ChatLoop.detectStuckPattern([a, b, a, b]))
    }

    func testNoStallOnProgress() {
        XCTAssertNil(ChatLoop.detectStuckPattern(["a", "b", "c"]))
    }

    func testNoStallBelowWindow() {
        XCTAssertNil(ChatLoop.detectStuckPattern(["a", "a"]))
    }
}