//
//  ThinkingChromeTests.swift
//
//  Wave C W09 — thinking duration stamp + cancel-path message shape.
//

import XCTest
@testable import AgentCore

final class ThinkingChromeTests: XCTestCase {

    func testChatMessageRoundTripsThinkingDurationSeconds() throws {
        let msg = ChatMessage(
            role: .assistant,
            content: "answer",
            reasoningContent: "I should check the file",
            thinkingDurationSeconds: 34
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.thinkingDurationSeconds, 34)
        XCTAssertEqual(decoded.reasoningContent, "I should check the file")
    }

    func testChatMessageDecodesOlderJSONWithoutThinkingDuration() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","role":"assistant","content":"hi","timestamp":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: json)
        XCTAssertNil(decoded.thinkingDurationSeconds)
        XCTAssertEqual(decoded.content, "hi")
    }

    /// Cancel-path shape: reasoning-only partial must keep reasoningContent
    /// (AgentLoop now persists this when content is empty).
    func testPartialAssistantCanCarryReasoningWithoutProse() {
        let partial = ChatMessage(
            role: .assistant,
            content: "",
            reasoningContent: "Planning the edit…",
            thinkingDurationSeconds: 12
        )
        XCTAssertTrue(partial.content.isEmpty)
        XCTAssertEqual(partial.reasoningContent, "Planning the edit…")
        XCTAssertEqual(partial.thinkingDurationSeconds, 12)
    }

    func testPartialAssistantCarriesBothProseAndReasoning() {
        let partial = ChatMessage(
            role: .assistant,
            content: "Stopped mid-reply",
            reasoningContent: "Was about to call run_shell",
            thinkingDurationSeconds: 5
        )
        XCTAssertFalse(partial.content.isEmpty)
        XCTAssertNotNil(partial.reasoningContent)
    }
}
