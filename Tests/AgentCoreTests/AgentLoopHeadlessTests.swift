//
//  AgentLoopHeadlessTests.swift
//
//  Integration tests for headless (unattended) mode, driven by a
//  scripted fake backend. Verifies the two in-loop behaviours the App
//  layer relies on (the App-side concerns — sleep assertion, completion
//  notifications — are wired in ChatViewModel and aren't exercised here):
//
//    * headless run injects the conservative prologue into the system
//      prompt, and
//    * appends a `buildHeadlessSummary` assistant message when the turn
//      settles — while a non-headless run does neither.
//

import XCTest
@testable import AgentCore

/// Minimal `InferenceBackend` test double. Replays a scripted list of
/// chunks per turn and records every `ChatRequest` it was handed so a
/// test can assert what the loop actually sent.
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

final class AgentLoopHeadlessTests: XCTestCase {

    private let model = ModelDescriptor(id: "test-model", displayName: "Test", backend: .lmStudio)

    /// A single turn that finishes immediately with prose and no tool calls.
    private var finishingTurn: [[ChatChunk]] {
        [[.contentDelta("All done."), .done(finishReason: "stop")]]
    }

    private let summaryMarker = "Headless run — summary"
    private let prologueMarker = "running UNATTENDED"

    func testHeadlessRunAppendsSummaryAndInjectsPrologue() async throws {
        let backend = ScriptedBackend(turns: finishingTurn)
        let loop = AgentLoop(backend: backend, model: model,
                             config: .init(verifyEdits: false, headlessMode: true))

        let result = try await loop.run(userMessage: "do the thing",
                                        conversation: Conversation()) { _ in }

        // Summary is the final message.
        XCTAssertTrue(result.messages.last?.content.contains(summaryMarker) == true,
                      "headless run must append a summary as the last message")
        // Prologue reached the model.
        let systemPrompt = backend.capturedRequests.first?.messages
            .first(where: { $0.role == .system })?.content ?? ""
        XCTAssertTrue(systemPrompt.contains(prologueMarker),
                      "headless run must inject the unattended prologue")
    }

    func testNonHeadlessRunDoesNeither() async throws {
        let backend = ScriptedBackend(turns: finishingTurn)
        let loop = AgentLoop(backend: backend, model: model,
                             config: .init(verifyEdits: false, headlessMode: false))

        let result = try await loop.run(userMessage: "do the thing",
                                        conversation: Conversation()) { _ in }

        XCTAssertFalse(result.messages.contains { $0.content.contains(summaryMarker) },
                       "non-headless run must not append a summary")
        let systemPrompt = backend.capturedRequests.first?.messages
            .first(where: { $0.role == .system })?.content ?? ""
        XCTAssertFalse(systemPrompt.contains(prologueMarker),
                       "non-headless run must not inject the prologue")
    }

    func testProjectInstructionsAreInjectedIntoSystemPrompt() async throws {
        // A project folder carrying standing instructions.
        let projectRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-instr-inject-\(UUID().uuidString)")
        let agentosDir = projectRoot.appendingPathComponent(".agentos")
        try FileManager.default.createDirectory(at: agentosDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        try "NEVER use UIKit in this project."
            .write(to: agentosDir.appendingPathComponent("instructions.md"),
                   atomically: true, encoding: .utf8)

        let backend = ScriptedBackend(turns: finishingTurn)
        let loop = AgentLoop(backend: backend, model: model,
                             config: .init(verifyEdits: false))
        _ = try await loop.run(userMessage: "hi",
                               conversation: Conversation(projectRoot: projectRoot)) { _ in }

        let systemPrompt = backend.capturedRequests.first?.messages
            .first(where: { $0.role == .system })?.content ?? ""
        XCTAssertTrue(systemPrompt.contains("NEVER use UIKit in this project."),
                      "project instructions must be injected into the system prompt")
    }

    func testHeadlessSummaryReportsIterationCount() async throws {
        // Two tool-using turns, then a finishing turn — exercises the
        // iteration count in the summary. The tool is read-only so no
        // BuildGuard / mutation paths fire.
        let toolCall: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "c1", name: "list_directory", argumentsAppend: "{\"path\": \".\"}"),
            .done(finishReason: "tool_calls"),
        ]
        let projectRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-headless-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let backend = ScriptedBackend(turns: [toolCall, finishingTurn[0]])
        await ToolRegistry.shared.registerBuiltins()
        let loop = AgentLoop(backend: backend, model: model,
                             config: .init(verifyEdits: false, headlessMode: true))

        let result = try await loop.run(userMessage: "look around",
                                        conversation: Conversation(projectRoot: projectRoot)) { _ in }

        let summary = result.messages.last?.content ?? ""
        XCTAssertTrue(summary.contains(summaryMarker))
        XCTAssertTrue(summary.contains("2 iterations"),
                      "summary should report the iteration count; got: \(summary)")
    }
}
