//
//  CLICancelTests.swift
//  C3: SIGINT during a turn cancels AgentLoop (Task.cancel) and the
//  partial conversation persists with paired tool_calls — same contract
//  as AgentLoopCancelPersistTests.testCancelMidToolPersistsPairedTranscript.
//

import XCTest
import Darwin
import AgentCore
@testable import VibeCoderCLILib

private final class CLICancelBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let turns: [[ChatChunk]]
    private var turnIndex = 0
    private let lock = NSLock()

    init(turns: [[ChatChunk]]) { self.turns = turns }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "c3", displayName: "C3", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        let chunks: [ChatChunk]
        if turnIndex < turns.count {
            chunks = turns[turnIndex]
        } else {
            chunks = [.contentDelta("done"), .done(finishReason: "stop")]
        }
        turnIndex += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for c in chunks { continuation.yield(c) }
            continuation.finish()
        }
    }

    func cancel(streamID: UUID) async {}
}

private actor HangGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.resume() }
    }

    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

final class CLICancelTests: XCTestCase {

    private let hangName = "hang_c3_cli_cancel"

    override func tearDown() async throws {
        await ToolRegistry.shared.unregisterDynamicTools(names: [hangName])
    }

    func testCancelMidToolPersistsPairedTranscript() async throws {
        let returned = try await runHangTurn { handle, started in
            await fulfillment(of: [started], timeout: 2.0)
            handle.cancel()
        }
        try await assertPairedPersist(returned)
    }

    func testSIGINTMapsToTurnCancelAndPersistsPairedTranscript() async throws {
        // runTurn arms SIGINT → TurnCancelHandle.cancel() for the duration
        // of the hang. raise(SIGINT) must unwind the same as handle.cancel().
        let returned = try await runHangTurn { _, started in
            await fulfillment(of: [started], timeout: 2.0)
            raise(SIGINT)
        }
        try await assertPairedPersist(returned)
    }

    func testSIGINTHandlerCancelsAttachedTask() async throws {
        let handle = TurnCancelHandle()
        let session = TurnSIGINT.install(cancelling: handle)
        defer { session.restore() }

        let task = Task<Conversation, Error> {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return Conversation(title: "should-cancel")
        }
        handle.attach(task)
        session.deliverForTesting()
        let result = await task.result
        guard case .failure(let error) = result else {
            return XCTFail("SIGINT mapping must cancel the attached Task")
        }
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
    }

    func testFirstSIGINTRestoresDefaultDisposition() {
        let previous = signal(SIGINT, SIG_DFL)
        defer { signal(SIGINT, previous) }

        let handle = TurnCancelHandle()
        let session = TurnSIGINT.install(cancelling: handle)
        session.deliverForTesting()
        session.restore()

        let after = signal(SIGINT, SIG_DFL)
        XCTAssertEqual(
            unsafeBitCast(after, to: Int.self),
            unsafeBitCast(SIG_DFL as (@convention(c) (Int32) -> Void)?, to: Int.self),
            "first SIGINT must restore default disposition so a second Ctrl+C exits"
        )
    }

    // MARK: - Helpers

    private func runHangTurn(
        cancelAfterStart: (TurnCancelHandle, XCTestExpectation) async -> Void
    ) async throws -> Conversation {
        await ToolRegistry.shared.registerBuiltins()
        let hang = HangGate()
        let meta = ToolRegistry.ToolMetadata(
            name: hangName,
            category: .debug,
            permission: .mutates,
            availability: .core,
            schema: ToolSchema(
                name: hangName,
                description: "Parks until cancelled (C3 persist test).",
                parameters: .init(properties: [:], required: [])
            )
        )
        await ToolRegistry.shared.registerDynamicTool(metadata: meta) { _, _ in
            await hang.markStarted()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return ToolResult(content: "hang should not finish", isError: true)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c3-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let hangID = "hang1"
        let leftoverID = "left2"
        let toolTurn: [ChatChunk] = [
            .toolCallDelta(
                index: 0, id: hangID, name: hangName, argumentsAppend: "{}"),
            .toolCallDelta(
                index: 1, id: leftoverID, name: "list_directory",
                argumentsAppend: #"{"path":"."}"#),
            .done(finishReason: "tool_calls"),
        ]
        let backend = CLICancelBackend(turns: [toolTurn])
        var settings = AppSettings()
        settings.verifyEdits = false
        settings.dreamEnabled = false
        settings.memoryEnabled = false
        settings.injectProjectMemory = false
        var runner = TurnRunner(
            backend: backend,
            model: ModelDescriptor(id: "c3", displayName: "C3", backend: .lmStudio),
            settings: settings,
            maxIterations: 8
        )
        runner.shellApprovalCoordinator = ShellApprovalReviewer { _ in .once }
        runner.patchReviewer = PatchReviewer { _ in .acceptAll }

        var seed = Conversation(title: "c3-cancel", projectRoot: project)
        seed.messages.append(ChatMessage(role: .user, content: "prior"))

        let started = expectation(description: "hang tool entered execute")
        Task {
            await hang.waitStarted()
            started.fulfill()
        }
        let handle = TurnCancelHandle()
        // Snapshot vars: Swift 5.10 on GHA rejects capturing `var` in Task.
        let turnRunner = runner
        let conversation = seed
        let run = Task {
            try await turnRunner.runTurn(
                userMessage: "hang then list",
                conversation: conversation,
                cancel: handle
            )
        }
        await cancelAfterStart(handle, started)
        return try await run.value
    }

    private func assertPairedPersist(_ returned: Conversation) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c3-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationStore(directory: dir)
        try await store.save(returned)
        let loaded = try await store.load(id: returned.id)
        guard let loaded else {
            return XCTFail("cancelled turn must round-trip through ConversationStore")
        }
        let messages = loaded.messages

        XCTAssertTrue(
            ChatLoop.toolCallPairingIsValid(in: messages),
            "unclosed=\(ChatLoop.unclosedToolCallIDs(in: messages))"
        )
        XCTAssertTrue(
            ChatLoop.unclosedToolCallIDs(in: messages).isEmpty,
            "dangling tool_calls after cancel persist: \(ChatLoop.unclosedToolCallIDs(in: messages))"
        )
        let assistantCalls = messages
            .filter { $0.role == .assistant }
            .flatMap(\.toolCalls)
        XCTAssertTrue(
            assistantCalls.contains(where: { $0.id == "hang1" }),
            "expected hang tool_call on assistant message"
        )
        XCTAssertTrue(
            assistantCalls.contains(where: { $0.id == "left2" }),
            "expected leftover tool_call on assistant message"
        )
        let resultIDs = Set(messages.filter { $0.role == .tool }.compactMap(\.toolCallID))
        for inv in assistantCalls {
            XCTAssertTrue(
                resultIDs.contains(inv.id),
                "tool_calls id \(inv.id) (\(inv.name)) has no tool result after cancel+load"
            )
        }
    }
}
