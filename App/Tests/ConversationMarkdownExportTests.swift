//
//  ConversationMarkdownExportTests.swift
//  Product S6 — export completeness + reliability.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class ConversationMarkdownExportTests: XCTestCase {

    private let fixed = Date(timeIntervalSince1970: 1_700_000_000)

    func testExportsUserAndAssistantProse() {
        var c = Conversation(title: "Demo", modelID: "test-model")
        c.messages = [
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "Hi there"),
        ]
        let md = ConversationMarkdownExport.render(conversation: c, exportedAt: fixed)
        XCTAssertTrue(md.contains("# Demo"))
        XCTAssertTrue(md.contains("## User"))
        XCTAssertTrue(md.contains("Hello"))
        XCTAssertTrue(md.contains("## Assistant"))
        XCTAssertTrue(md.contains("Hi there"))
        XCTAssertTrue(md.contains("test-model"))
    }

    func testIncludesToolArgsAndResult() {
        let inv = ToolCallInvocation(id: "c1", name: "read_file", arguments: #"{"path":"a.swift"}"#)
        var c = Conversation(title: "Tools")
        c.messages = [
            ChatMessage(role: .user, content: "read it"),
            ChatMessage(role: .assistant, content: "", toolCalls: [inv]),
            ChatMessage(role: .tool, content: "file body", toolCallID: "c1"),
        ]
        let md = ConversationMarkdownExport.render(conversation: c, exportedAt: fixed)
        XCTAssertTrue(md.contains("## Tool — `read_file`"), md)
        XCTAssertTrue(md.contains("a.swift"), md)
        XCTAssertTrue(md.contains("file body"), md)
        XCTAssertTrue(md.contains("tool calls: read_file") || md.contains("## Assistant"), md)
    }

    func testIncludesReasoningAndStreaming() {
        var c = Conversation(title: "Think")
        var asst = ChatMessage(role: .assistant, content: "answer")
        asst.reasoningContent = "step by step"
        c.messages = [
            ChatMessage(role: .user, content: "q"),
            asst,
        ]
        let md = ConversationMarkdownExport.render(
            conversation: c,
            streamingContent: "partial…",
            streamingReasoning: "live reason",
            exportedAt: fixed)
        XCTAssertTrue(md.contains("### Reasoning"))
        XCTAssertTrue(md.contains("step by step"))
        XCTAssertTrue(md.contains("## Assistant (streaming)"))
        XCTAssertTrue(md.contains("partial…"))
        XCTAssertTrue(md.contains("live reason"))
    }

    func testSkipsSystemMessages() {
        var c = Conversation(title: "Sys")
        c.messages = [
            ChatMessage(role: .system, content: "secret system"),
            ChatMessage(role: .user, content: "hi"),
        ]
        let md = ConversationMarkdownExport.render(conversation: c, exportedAt: fixed)
        XCTAssertFalse(md.contains("secret system"))
        XCTAssertTrue(md.contains("hi"))
    }

    func testToolResultFenceSurvivesEmbeddedBackticks() {
        let inv = ToolCallInvocation(id: "c1", name: "read_file", arguments: #"{"path":"a.md"}"#)
        var c = Conversation(title: "Fence")
        c.messages = [
            ChatMessage(role: .user, content: "read it"),
            ChatMessage(role: .assistant, content: "", toolCalls: [inv]),
            ChatMessage(role: .tool, content: "before\n```\nsecret\n```\nafter", toolCallID: "c1"),
        ]
        let md = ConversationMarkdownExport.render(conversation: c, exportedAt: fixed)
        XCTAssertTrue(md.contains("secret"), md)
        XCTAssertTrue(md.contains("before"), md)
        XCTAssertTrue(md.contains("after"), md)
        // A 3-backtick fence would close on the embedded ``` and leak "secret"
        // out of the result block. A longer fence (or indent) keeps it inside.
        let resultRange = md.range(of: "**Result:**")
        XCTAssertNotNil(resultRange)
        let afterResult = String(md[resultRange!.upperBound...])
        XCTAssertTrue(
            afterResult.contains("````") || afterResult.contains("```\n    "),
            "result must be wrapped so embedded ``` cannot close the fence:\n\(md)"
        )
    }

    func testSuggestedFilenameSanitizes() {
        var c = Conversation(title: "a/b:c")
        XCTAssertEqual(ConversationMarkdownExport.suggestedFilename(for: c), "a-b-c.md")
        c.title = ""
        XCTAssertEqual(ConversationMarkdownExport.suggestedFilename(for: c), "conversation.md")
    }
}
