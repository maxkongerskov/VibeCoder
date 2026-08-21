//
//  AgentLoopCancelPersistTests.swift
//
//  A4: cancel mid-tool → ConversationStore.load → every tool_calls id
//  has a tool result. Mirrors ChatViewModel's success-path persist
//  (`ConversationStore.save` of the loop's returned Conversation).
//

import XCTest
@testable import AgentCore

private final class CancelPersistBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let turns: [[ChatChunk]]
    private var turnIndex = 0
    private let lock = NSLock()

    init(turns: [[ChatChunk]]) { self.turns = turns }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "a4", displayName: "A4", backend: .lmStudio)]
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

final class AgentLoopCancelPersistTests: XCTestCase {

    private let hangName = "hang_a4_persist"

    override func tearDown() async throws {
        await ToolRegistry.shared.unregisterDynamicTools(names: [hangName])
    }

    /// Host path: AgentLoop returns a conversation; ChatViewModel saves it.
    /// Cancel while a serial mutator is in flight; remaining tools must be
    /// closed before save. Reload must have no dangling tool_calls ids.
    func testCancelMidToolPersistsPairedTranscript() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let hang = HangGate()
        let meta = ToolRegistry.ToolMetadata(
            name: hangName,
            category: .debug,
            permission: .mutates,
            availability: .core,
            schema: ToolSchema(
                name: hangName,
                description: "Parks until cancelled (A4 persist test).",
                parameters: .init(properties: [:], required: [])
            )
        )
        await ToolRegistry.shared.registerDynamicTool(metadata: meta) { _, _ in
            await hang.markStarted()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return ToolResult(content: "hang should not finish", isError: true)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("a4-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = dir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = ConversationStore(directory: dir.appendingPathComponent("conversations", isDirectory: true))

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
        let backend = CancelPersistBackend(turns: [toolTurn])
        let loop = AgentLoop(
            backend: backend,
            model: ModelDescriptor(id: "a4", displayName: "A4", backend: .lmStudio),
            config: .init(maxIterations: 8, verifyEdits: false, dreamEnabled: false)
        )
        var seed = Conversation(title: "a4-cancel", projectRoot: project)
        seed.messages.append(ChatMessage(role: .user, content: "prior"))

        let started = expectation(description: "hang tool entered execute")
        Task {
            await hang.waitStarted()
            started.fulfill()
        }
        let run = Task {
            try await loop.run(userMessage: "hang then list", conversation: seed) { _ in }
        }
        await fulfillment(of: [started], timeout: 2.0)
        run.cancel()
        let returned = try await run.value

        try await store.save(returned)
        let loaded = try await store.load(id: returned.id)
        XCTAssertNotNil(loaded, "cancelled turn must round-trip through ConversationStore")
        let messages = loaded!.messages

        XCTAssertTrue(
            ChatLoop.toolCallPairingIsValid(in: messages),
            "unclosed=\(ChatLoop.unclosedToolCallIDs(in: messages)) unpaired=\(ChatLoop.unpairedToolResultIDs(in: messages))"
        )
        XCTAssertTrue(
            ChatLoop.unclosedToolCallIDs(in: messages).isEmpty,
            "dangling tool_calls after cancel persist: \(ChatLoop.unclosedToolCallIDs(in: messages))"
        )
        let assistantCalls = messages
            .filter { $0.role == .assistant }
            .flatMap(\.toolCalls)
        XCTAssertTrue(
            assistantCalls.contains(where: { $0.id == hangID }),
            "expected hang tool_call on assistant message"
        )
        XCTAssertTrue(
            assistantCalls.contains(where: { $0.id == leftoverID }),
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
