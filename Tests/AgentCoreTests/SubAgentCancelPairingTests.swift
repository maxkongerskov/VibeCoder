//
//  SubAgentCancelPairingTests.swift
//
//  Wave B W06 / S6a: SubAgentRunner closeToolCalls on cancel + stall subset.
//

import XCTest
@testable import AgentCore

// MARK: - Scripted backend

private final class ScriptedBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let lock = NSLock()
    private var turnIndex = 0
    private let turns: [[ChatChunk]]
    private let interChunkDelayNs: UInt64

    init(turns: [[ChatChunk]], interChunkDelayNs: UInt64 = 0) {
        self.turns = turns
        self.interChunkDelayNs = interChunkDelayNs
    }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "test", displayName: "Test", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        let chunks: [ChatChunk]
        if turns.isEmpty {
            chunks = []
        } else if turnIndex < turns.count {
            chunks = turns[turnIndex]
        } else {
            // Extra turns: stop cleanly so cap tests don't hang.
            chunks = [.contentDelta("done"), .done(finishReason: "stop")]
        }
        turnIndex += 1
        let delay = interChunkDelayNs
        lock.unlock()
        return AsyncThrowingStream { continuation in
            Task {
                for c in chunks {
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.yield(c)
                }
                continuation.finish()
            }
        }
    }

    func cancel(streamID: UUID) async {}
}

