//
//  ToolResultCompressorTests.swift
//

import XCTest
@testable import AgentCore

final class ToolResultCompressorTests: XCTestCase {

    // MARK: - Helpers

    /// Three assistant turns: keepRecentTurns=1 protects the last *two*
    /// (current + 1), so only the oldest tool body is eligible for compress.
    /// `content` is placed on the **oldest** tool message (index 1).
    private func makeMessages(toolName: String, content: String) -> [ChatMessage] {
        var msgs: [ChatMessage] = []
        for i in 0..<3 {
            let id = "call-\(i)"
            msgs.append(ChatMessage(
                role: .assistant, content: "",
                toolCalls: [ToolCallInvocation(id: id, name: toolName, arguments: "{}")]))
            let body = i == 0 ? content : "short result \(i)"
            msgs.append(ChatMessage(role: .tool, content: body, toolCallID: id))
        }
        return msgs
    }

    // MARK: - Short results are left untouched

    func testShortResultPassesThrough() {
        let msgs = makeMessages(toolName: "read_file", content: "hello world")
        let out = ToolResultCompressor.compress(msgs)
        // Oldest tool body (content) is short → unchanged even if eligible.
        XCTAssertEqual(out[1].content, "hello world")
        XCTAssertEqual(out.last?.content, "short result 2")
    }

    // MARK: - Recent result is protected

    func testOldScreenshotImagesAreDroppedFromWireCopy() {
        let img = ChatImagePayload(mimeType: "image/png", base64Data: ComputerUseCapture.fixturePNGBase64)
        var msgs: [ChatMessage] = []
        for i in 0..<3 {
            let id = "shot-\(i)"
            msgs.append(ChatMessage(
                role: .assistant, content: "",
                toolCalls: [ToolCallInvocation(id: id, name: "screenshot", arguments: "{}")]))
            msgs.append(ChatMessage(
                role: .tool,
                content: "screenshot ok \(i)",
                toolCallID: id,
                images: [img]))
        }
        let out = ToolResultCompressor.compress(msgs)
        XCTAssertTrue(out[1].images.isEmpty, "oldest screenshot must drop vision parts")
        XCTAssertTrue(out[1].content.contains("older computer-use screenshot omitted"))
        XCTAssertFalse(out.last!.images.isEmpty, "most recent screenshot stays on the wire")
    }

    func testMostRecentResultIsNotCompressed() {
        let bigContent = String(repeating: "x", count: 5_000)
        // Only one turn — the single result is always "most recent".
        let callID = "call-1"
        let assistant = ChatMessage(
            role: .assistant, content: "",
            toolCalls: [ToolCallInvocation(id: callID, name: "read_file", arguments: "{}")])
        let tool = ChatMessage(role: .tool, content: bigContent, toolCallID: callID)
        let msgs = [assistant, tool]
        let out = ToolResultCompressor.compress(msgs)
        XCTAssertEqual(out.last?.content, bigContent, "Most-recent result must not be compressed")
    }

    // MARK: - read_file summarization

    func testReadFileSummary() {
        let lines = (1...100).map { "line \($0)" }
        let content = lines.joined(separator: "\n")
        let summary = ToolResultCompressor.summarizeReadFile(content)
        XCTAssertTrue(summary.contains("line 1"), "Should keep first lines")
        XCTAssertTrue(summary.contains("line 100"), "Should keep last lines")
        XCTAssertTrue(summary.contains("elided"), "Should mention elision")
        XCTAssertFalse(summary.contains("line 50"), "Middle lines should be gone")
    }

    func testReadFileShortPassesThrough() {
        let content = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let out = ToolResultCompressor.summarizeReadFile(content)
        XCTAssertEqual(out, content)
    }

    /// Large single-line / few-line blobs must char-truncate (not only multi-line elision).
    func testReadFileLargeSingleLineFallsBackToGeneric() {
        let content = String(repeating: "x", count: 5_000)
        let summary = ToolResultCompressor.summarizeReadFile(content)
        XCTAssertTrue(summary.count < content.count,
                      "Single-line multi-KB read_file bodies must shrink")
        XCTAssertTrue(summary.contains("truncated") || summary.contains("elided"),
                      "Should mark truncation: \(summary.suffix(80))")
    }

