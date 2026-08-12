//
//  SubAgentWireCompactionTests.swift
//
//  Wave B S6b: SubAgentRunner wire compaction (ToolResultCompressor + elision).
//

import XCTest
@testable import AgentCore

final class SubAgentWireCompactionTests: XCTestCase {

    private func model(contextLength: Int? = 32_768) -> ModelDescriptor {
        ModelDescriptor(
            id: "test-model",
            displayName: "Test",
            backend: .lmStudio,
            supportsTools: true,
            contextLength: contextLength)
    }

    /// Build N assistant→tool turns with large tool bodies so compression
    /// and elision have material to work on.
    private func longTranscript(turns: Int, toolChars: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are a sub-agent."),
            ChatMessage(role: .user, content: "Investigate the codebase."),
        ]
        for i in 0..<turns {
            let callID = "call-\(i)"
            messages.append(ChatMessage(
                role: .assistant,
                content: "Reading file \(i)",
                toolCalls: [ToolCallInvocation(
                    id: callID,
                    name: "read_file",
                    arguments: #"{"path":"/tmp/file\#(i).swift"}"#)]))
            messages.append(ChatMessage(
                role: .tool,
                content: String(repeating: "x", count: toolChars),
                toolCallID: callID))
        }
        return messages
    }

    func testWireMessagesDoesNotMutateInput() {
        let input = longTranscript(turns: 4, toolChars: 5_000)
        let originalContents = input.map(\.content)
        _ = SubAgentRunner.wireMessages(
            from: input,
            model: model(),
            contextBudgetTokens: 4_000)
        XCTAssertEqual(input.map(\.content), originalContents,
                       "wireMessages must never mutate the stored transcript")
    }

    func testToolResultCompressorShrinksOldLargeTools() {
        // Two+ assistant turns: oldest tool eligible for compress (keepRecentTurns=1).
        let input = longTranscript(turns: 3, toolChars: 5_000)
        let wire = SubAgentRunner.wireMessages(
            from: input,
            model: model(),
            // Huge budget so only ToolResultCompressor fires, not elision.
            contextBudgetTokens: 1_000_000)

        // First tool result (oldest) should be summarized; last protected.
        let toolBodies = wire.filter { $0.role == .tool }.map(\.content)
        XCTAssertEqual(toolBodies.count, 3)
        XCTAssertTrue(
            toolBodies[0].count < 5_000 || toolBodies[0].contains("elided")
                || toolBodies[0].contains("Re-read"),
            "Older large tool results should be compressed: \(toolBodies[0].prefix(80))")
        // Most recent tool result stays full when only compress runs and it is
        // within the protected recent turns.
        XCTAssertEqual(toolBodies.last?.count, 5_000,
                       "Most recent tool body must stay full under high budget")
    }

    func testElisionFiresUnderTightBudget() {
        let input = longTranscript(turns: 6, toolChars: 3_000)
        let tightBudget = 2_048
        let wire = SubAgentRunner.wireMessages(
            from: input,
            model: model(contextLength: 8_000),
            contextBudgetTokens: tightBudget)

        let wireTokens = ChatLoop.estimateTotalTokens(
            systemPromptTokens: 0, messages: wire)
        let fullTokens = ChatLoop.estimateTotalTokens(
            systemPromptTokens: 0, messages: input)

        XCTAssertLessThan(wireTokens, fullTokens,
                          "Wire path must reduce estimated tokens under tight budget")
        // Elision markers appear on old tool/assistant content when over budget.
        let joined = wire.map(\.content).joined(separator: "\n")
        let shrunk = wire.contains { msg in
            msg.role == .tool && msg.content.count < 3_000
        } || joined.contains("elided")
        XCTAssertTrue(shrunk, "Expected compression and/or elision markers in wire copy")
    }

    func testDefaultBudgetUsesModelContextLength() {
        // With a tiny window, derived budget is small → wire should shrink.
        let input = longTranscript(turns: 5, toolChars: 4_000)
        let wire = SubAgentRunner.wireMessages(
            from: input,
            model: model(contextLength: 4_096),
            contextBudgetTokens: nil)

        let wireTokens = ChatLoop.estimateTotalTokens(
            systemPromptTokens: 0, messages: wire)
        let fullTokens = ChatLoop.estimateTotalTokens(
            systemPromptTokens: 0, messages: input)
        XCTAssertLessThan(wireTokens, fullTokens)
    }

    func testNilContextLengthFallsBackToDefaultWindow() {
        let input = longTranscript(turns: 2, toolChars: 100)
        // Should not crash; short transcript stays unchanged under large default window.
        let wire = SubAgentRunner.wireMessages(
            from: input,
            model: model(contextLength: nil),
            contextBudgetTokens: nil)
        XCTAssertEqual(wire.count, input.count)
        XCTAssertEqual(wire.map(\.role), input.map(\.role))
    }

    func testSystemAndUserMessagesPreserved() {
        let input = longTranscript(turns: 4, toolChars: 5_000)
        let wire = SubAgentRunner.wireMessages(
            from: input,
            model: model(),
            contextBudgetTokens: 3_000)
        XCTAssertEqual(wire.first?.role, .system)
        XCTAssertEqual(wire.first?.content, "You are a sub-agent.")
        XCTAssertTrue(wire.contains { $0.role == .user && $0.content.contains("Investigate") })
    }
}