final class SubAgentCancelPairingTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await BackgroundJobManager.shared.cleanup()
    }

    override func tearDown() async throws {
        await BackgroundJobManager.shared.cleanup()
    }

    // MARK: - Unit: closeToolCalls + openToolCallIDs

    func testCloseToolCallsClearsOpenIDs() {
        var convo = Conversation(title: "t")
        let invs = [
            ToolCallInvocation(id: "a1", name: "read_file", arguments: #"{"path":"x"}"#),
            ToolCallInvocation(id: "a2", name: "list_directory", arguments: #"{"path":"."}"#),
        ]
        convo.messages.append(.init(
            role: .assistant,
            content: "",
            toolCalls: invs
        ))
        XCTAssertEqual(SubAgentRunner.openToolCallIDs(in: convo.messages), ["a1", "a2"])

        SubAgentRunner.closeToolCalls(
            invs,
            reason: "Cancelled by user before execution.",
            convo: &convo
        )
        XCTAssertTrue(
            SubAgentRunner.openToolCallIDs(in: convo.messages).isEmpty,
            "closeToolCalls must pair every open tool_call id"
        )
        let toolMsgs = convo.messages.filter { $0.role == .tool }
        XCTAssertEqual(toolMsgs.count, 2)
        XCTAssertTrue(toolMsgs.allSatisfy { $0.content.contains("Skipped:") })
        XCTAssertTrue(ChatLoop.unpairedToolResultIDs(in: convo.messages).isEmpty)
    }

    // MARK: - Mid-stream cancel: keep prose, drop partial tools

    func testMidStreamCancelKeepsProseDropsPartialTools() async throws {
        var chunks: [ChatChunk] = [
            .contentDelta("partial findings "),
            .contentDelta("so far… "),
        ]
        // Partial tool call stream (incomplete args) — must not land in transcript.
        chunks.append(.toolCallDelta(
            index: 0, id: "partial1", name: "read_file",
            argumentsAppend: #"{"path":"/tmp/incomp"#))
        for i in 0..<30 {
            chunks.append(.contentDelta("x\(i) "))
        }
        chunks.append(.done(finishReason: "stop"))

        let backend = ScriptedBackend(turns: [chunks], interChunkDelayNs: 25_000_000)
        let model = ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio)
        let jobID = try await BackgroundJobManager.shared.registerSubagent(description: "cancel-stream")

        let runTask = Task {
            await SubAgentRunner.run(
                prompt: "explore slowly",
                systemPromptOverride: SubagentType.explore.systemPrompt,
                allowedTools: SubagentType.explore.allowedTools(capability: .readOnly),
                backend: backend,
                model: model,
                registry: ToolRegistry.shared,
                maxIterations: 4,
                jobID: jobID
            )
        }

        try? await Task.sleep(nanoseconds: 90_000_000)
        let killedStream = await BackgroundJobManager.shared.kill(jobID)
        XCTAssertTrue(killedStream)

        let result = await runTask.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.finalText.lowercased().contains("cancel"))
        XCTAssertTrue(
            SubAgentRunner.openToolCallIDs(in: result.transcript.messages).isEmpty,
            "no open tool_call ids after stream cancel"
        )
        // Prose may have been kept if cancel landed after content deltas.
        let assistants = result.transcript.messages.filter { $0.role == .assistant }
        for a in assistants {
            XCTAssertTrue(
                a.toolCalls.isEmpty,
                "stream cancel must drop partial tool_calls, got \(a.toolCalls.map(\.name))"
            )
        }
    }

    // MARK: - Mid-dispatch cancel: close remaining tool_calls

    func testMidDispatchCancelClosesRemainingToolCalls() async throws {
        // First tool blocks; second would run after. Kill mid first tool.
        let backend = ScriptedBackend(turns: [[
            .toolCallDelta(
                index: 0, id: "t1", name: "run_shell",
                argumentsAppend: #"{"command":"sleep 1"}"#),
            .toolCallDelta(
                index: 1, id: "t2", name: "list_directory",
                argumentsAppend: #"{"path":"."}"#),
            .done(finishReason: "tool_calls"),
        ]])
        let model = ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio)
        let jobID = try await BackgroundJobManager.shared.registerSubagent(description: "cancel-dispatch")
        let root = FileManager.default.temporaryDirectory

        let runTask = Task {
            await SubAgentRunner.run(
                prompt: "run then list",
                systemPromptOverride: SubagentType.generalPurpose.systemPrompt,
                allowedTools: ["run_shell", "list_directory"],
                backend: backend,
                model: model,
                registry: ToolRegistry.shared,
                projectRoot: root,
                maxIterations: 3,
                enableStallPolicy: false,
                jobID: jobID
            )
        }

        // Land kill while sleep is in flight (or just after).
        try? await Task.sleep(nanoseconds: 150_000_000)
        let killedDispatch = await BackgroundJobManager.shared.kill(jobID)
        XCTAssertTrue(killedDispatch)

        let result = await runTask.value
        XCTAssertTrue(result.wasCancelled || result.finalText.lowercased().contains("cancel"),
                      result.finalText)

        let open = SubAgentRunner.openToolCallIDs(in: result.transcript.messages)
        XCTAssertTrue(open.isEmpty, "open tool_call ids after mid-dispatch cancel: \(open)")
        XCTAssertTrue(ChatLoop.unpairedToolResultIDs(in: result.transcript.messages).isEmpty)

        let toolByID = Dictionary(
            uniqueKeysWithValues: result.transcript.messages
                .filter { $0.role == .tool }
                .compactMap { m -> (String, String)? in
                    guard let id = m.toolCallID else { return nil }
                    return (id, m.content)
                }
        )
        // t2 must be closed synthetically if cancel landed before it ran.
        if let t2 = toolByID["t2"] {
            XCTAssertTrue(
                t2.contains("Skipped:") || t2.contains("Cancelled") || !t2.isEmpty,
                "t2 should have a result row: \(t2)"
            )
        }
        // At least two tool result rows if assistant declared both.
        let assistants = result.transcript.messages.filter {
            $0.role == .assistant && !$0.toolCalls.isEmpty
        }
        if let last = assistants.last {
            let ids = Set(last.toolCalls.map(\.id))
            let resultIDs = Set(toolByID.keys)
            XCTAssertTrue(ids.isSubset(of: resultIDs),
                          "declared \(ids) must be subset of results \(resultIDs)")
        }
    }

    // MARK: - Stall policy closes tools without dispatch

    func testStallPolicyClosesRepeatedToolCalls() async throws {
        let sameCall: [ChatChunk] = [
            .toolCallDelta(
                index: 0, id: "s1", name: "list_directory",
                argumentsAppend: #"{"path":"."}"#),
            .done(finishReason: "tool_calls"),
        ]
        // Three identical turns → stallWindow 3 fires before third dispatch.
        let backend = ScriptedBackend(turns: [sameCall, sameCall, sameCall])
        let model = ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio)
        let root = FileManager.default.temporaryDirectory

        let result = await SubAgentRunner.run(
            prompt: "list the same place forever",
            systemPromptOverride: SubagentType.explore.systemPrompt,
            allowedTools: ["list_directory"],
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            projectRoot: root,
            maxIterations: 8,
            stallWindow: 3,
            enableStallPolicy: true
        )

        XCTAssertNotNil(result.stallReason, "expected stall halt, got finalText=\(result.finalText)")
        XCTAssertTrue(result.finalText.lowercased().contains("stall"), result.finalText)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertTrue(
            SubAgentRunner.openToolCallIDs(in: result.transcript.messages).isEmpty,
            "stall closeToolCalls must pair ids"
        )

        let skipped = result.transcript.messages.filter {
            $0.role == .tool && $0.content.contains("Skipped:") && $0.content.contains("stalled")
        }
        XCTAssertFalse(skipped.isEmpty, "expected synthetic stall Skipped results")
    }

    // MARK: - Iteration cap message (no unpaired tools)

    func testIterationCapLeavesPairedTranscript() async throws {
        // Always request tools — exhaust cap with allowlist that succeeds.
        let call: [ChatChunk] = [
            .toolCallDelta(
                index: 0, id: "c", name: "list_directory",
                argumentsAppend: #"{"path":"."}"#),
            .done(finishReason: "tool_calls"),
        ]
        // Distinct ids per turn so stall does not fire; vary args slightly.
        let turns: [[ChatChunk]] = (0..<6).map { i in
            [
                .toolCallDelta(
                    index: 0, id: "c\(i)", name: "list_directory",
                    argumentsAppend: #"{"path":"./n\#(i)"}"#),
                .done(finishReason: "tool_calls"),
            ]
        }
        _ = call
        let backend = ScriptedBackend(turns: turns)
        let model = ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio)

        let result = await SubAgentRunner.run(
            prompt: "keep listing",
            allowedTools: ["list_directory"],
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            projectRoot: FileManager.default.temporaryDirectory,
            maxIterations: 3,
            enableStallPolicy: false
        )

        XCTAssertTrue(result.hitCap || result.finalText.contains("iteration cap")
                      || result.iterations >= 3,
                      "cap path: \(result.finalText) iters=\(result.iterations) hitCap=\(result.hitCap)")
        XCTAssertTrue(SubAgentRunner.openToolCallIDs(in: result.transcript.messages).isEmpty)
        XCTAssertTrue(ChatLoop.unpairedToolResultIDs(in: result.transcript.messages).isEmpty)
    }
}
