//
//  ToolCallPairingTests.swift
//  Wave C W01 — ChatLoop pairing helpers + stall finished event.
//

import XCTest
@testable import AgentCore

final class ToolCallPairingTests: XCTestCase {

    func testUnpairedOrphanToolResultDetected() {
        let messages: [ChatMessage] = [
            .init(role: .assistant, content: "hi"),
            .init(role: .tool, content: "orphan", toolCallID: "ghost"),
        ]
        XCTAssertEqual(ChatLoop.unpairedToolResultIDs(in: messages), ["ghost"])
        XCTAssertFalse(ChatLoop.toolCallPairingIsValid(in: messages))
    }

    func testUnclosedToolCallDetected() {
        let call = ToolCallInvocation(id: "c1", name: "read_file", arguments: "{}")
        let messages: [ChatMessage] = [
            .init(role: .assistant, content: "", toolCalls: [call]),
        ]
        XCTAssertEqual(ChatLoop.unclosedToolCallIDs(in: messages), ["c1"])
        XCTAssertFalse(ChatLoop.toolCallPairingIsValid(in: messages))
    }

    func testPairedTranscriptIsValid() {
        let call = ToolCallInvocation(id: "c1", name: "read_file", arguments: "{}")
        let messages: [ChatMessage] = [
            .init(role: .assistant, content: "", toolCalls: [call]),
            .init(role: .tool, content: "ok", toolCallID: "c1"),
        ]
        XCTAssertTrue(ChatLoop.unpairedToolResultIDs(in: messages).isEmpty)
        XCTAssertTrue(ChatLoop.unclosedToolCallIDs(in: messages).isEmpty)
        XCTAssertTrue(ChatLoop.toolCallPairingIsValid(in: messages))
    }

    func testCloseToolCallsMakesPairingValid() {
        var messages: [ChatMessage] = [
            .init(role: .assistant, content: "", toolCalls: [
                ToolCallInvocation(id: "a", name: "list_directory", arguments: "{}"),
                ToolCallInvocation(id: "b", name: "glob_files", arguments: "{}"),
            ]),
        ]
        XCTAssertFalse(ChatLoop.toolCallPairingIsValid(in: messages))
        for id in ["a", "b"] {
            messages.append(.init(role: .tool, content: "Skipped: stall", toolCallID: id))
        }
        XCTAssertTrue(ChatLoop.toolCallPairingIsValid(in: messages))
    }
}

// MARK: - AgentEvent toolFinished id fidelity (C2 O6)

final class AgentEventToolFinishedIDTests: XCTestCase {
    func testToolCompletedMapsToolFinishedWithId() {
        let events = AgentEvent.from(
            .toolCompleted(id: "call_42", name: "read_file", label: "Reading…", isError: false))
        guard case .toolFinished(let id, let name, _, let isError) = events.first else {
            return XCTFail("expected toolFinished, got \(events)")
        }
        XCTAssertEqual(id, "call_42")
        XCTAssertEqual(name, "read_file")
        XCTAssertFalse(isError)
    }
}

// MARK: - Mid-dispatch interjection drain (C2 O2)

