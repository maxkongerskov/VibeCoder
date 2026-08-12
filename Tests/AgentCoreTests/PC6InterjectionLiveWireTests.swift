//
//  PC6InterjectionLiveWireTests.swift
//
//  Phase C PC6 — mid-turn interjection live wire: buffer + loop drain
//  (including natural-finish path with no tool calls).
//

import XCTest
@testable import AgentCore

final class PC6InterjectionLiveWireTests: XCTestCase {

    // MARK: - Buffer

    func testEnqueueDrainFIFOAndEmpties() async {
        let id = UUID()
        await InterjectionBuffer.shared.clear(conversationId: id)
        let ok1 = await InterjectionBuffer.shared.enqueue(
            conversationId: id, text: "one", expectedEpoch: nil)
        let ok2 = await InterjectionBuffer.shared.enqueue(
            conversationId: id, text: "two", expectedEpoch: nil)
        XCTAssertTrue(ok1)
        XCTAssertTrue(ok2)
        let peek2 = await InterjectionBuffer.shared.peekCount(conversationId: id)
        XCTAssertEqual(peek2, 2)

        let drained = await InterjectionBuffer.shared.drain(conversationId: id)
        XCTAssertEqual(drained, ["one", "two"])
        let peek0 = await InterjectionBuffer.shared.peekCount(conversationId: id)
        XCTAssertEqual(peek0, 0)
        let empty = await InterjectionBuffer.shared.drain(conversationId: id)
        XCTAssertTrue(empty.isEmpty)
        await InterjectionBuffer.shared.clear(conversationId: id)
    }

    func testEpochRejectsStaleEnqueueAfterClear() async {
        let id = UUID()
        await InterjectionBuffer.shared.clear(conversationId: id)
        let epoch = await InterjectionBuffer.shared.currentEpoch(conversationId: id)
        await InterjectionBuffer.shared.clear(conversationId: id) // bump
        let accepted = await InterjectionBuffer.shared.enqueue(
            conversationId: id, text: "late", expectedEpoch: epoch)
        XCTAssertFalse(accepted)
        let n = await InterjectionBuffer.shared.peekCount(conversationId: id)
        XCTAssertEqual(n, 0)
        await InterjectionBuffer.shared.clear(conversationId: id)
    }

    // MARK: - Loop drain

    private final class ScriptedBackend: InferenceBackend, @unchecked Sendable {
        let identifier: BackendIdentifier = .lmStudio
        private let lock = NSLock()
        private let turns: [[ChatChunk]]
        private var turnIndex = 0
        /// Called once when the first model stream is opened (before chunks).
        var onFirstStreamOpen: (@Sendable () async -> Void)?

        init(turns: [[ChatChunk]]) { self.turns = turns }

        func listModels() async throws -> [ModelDescriptor] { [] }

        func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
            lock.lock()
            let idx = turnIndex
            let chunks = turns.isEmpty ? [] : turns[min(turnIndex, turns.count - 1)]
            turnIndex += 1
            let hook = onFirstStreamOpen
            lock.unlock()
            return AsyncThrowingStream { cont in
                Task {
                    // Enqueue mid-turn before the model "finishes" so the
                    // natural-finish drain path can observe pending steers.
                    if idx == 0, let hook {
                        await hook()
                    }
                    for c in chunks { cont.yield(c) }
                    cont.finish()
                }
            }
        }

        func cancel(streamID: UUID) async {}
    }

    /// Steers enqueued while the model streams a no-tool final answer must
    /// still land in the transcript (PC6 natural-finish drain).
    func testInterjectionDuringNoToolFinishContinuesAndInjects() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let model = ModelDescriptor(id: "t", displayName: "t", backend: .lmStudio)
        let convoID = UUID()
        let convo = Conversation(id: convoID, projectRoot: FileManager.default.temporaryDirectory)

        // First response: content only (natural finish path).
        // Second response: after steer is injected, model stops again.
        let turns: [[ChatChunk]] = [
            [.contentDelta("draft answer"), .done(finishReason: "stop")],
            [.contentDelta("revised with steer"), .done(finishReason: "stop")],
        ]
        let backend = ScriptedBackend(turns: turns)
        backend.onFirstStreamOpen = {
            _ = await InterjectionBuffer.shared.enqueue(
                conversationId: convoID, text: "prefer short answer")
        }
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(verifyEdits: false, dreamEnabled: false))

        let final = try await loop.run(
            userMessage: "write something",
            conversation: convo) { _ in }

        let steerMsgs = final.messages.filter {
            $0.role == .user && $0.content.contains("prefer short answer")
        }
        XCTAssertFalse(
            steerMsgs.isEmpty,
            "natural-finish path must inject interjection; got \(final.messages.map { "\($0.role):\($0.content.prefix(50))" })")

        // Model should have been re-invoked after the steer.
        let assistants = final.messages.filter { $0.role == .assistant }
        XCTAssertTrue(
            assistants.contains { $0.content.contains("revised with steer") }
                || assistants.count >= 2,
            "expected a second model response after steer; assistants=\(assistants.map(\.content))"
        )
        await InterjectionBuffer.shared.clear(conversationId: convoID)
    }

    /// Pre-seeded buffer is drained at iteration start into transcript.
    func testIterationStartDrainInjectsUserMessage() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let model = ModelDescriptor(id: "t2", displayName: "t2", backend: .lmStudio)
        let convoID = UUID()
        let convo = Conversation(id: convoID, projectRoot: FileManager.default.temporaryDirectory)

        _ = await InterjectionBuffer.shared.enqueue(
            conversationId: convoID, text: "preseeded steer")

        let backend = ScriptedBackend(turns: [
            [.contentDelta("ok"), .done(finishReason: "stop")],
        ])
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(verifyEdits: false, dreamEnabled: false))

        let final = try await loop.run(
            userMessage: "hi",
            conversation: convo) { _ in }

        let steers = final.messages.filter {
            $0.role == .user && $0.content.contains("preseeded steer")
        }
        XCTAssertEqual(steers.count, 1)
        let left = await InterjectionBuffer.shared.peekCount(conversationId: convoID)
        XCTAssertEqual(left, 0)
        await InterjectionBuffer.shared.clear(conversationId: convoID)
    }
}
