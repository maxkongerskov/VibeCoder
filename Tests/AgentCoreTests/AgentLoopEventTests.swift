//
//  AgentLoopEventTests.swift
//
//  Event-sequence tests for AgentLoop driven by a scripted fake backend.
//  Pins the loop's observable behavior across its main branches: simple
//  finish, single + multi-iteration tool use, stall detection, cancel
//  (stream + dispatch), BuildGuard loop, grounding nudge, raw mode, and
//  iteration cap.
//
//  Reuses the ScriptedBackend pattern from AgentLoopHeadlessTests but
//  captures the full LoopEvent stream so we can assert on the exact
//  sequence the loop emits.
//

import XCTest
@testable import AgentCore

// MARK: - Test doubles

/// Minimal `InferenceBackend` that replays scripted chunk lists per turn
/// and records every ChatRequest it receives. Same shape as the one in
/// AgentLoopHeadlessTests; kept here so the event tests are self-contained.
private final class ScriptedBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio

    private let lock = NSLock()
    private var _captured: [ChatRequest] = []
    private let turns: [[ChatChunk]]
    private var turnIndex = 0

    init(turns: [[ChatChunk]]) { self.turns = turns }

    var capturedRequests: [ChatRequest] {
        lock.lock(); defer { lock.unlock() }; return _captured
    }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "test-model", displayName: "Test", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        _captured.append(request)
        let chunks = turns.isEmpty ? [] : turns[min(turnIndex, turns.count - 1)]
        turnIndex += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for c in chunks { continuation.yield(c) }
            continuation.finish()
        }
    }

    func cancel(streamID: UUID) async {}
}

/// Collects LoopEvents into an array for post-hoc assertion. Safe across
/// async boundaries via a lock.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [LoopEvent] = []

    func append(_ e: LoopEvent) {
        lock.lock(); _events.append(e); lock.unlock()
    }
    var events: [LoopEvent] {
        lock.lock(); defer { lock.unlock() }; return _events
    }
    /// Compact human-readable rendering of the event sequence, for
    /// debugging test failures.
    func rendered() -> String {
        events.map(describe).joined(separator: " → ")
    }
}

private func describe(_ e: LoopEvent) -> String {
    switch e {
    case .iterationStarted(let i):     return "iter\(i)"
    case .userMessage:                  return "user"
    case .contentDelta(let s):          return "delta('\(s.prefix(20))')"
    case .assistantMessage:             return "assistant"
    case .toolResult(let inv, let r):   return "toolResult(\(inv.name), err=\(r.isError))"
    case .buildPassed:                  return "buildPassed"
    case .buildFailed:                  return "buildFailed"
    case .buildSkipped:                 return "buildSkipped"
    case .stalled:                      return "stalled"
    case .iterationCapHit(let c):       return "capHit(\(c))"
    case .finished(let r):              return "finished(\(r))"
    case .error(let d):                 return "error(\(d.prefix(30)))"
    case .toolStarted(_, let n, _):    return "toolStarted(\(n))"
    case .toolCompleted(_, let n, _, _): return "toolCompleted(\(n))"
case .reasoningDelta:               return "reasoningDelta"
    case .pendingQuestion:             return "pendingQuestion"
    case .info(let msg):               return "info(\(msg.prefix(30)))"
    case .stepStarted(let i):          return "stepStarted(\(i))"
    case .stepFinished(let i, let s):  return "stepFinished(\(i),\(s ?? ""))"
    case .contextCompacted(_, let n):  return "contextCompacted(\(n))"
}
}