    func testCompressOldLargeSingleLineReadFile() {
        // Three assistant turns so keepRecentTurns=1 leaves the oldest eligible.
        let big = String(repeating: "y", count: 5_000)
        var msgs: [ChatMessage] = []
        for i in 0..<3 {
            let id = "c\(i)"
            msgs.append(ChatMessage(
                role: .assistant, content: "t\(i)",
                toolCalls: [ToolCallInvocation(
                    id: id, name: "read_file",
                    arguments: #"{"path":"/tmp/f\#(i).txt"}"#)]))
            msgs.append(ChatMessage(
                role: .tool,
                content: i == 0 ? big : String(repeating: "z", count: 100),
                toolCallID: id))
        }
        let out = ToolResultCompressor.compress(msgs)
        let tools = out.filter { $0.role == .tool }
        XCTAssertEqual(tools.count, 3)
        XCTAssertTrue(tools[0].content.count < big.count,
                      "Oldest large single-line tool result must compress")
        XCTAssertEqual(tools[2].content.count, 100,
                       "Most recent small tool body stays full")
    }

    // MARK: - Shell summarization

    func testShellSummaryKeepsErrorLines() {
        var lines = (1...60).map { "output line \($0)" }
        lines[25] = "error: something went wrong"
        let content = lines.joined(separator: "\n")
        let summary = ToolResultCompressor.summarizeShell(content)
        XCTAssertTrue(summary.contains("error: something went wrong"), "Key diagnostics must survive")
        XCTAssertTrue(summary.contains("elided"), "Should mention elision")
    }

    func testShellShortPassesThrough() {
        let content = (1...20).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ToolResultCompressor.summarizeShell(content), content)
    }

    // MARK: - Generic summarization

    func testGenericSummaryTruncates() {
        let content = String(repeating: "a", count: 2_000)
        let summary = ToolResultCompressor.summarizeGeneric(content)
        XCTAssertTrue(summary.count < content.count)
        XCTAssertTrue(summary.contains("truncated"))
    }

    // MARK: - Listing summarization

    func testListingSummaryTruncates() {
        let content = (1...100).map { "file\($0).swift" }.joined(separator: "\n")
        let summary = ToolResultCompressor.summarizeListing(content)
        XCTAssertTrue(summary.contains("more entries elided"))
        XCTAssertFalse(summary.contains("file100.swift"))
    }

    // MARK: - compress() integration

    func testCompressOldLargeResults() {
        // keepRecentTurns=1 protects last 2 assistant turns → need 3 turns
        // for the oldest large tool body to be eligible.
        let bigContent = String(repeating: "x\n", count: 2_000)  // >> threshold
        var msgs: [ChatMessage] = []
        for i in 0..<3 {
            let id = "call-\(i)"
            msgs.append(ChatMessage(
                role: .assistant, content: "",
                toolCalls: [ToolCallInvocation(
                    id: id, name: "read_file",
                    arguments: #"{"path":"/f\#(i).swift"}"#)]))
            msgs.append(ChatMessage(
                role: .tool,
                content: i == 0 ? bigContent : String(repeating: "y\n", count: 50),
                toolCallID: id))
        }
        let out = ToolResultCompressor.compress(msgs)
        let tools = out.filter { $0.role == .tool }
        XCTAssertEqual(tools.count, 3)
        XCTAssertTrue(tools[0].content.count < bigContent.count,
                      "Oldest large result should be compressed, got \(tools[0].content.count) chars")
        XCTAssertTrue(
            tools[0].content.contains("elided")
                || tools[0].content.contains("compressed")
                || tools[0].content.contains("truncated"),
            "Expected compress marker in body")
        // Most recent tool body stays full (not the big one in this setup).
        XCTAssertEqual(tools[2].content, String(repeating: "y\n", count: 50),
                       "Recent result must remain uncompressed")
    }

    func testCompressDoesNotMutateInput() {
        let bigContent = String(repeating: "z\n", count: 2_000)
        let msgs = makeMessages(toolName: "run_shell", content: bigContent)
        let original = msgs.map(\.content)
        _ = ToolResultCompressor.compress(msgs)
        // Original array is unchanged (wire copy only).
        XCTAssertEqual(msgs.map(\.content), original)
        XCTAssertEqual(msgs[1].content, bigContent, "oldest body must stay intact on input")
    }

    // MARK: - Deduplication

    func testDuplicateReadFileIsStubbed() {
        let content = "file content here"
        let path = "/project/Foo.swift"
        let args = #"{"path":"/project/Foo.swift"}"#

        let call0 = "call-0"
        let call1 = "call-1"
        let msgs: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "",
                        toolCalls: [ToolCallInvocation(id: call0, name: "read_file", arguments: args)]),
            ChatMessage(role: .tool, content: content, toolCallID: call0),
            ChatMessage(role: .assistant, content: "",
                        toolCalls: [ToolCallInvocation(id: call1, name: "read_file", arguments: args)]),
            ChatMessage(role: .tool, content: content, toolCallID: call1),
        ]
        let out = ToolResultCompressor.deduplicate(msgs)
        // First read should be stubbed.
        XCTAssertTrue(out[1].content.contains("unchanged"), "First duplicate should be stubbed")
        XCTAssertTrue(out[1].content.contains(path) || out[1].content.contains("Re-read"))
        // Second (last) read should be full.
        XCTAssertEqual(out[3].content, content, "Last read must keep full content")
    }

    func testNonDuplicateReadFileUnchanged() {
        let args = #"{"path":"/project/Bar.swift"}"#
        let call0 = "call-0"
        let msgs: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "",
                        toolCalls: [ToolCallInvocation(id: call0, name: "read_file", arguments: args)]),
            ChatMessage(role: .tool, content: "different each time", toolCallID: call0),
        ]
        let out = ToolResultCompressor.deduplicate(msgs)
        XCTAssertEqual(out[1].content, "different each time")
    }

    func testDifferentContentNotStubbed() {
        let args = #"{"path":"/project/Baz.swift"}"#
        let call0 = "call-0"
        let call1 = "call-1"
        let msgs: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "",
                        toolCalls: [ToolCallInvocation(id: call0, name: "read_file", arguments: args)]),
            ChatMessage(role: .tool, content: "version one", toolCallID: call0),
            ChatMessage(role: .assistant, content: "",
                        toolCalls: [ToolCallInvocation(id: call1, name: "read_file", arguments: args)]),
            ChatMessage(role: .tool, content: "version two", toolCallID: call1),
        ]
        let out = ToolResultCompressor.deduplicate(msgs)
        // Different content — first read should NOT be stubbed.
        XCTAssertEqual(out[1].content, "version one")
        XCTAssertEqual(out[3].content, "version two")
    }
}
