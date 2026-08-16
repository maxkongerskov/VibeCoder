//
//  ParityLoopIntegrationTests.swift
//  Wave-2 loop: reactive overflow retry, stop-hook continuation,
//  wire-only micro-compact.
//

import XCTest
@testable import AgentCore

private enum ScriptedStream: Sendable {
    case chunks([ChatChunk])
    case failure(Error)
}

/// PC5-style scripted backend that can throw on a turn (overflow retry).
private final class ParityLoopScriptedBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let turns: [ScriptedStream]
    private var turnIndex = 0
    private let lock = NSLock()
    private(set) var streamAttempts = 0
    private var _captured: [ChatRequest] = []

    init(turns: [ScriptedStream]) { self.turns = turns }

    var capturedRequests: [ChatRequest] {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "parity-loop", displayName: "Parity Loop", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        streamAttempts += 1
        _captured.append(request)
        let idx = turnIndex
        turnIndex += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            guard idx < turns.count else {
                continuation.yield(.contentDelta("done"))
                continuation.yield(.done(finishReason: "stop"))
                continuation.finish()
                return
            }
            switch turns[idx] {
            case .chunks(let chunks):
                for c in chunks { continuation.yield(c) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    func cancel(streamID: UUID) async {}
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LoopEvent] = []

    func append(_ event: LoopEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    var finishedReason: String? {
        lock.lock(); defer { lock.unlock() }
        for e in events {
            if case .finished(let reason) = e { return reason }
        }
        return nil
    }

    var sawError: Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains {
            if case .error = $0 { return true }
            return false
        }
    }
}

final class ParityLoopIntegrationTests: XCTestCase {

    private var model: ModelDescriptor {
        ModelDescriptor(id: "parity-loop", displayName: "Parity Loop", backend: .lmStudio)
    }

    private func loopConfig() -> AgentLoop.Configuration {
        .init(
            maxIterations: 6,
            verifyEdits: false,
            memoryEnabled: false,
            dreamEnabled: false)
    }

    // MARK: - Reactive overflow retry

    func testContextOverflowRetriesOnceThenFinishes() async throws {
        let overflow = BackendError.http(
            status: 400,
            body: "context_length_exceeded: prompt too large")
        let backend = ParityLoopScriptedBackend(turns: [
            .failure(overflow),
            .chunks([
                .contentDelta("ok after compact"),
                .done(finishReason: "stop"),
            ]),
        ])
        let loop = AgentLoop(backend: backend, model: model, config: loopConfig())
        var convo = Conversation()
        convo.messages.append(ChatMessage(role: .user, content: "prior"))

        let events = EventBox()
        let result = try await loop.run(
            userMessage: "continue",
            conversation: convo
        ) { event in
            events.append(event)
        }

        XCTAssertEqual(backend.streamAttempts, 2, "classifier must retry the same model step once")
        XCTAssertEqual(events.finishedReason, "stop")
        XCTAssertTrue(
            result.messages.contains(where: {
                $0.role == .assistant && $0.content.contains("ok after compact")
            }),
            "retry should land a finished assistant turn")
    }

    func testSecondOverflowAfterRetryFailsTheTurn() async throws {
        let overflow = BackendError.http(
            status: 400,
            body: "context_length_exceeded")
        let backend = ParityLoopScriptedBackend(turns: [
            .failure(overflow),
            .failure(overflow),
        ])
        let loop = AgentLoop(backend: backend, model: model, config: loopConfig())
        var convo = Conversation()
        convo.messages.append(ChatMessage(role: .user, content: "prior"))

        let events = EventBox()
        do {
            _ = try await loop.run(
                userMessage: "too big",
                conversation: convo
            ) { event in
                events.append(event)
            }
            XCTFail("second consecutive overflow should throw")
        } catch {
            XCTAssertTrue(
                ContextOverflowClassifier.isContextExceeded(error: error),
                "thrown error should still classify as overflow")
        }
        XCTAssertEqual(backend.streamAttempts, 2)
        XCTAssertTrue(events.sawError)
    }

    func testRapidRefillBreakerTripsAtThreeConsecutiveCompacts() {
        var breaker = RapidRefillBreaker()
        XCTAssertFalse(breaker.shouldHardStop())
        breaker.recordCompact()
        XCTAssertFalse(breaker.shouldHardStop())
        breaker.recordCompact()
        XCTAssertTrue(
            breaker.shouldHardStop(),
            "loop hard-stops when the next compact would be the 3rd rapid one")
    }

    // MARK: - Stop-hook continuation

    func testStopHookContinueInjectsContextAndTakesAnotherStep() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-loop-stop-\(UUID().uuidString)", isDirectory: true)
        let hooks = root.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = hooks.appendingPathComponent("stop-once.sh")
        try """
        #!/bin/sh
        ONCE="\(hooks.path)/continued"
        if [ -f "$ONCE" ]; then
          echo '{}'
          exit 0
        fi
        touch "$ONCE"
        echo '{"continue":true,"additionalContext":"run the test suite"}'
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        let config: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "stop-once.sh", "timeout": 5]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let finish: [ChatChunk] = [
            .contentDelta("natural stop"),
            .done(finishReason: "stop"),
        ]
        let backend = ParityLoopScriptedBackend(turns: [
            .chunks(finish),
            .chunks([
                .contentDelta("after hook"),
                .done(finishReason: "stop"),
            ]),
        ])
        let loop = AgentLoop(backend: backend, model: model, config: loopConfig())
        var convo = Conversation(projectRoot: root)
        convo.messages.append(ChatMessage(role: .user, content: "prior"))

        let result = try await loop.run(
            userMessage: "hi",
            conversation: convo
        ) { _ in }

        XCTAssertEqual(backend.streamAttempts, 2, "Stop continue must take another model step")
        XCTAssertTrue(
            result.messages.contains(where: {
                $0.role == .user && $0.content.contains("run the test suite")
            }),
            "hook additionalContext should be injected as a user/system-reminder")
        XCTAssertTrue(
            result.messages.contains(where: {
                $0.role == .assistant && $0.content.contains("after hook")
            }))
    }

    // MARK: - Micro-compact (wire only)

    func testMicroCompactClearsWireCopyButNotPersistedHistory() async throws {
        var convo = Conversation()
        convo.messages.append(ChatMessage(role: .user, content: "seed"))
        for i in 0..<8 {
            let id = "call-\(i)"
            convo.messages.append(ChatMessage(
                role: .assistant,
                content: "read \(i)",
                toolCalls: [ToolCallInvocation(
                    id: id, name: "read_file",
                    arguments: #"{"path":"/f\#(i).swift"}"#)]))
            convo.messages.append(ChatMessage(
                role: .tool,
                content: "BODY-\(i)-" + String(repeating: "x", count: 80),
                toolCallID: id))
        }

        let backend = ParityLoopScriptedBackend(turns: [
            .chunks([.contentDelta("done"), .done(finishReason: "stop")]),
        ])
        let loop = AgentLoop(backend: backend, model: model, config: loopConfig())
        let result = try await loop.run(
            userMessage: "wrap up",
            conversation: convo
        ) { _ in }

        XCTAssertEqual(backend.streamAttempts, 1)
        let persistedTools = result.messages.filter { $0.role == .tool }
        XCTAssertTrue(
            persistedTools.contains { $0.content.hasPrefix("BODY-0-") },
            "persisted convo must keep full tool bodies")
        XCTAssertFalse(
            persistedTools.contains { MicroCompactor.isClearedToolResult($0.content) },
            "micro-compact must not persist")

        let wire = backend.capturedRequests.first?.messages ?? []
        let wireTools = wire.filter { $0.role == .tool }
        XCTAssertTrue(
            wireTools.contains { MicroCompactor.isClearedToolResult($0.content) },
            "wire copy should clear old compactable tool bodies")
        XCTAssertTrue(
            wireTools.contains { $0.content.hasPrefix("BODY-") },
            "recent keep-window tool bodies stay verbatim on the wire")
    }
}
