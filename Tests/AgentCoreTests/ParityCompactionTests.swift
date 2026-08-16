//
//  ParityCompactionTests.swift
//  ZCode-parity compaction helpers (classifier, micro-compact, rapid-refill).
//

import XCTest
@testable import AgentCore

final class ParityCompactionTests: XCTestCase {

    // MARK: - ContextOverflowClassifier

    func testClassifierMatchesZCodeMarkers() {
        let markers = [
            "model_context_exceeded",
            "context_exceeded",
            "context_length_exceeded",
            "context_window_exceeded",
            "model_context_window_exceeded",
            "prompt_too_long",
        ]
        for marker in markers {
            XCTAssertTrue(
                ContextOverflowClassifier.isContextExceeded(marker),
                "marker should match: \(marker)")
            XCTAssertTrue(
                ContextOverflowClassifier.isContextExceeded("HTTP 400: {\"code\":\"\(marker)\"}"),
                "HTTP-ish wrapper should match: \(marker)")
        }
    }

    func testClassifierMatchesOpenAIAndAnthropicVariants() {
        XCTAssertTrue(ContextOverflowClassifier.isContextExceeded(
            "This model's maximum context length is 8192 tokens. However, your messages resulted in 9000 tokens."))
        XCTAssertTrue(ContextOverflowClassifier.isContextExceeded(
            "too many tokens in your request"))
        XCTAssertTrue(ContextOverflowClassifier.isContextExceeded(
            "prompt is too long: 200000 tokens"))
        XCTAssertTrue(ContextOverflowClassifier.isContextExceeded(
            "input token count exceeds the maximum number of tokens allowed"))
    }

    func testClassifierRejectsLengthStopAndNoise() {
        XCTAssertFalse(ContextOverflowClassifier.isContextExceeded("max_tokens"))
        XCTAssertFalse(ContextOverflowClassifier.isContextExceeded("finish_reason: length"))
        XCTAssertFalse(ContextOverflowClassifier.isContextExceeded("finish_reason=max_tokens"))
        XCTAssertFalse(ContextOverflowClassifier.isContextExceeded("output truncated due to max_tokens"))
        XCTAssertFalse(ContextOverflowClassifier.isContextExceeded(""))
        XCTAssertFalse(ContextOverflowClassifier.isContextExceeded("HTTP 400: invalid_request"))
        XCTAssertFalse(ContextOverflowClassifier.isContextExceeded("rate_limit_error"))
    }

    func testClassifierErrorOverloadReadsBackendHTTPBody() {
        let overflow = BackendError.http(
            status: 400,
            body: "context_length_exceeded: request too large")
        XCTAssertTrue(ContextOverflowClassifier.isContextExceeded(error: overflow))

        let lengthStop = BackendError.http(status: 200, body: "finish_reason: max_tokens")
        XCTAssertFalse(ContextOverflowClassifier.isContextExceeded(error: lengthStop))

        let transport = BackendError.transport("prompt_too_long from proxy")
        XCTAssertTrue(ContextOverflowClassifier.isContextExceeded(error: transport))
    }

    // MARK: - MicroCompactor