private extension LoopEvent {
    /// True if this event is one of the variants we treat as comparable
    /// in sequence assertions (ignoring associated payload details).
    var kindTag: String {
        switch self {
        case .iterationStarted: return "iterationStarted"
        case .userMessage:      return "userMessage"
        case .contentDelta:     return "contentDelta"
        case .assistantMessage: return "assistantMessage"
        case .toolResult:       return "toolResult"
        case .buildPassed:      return "buildPassed"
        case .buildFailed:      return "buildFailed"
        case .buildSkipped:     return "buildSkipped"
        case .stalled:          return "stalled"
        case .iterationCapHit:  return "iterationCapHit"
        case .finished:         return "finished"
        case .error:            return "error"
        case .toolStarted:      return "toolStarted"
        case .toolCompleted:    return "toolCompleted"
case .reasoningDelta:   return "reasoningDelta"
        case .pendingQuestion:  return "pendingQuestion"
        case .info:             return "info"
        case .stepStarted:      return "stepStarted"
        case .stepFinished:     return "stepFinished"
        case .contextCompacted: return "contextCompacted"
    }
}
}

// MARK: - Tests

final class AgentLoopEventTests: XCTestCase {

    private let model = ModelDescriptor(id: "test-model", displayName: "Test", backend: .lmStudio)

    /// A turn that emits prose and finishes with no tool calls.
    private var finishingTurn: [ChatChunk] {
        [.contentDelta("All done."), .done(finishReason: "stop")]
    }

    /// Drive the loop with the given backend + config and collect events.
    private func drive(
        backend: ScriptedBackend,
        config: AgentLoop.Configuration = .init(verifyEdits: false),
        message: String = "do the thing"
    ) async throws -> (conversation: Conversation, collector: EventCollector) {
        let loop = AgentLoop(backend: backend, model: model, config: config)
        let collector = EventCollector()
        let convo = try await loop.run(userMessage: message,
                                       conversation: Conversation()) { e in
            collector.append(e)
        }
        return (convo, collector)
    }

    /// Assert the event sequence matches the given kind tags (in order).
    /// Extra events of ignored kinds (e.g. contentDelta) are tolerated if
    /// `allowExtraDeltas` is true.
    private func assertSequence(_ collector: EventCollector,
                                expected: [String],
                                allowExtraDeltas: Bool = true,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        let tags = collector.events.map { $0.kindTag }
        if allowExtraDeltas {
            // Strip contentDelta — tests shouldn't be brittle to how many
            // delta chunks a stream emits.
            let filtered = tags.filter { $0 != "contentDelta" }
            XCTAssertEqual(filtered, expected,
                           "Event sequence mismatch.\nExpected: \(expected)\nGot:      \(filtered)\nFull:     \(collector.rendered())",
                           file: file, line: line)
        } else {
            XCTAssertEqual(tags, expected,
                           "Event sequence mismatch.\nFull: \(collector.rendered())",
                           file: file, line: line)
        }
    }

    // MARK: - Simple prose finish

    func testSimpleProseFinishEmitsCanonicalSequence() async throws {
        let backend = ScriptedBackend(turns: [finishingTurn])
        let (convo, collector) = try await drive(backend: backend)

        // user → iter1 → (delta) → assistant → finished
        assertSequence(collector, expected: [
            "userMessage", "iterationStarted", "assistantMessage", "finished"
        ])
        // The conversation has user + assistant messages, no tool messages.
        XCTAssertEqual(convo.messages.count, 2)
        XCTAssertEqual(convo.messages.first?.role, .user)
        XCTAssertEqual(convo.messages.last?.role, .assistant)
    }

    // MARK: - Single tool call → result → prose finish

