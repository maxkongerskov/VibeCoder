//
//  EditVerifyTests.swift
//
//  Regression: exploratory read-only tools must not satisfy post-edit verification.
//

import XCTest
@testable import AgentCore

// MARK: - AgentLoop integration doubles

private final class EditVerifyScriptedBackend: InferenceBackend, @unchecked Sendable {
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

private final class FinishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}

final class EditVerifyTests: XCTestCase {

    private let sampleMutating: Set<String> = [
        "write_file", "edit_file", "apply_patch",
    ]

    private func msg(_ role: ChatMessage.Role, _ content: String,
                     calls: [ToolCallInvocation] = []) -> ChatMessage {
        ChatMessage(role: role, content: content, toolCalls: calls)
    }

    private func toolMsg(_ content: String, id: String = "t1") -> ChatMessage {
        ChatMessage(role: .tool, content: content, toolCallID: id)
    }

    func testListDirectoryAfterEditDoesNotSatisfyVerification() async {
        await ToolRegistry.shared.registerBuiltins()
        let classification = await ToolClassification.load(
            registry: .shared, xcodeMCPEnabled: false)
        XCTAssertFalse(classification.verification.contains("list_directory"))

        let messages: [ChatMessage] = [
            msg(.user, "fix it"),
            msg(.assistant, "", calls: [.init(id: "e1", name: "write_file", arguments: "{}")]),
            toolMsg("Wrote 10 bytes", id: "e1"),
            msg(.assistant, "", calls: [.init(id: "l1", name: "list_directory", arguments: "{}")]),
            toolMsg(".\nREADME.md", id: "l1"),
            msg(.assistant, "All done!"),
        ]
        XCTAssertFalse(ChatLoop.editAlreadyVerifiedThisTurn(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: classification.mutating,
            verificationToolNames: classification.verification))
        XCTAssertTrue(ChatLoop.shouldVerifyEdits(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: classification.mutating,
            verificationToolNames: classification.verification,
            alreadyVerified: false))
    }

    func testReadFileAfterEditSatisfiesVerification() async {
        await ToolRegistry.shared.registerBuiltins()
        let classification = await ToolClassification.load(
            registry: .shared, xcodeMCPEnabled: false)

        let messages: [ChatMessage] = [
            msg(.user, "fix it"),
            msg(.assistant, "", calls: [.init(id: "e1", name: "write_file", arguments: "{}")]),
            toolMsg("Wrote 10 bytes", id: "e1"),
            msg(.assistant, "", calls: [.init(id: "r1", name: "read_file", arguments: "{}")]),
            toolMsg("file contents", id: "r1"),
            msg(.assistant, "Verified and done."),
        ]
        XCTAssertTrue(ChatLoop.editAlreadyVerifiedThisTurn(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: classification.mutating,
            verificationToolNames: classification.verification))
        XCTAssertFalse(ChatLoop.shouldVerifyEdits(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: classification.mutating,
            verificationToolNames: classification.verification,
            alreadyVerified: false))
    }

    func testMCPVerificationExcludedWhenXcodeMCPDisabled() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let classification = await ToolClassification.load(
            registry: .shared, xcodeMCPEnabled: false)
        XCTAssertFalse(classification.verification.contains("BuildProject"))
    }

    func testGitDiffAfterEditSatisfiesVerification() async {
        await ToolRegistry.shared.registerBuiltins()
        let classification = await ToolClassification.load(
            registry: .shared, xcodeMCPEnabled: false)

        let messages: [ChatMessage] = [
            msg(.user, "fix it"),
            msg(.assistant, "", calls: [.init(id: "e1", name: "write_file", arguments: "{}")]),
            toolMsg("Wrote 10 bytes", id: "e1"),
            msg(.assistant, "", calls: [.init(id: "d1", name: "git_diff", arguments: "{}")]),
            toolMsg("diff --git a/Foo.swift", id: "d1"),
            msg(.assistant, "Done."),
        ]
        XCTAssertTrue(ChatLoop.editAlreadyVerifiedThisTurn(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: classification.mutating,
            verificationToolNames: classification.verification))
    }

    // MARK: - AgentLoop end-to-end

    private func toolCallTurn(id: String, name: String, args: String) -> [ChatChunk] {
        [.toolCallDelta(index: 0, id: id, name: name, argumentsAppend: args),
         .done(finishReason: "tool_calls")]
    }

    private func proseTurn(_ text: String) -> [ChatChunk] {
        [.contentDelta(text), .done(finishReason: "stop")]
    }

    func testAgentLoopEditVerifyForceContinueAfterListDirectoryOnly() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edit-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writeArgs = #"{"path":"test.txt","content":"hello"}"#
        let listArgs = #"{"path":"."}"#
        let readArgs = #"{"path":"test.txt"}"#
        let backend = EditVerifyScriptedBackend(turns: [
            toolCallTurn(id: "w1", name: "write_file", args: writeArgs),
            toolCallTurn(id: "l1", name: "list_directory", args: listArgs),
            proseTurn("All done!"),
            toolCallTurn(id: "r1", name: "read_file", args: readArgs),
            proseTurn("Verified and done."),
        ])
        let model = ModelDescriptor(id: "test-model", displayName: "Test", backend: .lmStudio)
        let loop = AgentLoop(backend: backend, model: model,
                             config: .init(verifyEdits: true))
        let finished = FinishFlag()
        _ = try await loop.run(userMessage: "fix it",
                               conversation: Conversation(projectRoot: tmp)) { e in
            if case .finished = e { finished.set() }
        }

        XCTAssertTrue(finished.value, "loop should finish after real verification")
        XCTAssertGreaterThanOrEqual(
            backend.capturedRequests.count, 4,
            "premature finish must be blocked — expect edit-verify force-continue iteration")
        let nudged = backend.capturedRequests.dropFirst(3).contains { req in
            req.messages.first(where: { $0.role == .system })?
                .content.contains("Verify your edits") == true
        }
        XCTAssertTrue(
            nudged,
            "mutating edit → list_directory → finish must inject edit-verify nudge")
        print("EDIT_VERIFY_TRACE: mutating edit → list_directory → finish attempt → force-continue")
    }

    func testAgentLoopFinishesWithoutNudgeAfterReadFileVerification() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edit-verify-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writeArgs = #"{"path":"test.txt","content":"hello"}"#
        let readArgs = #"{"path":"test.txt"}"#
        let backend = EditVerifyScriptedBackend(turns: [
            toolCallTurn(id: "w1", name: "write_file", args: writeArgs),
            toolCallTurn(id: "r1", name: "read_file", args: readArgs),
            proseTurn("Verified and done."),
        ])
        let model = ModelDescriptor(id: "test-model", displayName: "Test", backend: .lmStudio)
        let loop = AgentLoop(backend: backend, model: model,
                             config: .init(verifyEdits: true))
        _ = try await loop.run(userMessage: "fix it",
                               conversation: Conversation(projectRoot: tmp)) { _ in }

        XCTAssertEqual(backend.capturedRequests.count, 3,
                       "read_file after edit satisfies verification — no extra iteration")
        let nudged = backend.capturedRequests.contains { req in
            req.messages.first(where: { $0.role == .system })?
                .content.contains("Verify your edits") == true
        }
        XCTAssertFalse(nudged)
        print("EDIT_VERIFY_TRACE: mutating edit → read_file → finish succeeds")
    }
}