    func testMicroCompactKeepsRecentAndPairing() {
        var messages: [ChatMessage] = []
        for i in 0..<10 {
            let id = "call-\(i)"
            let tool = i == 3 ? "ask_user" : "read_file"
            messages.append(ChatMessage(
                role: .assistant,
                content: "step \(i)",
                toolCalls: [ToolCallInvocation(
                    id: id, name: tool, arguments: #"{"path":"/f\#(i).swift"}"#)]))
            messages.append(ChatMessage(
                role: .tool,
                content: "BODY-\(i)-" + String(repeating: "x", count: 40),
                toolCallID: id))
        }
        XCTAssertEqual(messages.count, 20)

        let originalIDs = messages.compactMap(\.toolCallID)
        let originalCalls = messages.flatMap { $0.toolCalls.map(\.id) }
        let originalContents = messages.map(\.content)

        let convo = Conversation(title: "micro", messages: messages)
        let out = MicroCompactor.compact(convo, keepRecent: 6)

        XCTAssertEqual(convo.messages.map(\.content), originalContents,
                       "caller Conversation must not be mutated")
        XCTAssertEqual(out.messages.count, messages.count)
        XCTAssertEqual(out.messages.compactMap(\.toolCallID), originalIDs)
        XCTAssertEqual(out.messages.flatMap { $0.toolCalls.map(\.id) }, originalCalls)
        XCTAssertTrue(ChatLoop.toolCallPairingIsValid(in: out.messages))

        let cut = messages.count - 6
        for i in cut..<messages.count {
            XCTAssertEqual(
                out.messages[i].content, messages[i].content,
                "recent message \(i) must stay intact")
        }

        // Older compactable tool bodies cleared; non-listed tools left alone.
        for i in 0..<cut where messages[i].role == .tool {
            if messages[i].toolCallID == "call-3" {
                XCTAssertEqual(out.messages[i].content, messages[i].content,
                               "ask_user is not in the default compactable set")
            } else {
                XCTAssertEqual(out.messages[i].content, MicroCompactor.clearedMarker)
            }
        }
    }

    func testMicroCompactAcceptsZCodeAliasesAndSkipsAlreadyCleared() {
        let call = ToolCallInvocation(id: "r1", name: "Read", arguments: "{}")
        let messages = [
            ChatMessage(role: .assistant, content: "", toolCalls: [call]),
            ChatMessage(role: .tool, content: "already gone", toolCallID: "r1"),
            ChatMessage(role: .assistant, content: "later"),
            ChatMessage(role: .user, content: "go on"),
            ChatMessage(role: .assistant, content: "ok"),
            ChatMessage(role: .user, content: "more"),
            ChatMessage(role: .assistant, content: "done"),
        ]
        let once = MicroCompactor.compact(messages: messages, keepRecent: 4)
        XCTAssertEqual(once[1].content, MicroCompactor.clearedMarker)
        let twice = MicroCompactor.compact(messages: once, keepRecent: 4)
        XCTAssertEqual(twice[1].content, MicroCompactor.clearedMarker)
    }

    func testCompressorSkipsMicrocompactMarker() {
        let big = String(repeating: "z", count: 5_000)
        var msgs: [ChatMessage] = []
        for i in 0..<3 {
            let id = "c\(i)"
            msgs.append(ChatMessage(
                role: .assistant, content: "",
                toolCalls: [ToolCallInvocation(id: id, name: "read_file", arguments: "{}")]))
            let body = i == 0 ? MicroCompactor.clearedMarker : (i == 1 ? big : "short")
            msgs.append(ChatMessage(role: .tool, content: body, toolCallID: id))
        }
        let out = ToolResultCompressor.compress(msgs)
        XCTAssertEqual(out[1].content, MicroCompactor.clearedMarker)
    }

    // MARK: - RapidRefillBreaker

    func testRapidRefillTripsAtThreeConsecutiveCompacts() {
        var breaker = RapidRefillBreaker()
        XCTAssertFalse(breaker.shouldHardStop())
        breaker.recordCompact()
        XCTAssertFalse(breaker.shouldHardStop())
        breaker.recordCompact()
        XCTAssertTrue(breaker.shouldHardStop(), "third consecutive compact is blocked")
        breaker.recordCompact()
        XCTAssertTrue(breaker.shouldHardStop())
    }

    func testRapidRefillResetsAfterThreeToolTurns() {
        var breaker = RapidRefillBreaker()
        breaker.recordCompact()
        breaker.recordCompact()
        XCTAssertTrue(breaker.shouldHardStop())
        breaker.recordToolTurn()
        breaker.recordToolTurn()
        XCTAssertTrue(breaker.shouldHardStop(), "2 tool turns is not a reset")
        breaker.recordToolTurn()
        XCTAssertFalse(breaker.shouldHardStop(), ">=3 tool turns resets the streak")
        breaker.recordCompact()
        XCTAssertFalse(breaker.shouldHardStop(), "compact after a healthy stretch is not rapid")
    }

    func testRapidRefillTwoToolsBetweenCompactsStillCounts() {
        var breaker = RapidRefillBreaker()
        breaker.recordCompact()
        breaker.recordToolTurn()
        breaker.recordToolTurn()
        breaker.recordCompact()
        XCTAssertTrue(breaker.shouldHardStop(), "<3 tool turns between each pair trips at 3")
    }

    // MARK: - FullReplace 9-section + continuation

    func testFullReplaceEmitsNineSectionsAndContinuation() async {
        var messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "Build a calculator app"),
            ChatMessage(
                role: .assistant,
                content: "I will decide to use SwiftUI.",
                toolCalls: [ToolCallInvocation(
                    id: "1", name: "read_file",
                    arguments: #"{"path":"/src/Calc.swift"}"#)]),
            ChatMessage(role: .tool, content: "Tool error: missing file", toolCallID: "1"),
        ]
        for i in 0..<12 {
            messages.append(ChatMessage(role: .user, content: "Continue \(i) " + String(repeating: "x", count: 80)))
            messages.append(ChatMessage(role: .assistant, content: "Working \(i) " + String(repeating: "y", count: 80)))
        }

        let result = await FullReplaceCompactor.compact(
            messages,
            systemPromptTokens: 50,
            budgetTokens: 400,
            keepRecent: 4)

        XCTAssertGreaterThan(result.droppedCount, 0)
        XCTAssertTrue(
            result.messages.first?.content.contains(FullReplaceCompactor.continuationPreamble) == true,
            "carrier must use ZCode continuation framing")
        for heading in FullReplaceCompactor.nineSectionHeadings {
            XCTAssertTrue(
                result.summary.contains(heading),
                "extractive summary missing \(heading):\n\(result.summary)")
        }
        for heading in FullReplaceCompactor.nineSectionHeadings {
            XCTAssertTrue(
                FullReplaceCompactor.nineSectionInstructions.contains(heading),
                "nineSectionInstructions missing \(heading)")
        }
        XCTAssertTrue(result.durableNote.lowercased().contains("swiftui"),
                      "durable note should keep planted decision: \(result.durableNote)")
    }

    func testFormatCompactSummaryStripsAnalysis() {
        let raw = """
        <analysis>scratch</analysis>
        <summary>
        1. Primary Request and Intent:
           Ship it
        </summary>
        """
        let formatted = FullReplaceCompactor.formatCompactSummary(raw)
        XCTAssertFalse(formatted.contains("<analysis>"))
        XCTAssertTrue(formatted.contains("Primary Request"))
        XCTAssertTrue(formatted.contains("Ship it"))
    }
}