final class AgentLoopMidDispatchInterjectionTests: XCTestCase {
    private final class ScriptedBackend: InferenceBackend, @unchecked Sendable {
        let identifier: BackendIdentifier = .lmStudio
        private let lock = NSLock()
        private let turns: [[ChatChunk]]
        private var turnIndex = 0
        init(turns: [[ChatChunk]]) { self.turns = turns }
        func listModels() async throws -> [ModelDescriptor] { [] }
        func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
            lock.lock()
            let chunks = turns.isEmpty ? [] : turns[min(turnIndex, turns.count - 1)]
            turnIndex += 1
            lock.unlock()
            return AsyncThrowingStream { cont in
                for c in chunks { cont.yield(c) }
                cont.finish()
            }
        }
        func cancel(streamID: UUID) async {}
    }

    /// Interjections must appear in the transcript after the tool batch
    /// (never mid-pairing). Pre-seed buffer so the post-batch drain sees it.
    func testInterjectionEnqueuedDuringToolAppearsInTranscript() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let model = ModelDescriptor(id: "t", displayName: "t", backend: .lmStudio)
        let convoID = UUID()
        var convo = Conversation(id: convoID, projectRoot: FileManager.default.temporaryDirectory)
        let toolThenFinish: [[ChatChunk]] = [
            [
                .toolCallDelta(index: 0, id: "c1", name: "list_directory",
                               argumentsAppend: #"{"path":"."}"#),
                .done(finishReason: "tool_calls"),
            ],
            [.contentDelta("ok"), .done(finishReason: "stop")],
        ]
        let backend = ScriptedBackend(turns: toolThenFinish)
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(verifyEdits: false, dreamEnabled: false))

        // Seed before run — AgentLoop applies after tool batch (pairing-safe),
        // not mid-dispatch between tool results.
        _ = await InterjectionBuffer.shared.enqueue(
            conversationId: convoID, text: "prefer list only")

        let final = try await loop.run(
            userMessage: "look around",
            conversation: convo) { _ in }

        let userSteer = final.messages.filter {
            $0.role == .user && $0.content.contains("prefer list only")
        }
        XCTAssertFalse(userSteer.isEmpty,
                       "interjection must land in transcript; messages=\(final.messages.map { "\($0.role):\($0.content.prefix(40))" })")
        // No user message may sit between consecutive .tool results.
        for i in 0..<(final.messages.count - 2) {
            if final.messages[i].role == .tool,
               final.messages[i + 1].role == .user,
               final.messages[i + 2].role == .tool {
                XCTFail("user message interleaved between tool results at index \(i + 1)")
            }
        }
        await InterjectionBuffer.shared.clear(conversationId: convoID)
    }
}

// MARK: - Stall emits finished

final class AgentLoopStallFinishedTests: XCTestCase {

    private final class ScriptedBackend: InferenceBackend, @unchecked Sendable {
        let identifier: BackendIdentifier = .lmStudio
        private let lock = NSLock()
        private let turns: [[ChatChunk]]
        private var turnIndex = 0

        init(turns: [[ChatChunk]]) { self.turns = turns }

        func listModels() async throws -> [ModelDescriptor] { [] }

        func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
            lock.lock()
            let chunks = turns.isEmpty ? [] : turns[min(turnIndex, turns.count - 1)]
            turnIndex += 1
            lock.unlock()
            return AsyncThrowingStream { cont in
                for c in chunks { cont.yield(c) }
                cont.finish()
            }
        }

        func cancel(streamID: UUID) async {}
    }

    func testStallEmitsFinishedWithReason() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let sameCall: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c1", name: "list_directory",
                           argumentsAppend: #"{"path":"."}"#),
            .done(finishReason: "tool_calls"),
        ]
        let backend = ScriptedBackend(turns: [sameCall, sameCall, sameCall])
        let model = ModelDescriptor(id: "t", displayName: "t", backend: .lmStudio)
        var finishedReasons: [String] = []
        var sawStalled = false
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(stallWindow: 3, verifyEdits: false, dreamEnabled: false))
        let convo = try await loop.run(
            userMessage: "loop",
            conversation: Conversation()) { event in
            if case .stalled = event { sawStalled = true }
            if case .finished(let r) = event { finishedReasons.append(r) }
        }
        XCTAssertTrue(sawStalled, "stall event required")
        XCTAssertFalse(finishedReasons.isEmpty, "stall must emit .finished (not silent break)")
        XCTAssertTrue(
            finishedReasons.contains { $0.hasPrefix("stalled") || $0.contains("stall") },
            "finished reason should mention stall: \(finishedReasons)")
        XCTAssertTrue(ChatLoop.toolCallPairingIsValid(in: convo.messages),
                      "stall closeToolCalls must pair: unclosed=\(ChatLoop.unclosedToolCallIDs(in: convo.messages))")
    }

    func testIterationCapEmitsFinished() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let forever: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c1", name: "list_directory",
                           argumentsAppend: #"{"path":"."}"#),
            .done(finishReason: "tool_calls"),
        ]
        let backend = ScriptedBackend(turns: [forever, forever, forever, forever])
        let model = ModelDescriptor(id: "t", displayName: "t", backend: .lmStudio)
        var finishedReasons: [String] = []
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(maxIterations: 2, verifyEdits: false, dreamEnabled: false))
        _ = try await loop.run(userMessage: "cap", conversation: Conversation()) { event in
            if case .finished(let r) = event { finishedReasons.append(r) }
        }
        XCTAssertTrue(
            finishedReasons.contains {
                $0.contains("iteration cap") || $0.contains("iteration limit")
            },
            "cap must emit finished: \(finishedReasons)")
    }
}