    func testSingleToolCallThenFinish() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let toolCall: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c1", name: "list_directory",
                           argumentsAppend: "{\"path\": \".\"}"),
            .done(finishReason: "tool_calls")
        ]
        // Turn 1: model calls a tool. Turn 2: model finishes with prose.
        let backend = ScriptedBackend(turns: [toolCall, finishingTurn])
        let (convo, collector) = try await drive(backend: backend)

        // user → iter1 → assistant(with tool) → toolResult → stepFinished → iter2 → assistant → finished
        assertSequence(collector, expected: [
            "userMessage", "iterationStarted", "assistantMessage",
            "toolStarted", "toolCompleted", "toolResult", "stepFinished",
            "iterationStarted", "assistantMessage", "finished"
        ])
        // Conversation has: user, assistant(tool), tool, assistant(prose)
        XCTAssertEqual(convo.messages.count, 4)
        XCTAssertEqual(convo.messages[2].role, .tool)
    }

    // MARK: - Two tool calls in sequence

    func testTwoSequentialToolCalls() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let call1: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c1", name: "list_directory",
                           argumentsAppend: "{\"path\": \".\"}"),
            .done(finishReason: "tool_calls")
        ]
        let call2: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c2", name: "list_directory",
                           argumentsAppend: "{\"path\": \"..\"}"),
            .done(finishReason: "tool_calls")
        ]
        let backend = ScriptedBackend(turns: [call1, call2, finishingTurn])
        let (convo, collector) = try await drive(backend: backend)

        assertSequence(collector, expected: [
            "userMessage", "iterationStarted", "assistantMessage",
            "toolStarted", "toolCompleted", "toolResult", "stepFinished",
            "iterationStarted", "assistantMessage",
            "toolStarted", "toolCompleted", "toolResult", "stepFinished",
            "iterationStarted", "assistantMessage", "finished"
        ])
        XCTAssertEqual(convo.messages.count, 6)
    }

    // MARK: - Index bucketing of tool-call deltas

    func testToolCallDeltasBucketByIndex() async throws {
        await ToolRegistry.shared.registerBuiltins()
        // Split one tool call across multiple fragments with the SAME index.
        // Only the first carries an id; the rest identify by index.
        let part1 = "{\"path\":"
        let part2 = " \".\"}"
        let fragmented: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c1", name: "list_directory", argumentsAppend: part1),
            .toolCallDelta(index: 0, id: nil,  name: nil,             argumentsAppend: part2),
            .done(finishReason: "tool_calls")
        ]
        let backend = ScriptedBackend(turns: [fragmented, finishingTurn])
        let (convo, _) = try await drive(backend: backend)

        // The assistant message should have exactly ONE tool call (not 2).
        let assistantWithTool = convo.messages.first { $0.role == .assistant && !$0.toolCalls.isEmpty }
        XCTAssertNotNil(assistantWithTool)
        XCTAssertEqual(assistantWithTool?.toolCalls.count, 1,
                       "Fragments with the same index must merge into one tool call")
        XCTAssertEqual(assistantWithTool?.toolCalls.first?.id, "c1")
    }

    // MARK: - Stall detection (3 identical tool calls)

    func testStallDetectionFiresAfterThreeIdenticalCalls() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let sameCall: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c1", name: "list_directory",
                           argumentsAppend: "{\"path\": \".\"}"),
            .done(finishReason: "tool_calls")
        ]
        // 3 identical turns in a row trigger stall detection.
        let backend = ScriptedBackend(turns: [sameCall, sameCall, sameCall])
        let (_, collector) = try await drive(
            backend: backend,
            config: .init(stallWindow: 3, verifyEdits: false)
        )

        // The stalled event must appear, and the open tool calls get
        // synthetic error results.
        XCTAssertTrue(collector.events.contains { if case .stalled = $0 { return true }; return false },
                      "Expected a .stalled event.\nFull: \(collector.rendered())")
        // The synthetic results are errors.
        let stalledToolResults = collector.events.filter {
            if case .toolResult(_, let r) = $0 { return r.isError }
            return false
        }
        XCTAssertFalse(stalledToolResults.isEmpty,
                       "Stall should close open tool calls with synthetic error results")
    }

    // MARK: - Iteration cap

    func testIterationCapEmitsCapHitEvent() async throws {
        await ToolRegistry.shared.registerBuiltins()
        // Model never finishes — always calls a tool.
        let foreverCall: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c1", name: "list_directory",
                           argumentsAppend: "{\"path\": \".\"}"),
            .done(finishReason: "tool_calls")
        ]
        let backend = ScriptedBackend(turns: [foreverCall, foreverCall, foreverCall, foreverCall])
        let (_, collector) = try await drive(
            backend: backend,
            config: .init(maxIterations: 2, verifyEdits: false)
        )

        XCTAssertTrue(collector.events.contains { if case .iterationCapHit(let c) = $0 { return c == 2 }; return false },
                      "Expected .iterationCapHit(2).\nFull: \(collector.rendered())")
    }

    // MARK: - Chat mode (rawMode) skips harness scaffolding

    func testChatModeBypassesStallDetection() async throws {
        await ToolRegistry.shared.registerBuiltins()
        // Chat mode only offers web_search + read_file; use read_file (no network).
        let sameCall: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c1", name: "read_file",
                           argumentsAppend: "{\"path\": \"missing-stall-probe.txt\"}"),
            .done(finishReason: "tool_calls")
        ]
        // 5 identical calls would normally stall at 3, but chat mode disables it.
        let backend = ScriptedBackend(turns: [sameCall, sameCall, sameCall, sameCall, finishingTurn])
        let (_, collector) = try await drive(
            backend: backend,
            config: .init(stallWindow: 3, verifyEdits: false, rawMode: true)
        )

        XCTAssertFalse(collector.events.contains { if case .stalled = $0 { return true }; return false },
                       "Chat mode must not stall.\nFull: \(collector.rendered())")
    }

    func testChatModeFinishesWithoutForcingVerification() async throws {
        await ToolRegistry.shared.registerBuiltins()
        // Chat mode must not inject grounding — model decides when done.
        // Use read_file (allowed in chat) rather than delete_file.
        let failedToolCall: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c1", name: "read_file",
                           argumentsAppend: "{\"path\": \"does-not-exist.txt\"}"),
            .done(finishReason: "tool_calls")
        ]
        // Turn 2: model claims success (would normally trigger grounding nudge).
        let claimSuccess: [ChatChunk] = [
            .contentDelta("Done! Successfully read the file."),
            .done(finishReason: "stop")
        ]
        let backend = ScriptedBackend(turns: [failedToolCall, claimSuccess])
        let (_, collector) = try await drive(
            backend: backend,
            config: .init(verifyEdits: false, rawMode: true)
        )
        // Only one finishing event — chat mode didn't force a second pass.
        let finishedCount = collector.events.filter { if case .finished = $0 { return true }; return false }.count
        XCTAssertEqual(finishedCount, 1,
                       "Chat mode should finish after one prose turn, not force re-verification.\nFull: \(collector.rendered())")
    }

    func testChatModeOffersOnlyWebAndReadTools() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let backend = ScriptedBackend(turns: [finishingTurn])
        let (_, _) = try await drive(
            backend: backend,
            config: .init(verifyEdits: false, rawMode: true)
        )
        let tools = backend.capturedRequests.first?.tools ?? []
        let names = Set(tools.map(\.name))
        XCTAssertEqual(names, Set(["web_search", "read_file"]),
                       "Chat mode tools must be web_search + read_file only. Got: \(names.sorted())")
        let systemMsgs = backend.capturedRequests.first?.messages.filter { $0.role == .system } ?? []
        XCTAssertTrue(systemMsgs.isEmpty || systemMsgs.allSatisfy {
            $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }, "Chat mode must not send a harness system prompt")
    }

    // MARK: - Grounding nudge (non-raw mode)

    func testGroundingNudgeForcesReverification() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let failedToolCall: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c1", name: "delete_file",
                           argumentsAppend: "{\"path\": \"does-not-exist.txt\"}"),
            .done(finishReason: "tool_calls")
        ]
        // Turn 2: model claims success WITHOUT hedging — classic confabulation.
        let claimSuccess: [ChatChunk] = [
            .contentDelta("Done! The file was deleted successfully."),
            .done(finishReason: "stop")
        ]
        // Turn 3 (forced by nudge): model re-verifies, then finishes honestly.
        let honestFinish: [ChatChunk] = [
            .contentDelta("Actually, the file didn't exist — the deletion failed."),
            .done(finishReason: "stop")
        ]
        let backend = ScriptedBackend(turns: [failedToolCall, claimSuccess, honestFinish])
        let (_, collector) = try await drive(backend: backend)

        // The loop should run 3 iterations: tool → claim → forced re-verify → finish.
        let iterCount = collector.events.filter { if case .iterationStarted = $0 { return true }; return false }.count
        XCTAssertGreaterThanOrEqual(iterCount, 3,
                                    "Grounding nudge should force an extra iteration.\nFull: \(collector.rendered())")
    }

    // MARK: - Disabled tool is rejected at dispatch

    func testDisabledToolReturnsErrorResult() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let callDisabled: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c1", name: "web_search",
                           argumentsAppend: "{\"query\": \"test\"}"),
            .done(finishReason: "tool_calls")
        ]
        let backend = ScriptedBackend(turns: [callDisabled, finishingTurn])
        let (_, collector) = try await drive(
            backend: backend,
            config: .init(verifyEdits: false, disabledToolNames: ["web_search"])
        )

        let webResults = collector.events.filter {
            if case .toolResult(let inv, let r) = $0 { return inv.name == "web_search" && r.isError }
            return false
        }
        XCTAssertFalse(webResults.isEmpty,
                       "Disabled tool should produce an error tool result.\nFull: \(collector.rendered())")
    }

    // MARK: - Inline JSON tool calls (no native tool_calls deltas)

    func testInlineJSONArrayToolCallsAreDispatched() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let inlineJSON = """
        [
          {"tool": "list_directory", "path": "."}
        ]
        """
        let inlineTurn: [ChatChunk] = [
            .contentDelta(inlineJSON),
            .done(finishReason: "stop")
        ]
        let backend = ScriptedBackend(turns: [inlineTurn, finishingTurn])
        let (convo, collector) = try await drive(backend: backend)

        assertSequence(collector, expected: [
            "userMessage", "iterationStarted", "assistantMessage",
            "toolStarted", "toolCompleted", "toolResult", "stepFinished",
            "iterationStarted", "assistantMessage", "finished"
        ])
        let assistantWithTool = convo.messages.first {
            $0.role == .assistant && !$0.toolCalls.isEmpty
        }
        XCTAssertNotNil(assistantWithTool)
        XCTAssertEqual(assistantWithTool?.toolCalls.first?.name, "list_directory")
        XCTAssertTrue(assistantWithTool?.content.isEmpty ?? false,
                      "Inline JSON markup should be stripped from assistant content")
        XCTAssertEqual(convo.messages.first(where: { $0.role == .tool })?.role, .tool)
    }

    // MARK: - System prompt contains editing rules (non-raw) and excludes them (raw)

    func testSystemPromptHasEditingRulesByDefault() async throws {
        let backend = ScriptedBackend(turns: [finishingTurn])
        let (_, _) = try await drive(backend: backend)
        let systemPrompt = backend.capturedRequests.first?.messages
            .first(where: { $0.role == .system })?.content ?? ""
        XCTAssertTrue(systemPrompt.contains("edit_file"),
                      "Non-raw system prompt should teach edit_file as primary edit tool")
    }

    func testChatModeSystemPromptOmitsHarnessRules() async throws {
        let backend = ScriptedBackend(turns: [finishingTurn])
        let (_, _) = try await drive(
            backend: backend,
            config: .init(verifyEdits: false, rawMode: true)
        )
        // Empty compose: no system message on the wire (or empty if present).
        let systemPrompt = backend.capturedRequests.first?.messages
            .first(where: { $0.role == .system })?.content ?? ""
        XCTAssertFalse(systemPrompt.contains("Editing rules"),
                       "Chat mode system prompt must omit harness rules.\nGot: \(systemPrompt)")
        XCTAssertTrue(systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "Chat mode should have an empty system prompt.\nGot: \(systemPrompt)")
    }
}
