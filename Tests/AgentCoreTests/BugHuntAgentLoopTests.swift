//
//  BugHuntAgentLoopTests.swift
//
//  Verification-first hunt against Sources/AgentCore/Agent/.
//

import XCTest
@testable import AgentCore

// MARK: - Scripted backend

private final class BugHuntScriptedBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let lock = NSLock()
    private var _captured: [ChatRequest] = []
    private let turns: [[ChatChunk]]
    private var turnIndex = 0

    init(turns: [[ChatChunk]]) { self.turns = turns }

    var capturedRequests: [ChatRequest] {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "bug-hunt", displayName: "BugHunt", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        _captured.append(request)
        let chunks: [ChatChunk]
        if turns.isEmpty {
            chunks = []
        } else if turnIndex < turns.count {
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

private final class BugHuntCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class BugHuntEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [LoopEvent] = []

    func append(_ e: LoopEvent) {
        lock.lock(); _events.append(e); lock.unlock()
    }

    var events: [LoopEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    var pendingQuestionCount: Int {
        events.filter { if case .pendingQuestion = $0 { return true }; return false }.count
    }

    var iterationCount: Int {
        events.filter { if case .iterationStarted = $0 { return true }; return false }.count
    }
}

final class BugHuntAgentLoopTests: XCTestCase {

    private let model = ModelDescriptor(
        id: "bug-hunt", displayName: "BugHunt", backend: .lmStudio,
        supportsTools: true, contextLength: 32_768)

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
    }

    // MARK: - SubAgentRunner name fragments (parity with ResponseNormalizer)

    /// AgentLoop buckets names via ResponseNormalizer (concat / overlap).
    /// SubAgentRunner *replaces* a non-empty name on each delta, so a
    /// fragmented `list_` + `directory` becomes `directory`.
    func testSubAgentRunnerMergesFragmentedToolNames() async throws {
        let backend = BugHuntScriptedBackend(turns: [[
            .toolCallDelta(index: 0, id: "c1", name: "list_", argumentsAppend: nil),
            .toolCallDelta(index: 0, id: nil, name: "directory",
                           argumentsAppend: #"{"path":"."}"#),
            .done(finishReason: "tool_calls"),
        ]])
        let result = await SubAgentRunner.run(
            prompt: "list the project",
            allowedTools: ["list_directory"],
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            projectRoot: FileManager.default.temporaryDirectory,
            maxIterations: 3,
            enableStallPolicy: false
        )
        let assistants = result.transcript.messages.filter { $0.role == .assistant }
        let names = assistants.flatMap { $0.toolCalls.map(\.name) }
        XCTAssertTrue(
            names.contains("list_directory"),
            "fragmented native name deltas must assemble to list_directory, got \(names); final=\(result.finalText)"
        )
        XCTAssertFalse(
            names.contains("directory"),
            "second name fragment must not replace the first; got \(names)"
        )
    }

    /// ResponseNormalizer (AgentLoop) substitutes `{}` for empty args.
    /// SubAgentRunner forwards `""`, which ToolArguments rejects.
    func testSubAgentRunnerEmptyArgumentsDefaultToEmptyObject() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-empty-args-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let backend = BugHuntScriptedBackend(turns: [[
            .toolCallDelta(index: 0, id: "c1", name: "list_directory", argumentsAppend: nil),
            .done(finishReason: "tool_calls"),
        ]])
        let result = await SubAgentRunner.run(
            prompt: "list files",
            allowedTools: ["list_directory"],
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            projectRoot: tmp,
            maxIterations: 3,
            enableStallPolicy: false
        )
        let toolMsgs = result.transcript.messages.filter { $0.role == .tool }
        XCTAssertFalse(toolMsgs.isEmpty, "tool call must produce a result row")
        let joined = toolMsgs.map(\.content).joined(separator: "\n")
        XCTAssertFalse(
            joined.lowercased().contains("could not parse json")
                || joined.lowercased().contains("invalid arguments")
                || joined.lowercased().contains("tool error"),
            "empty argument stream must be treated as {{}}; got: \(joined)"
        )
    }

    /// AgentLoop recovers inline JSON tool calls; SubAgentRunner does not.
    func testSubAgentRunnerDispatchesInlineJSONToolCalls() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-inline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inline = #"[{"tool":"list_directory","path":"."}]"#
        let backend = BugHuntScriptedBackend(turns: [[
            .contentDelta(inline),
            .done(finishReason: "stop"),
        ]])
        let result = await SubAgentRunner.run(
            prompt: "list files",
            allowedTools: ["list_directory"],
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            projectRoot: tmp,
            maxIterations: 2,
            enableStallPolicy: false
        )
        let toolRows = result.transcript.messages.filter { $0.role == .tool }
        XCTAssertFalse(
            toolRows.isEmpty,
            "inline JSON tool calls must be dispatched like AgentLoop; transcript=\(result.transcript.messages.map { "\($0.role):\($0.content.prefix(60))" }) final=\(result.finalText)"
        )
    }

    // MARK: - ResponseNormalizer / think-tag leakage

    /// Inline fallback must not treat tool JSON rehearsed inside <think> as live calls.
    func testResponseNormalizerDoesNotExtractToolCallsFromThinkTags() {
        let content = """
        <think>
        I might call [{"tool": "delete_file", "path": "/tmp/should-not-run"}]
        </think>
        The directory is empty.
        """
        let result = ResponseNormalizer.finalize(content: content, buckets: [:])
        XCTAssertTrue(
            result.toolCalls.isEmpty,
            "tool JSON inside think tags must not become live tool_calls; got \(result.toolCalls.map(\.name))"
        )
        XCTAssertTrue(result.content.contains("directory is empty"))
    }

    /// Same leak through AgentLoop: a think-tag rehearsal would mutate the project.
    func testAgentLoopDoesNotDispatchInlineToolsRehearsedInThinkTags() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-think-dispatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let victim = tmp.appendingPathComponent("keep-me.txt")
        try "keep".write(to: victim, atomically: true, encoding: .utf8)

        let content = """
        <think>
        [{"tool":"delete_file","path":"keep-me.txt"}]
        </think>
        Leaving the file alone.
        """
        let backend = BugHuntScriptedBackend(turns: [[
            .contentDelta(content),
            .done(finishReason: "stop"),
        ]])
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(verifyEdits: false, dreamEnabled: false)
        )
        let convo = try await loop.run(
            userMessage: "do not delete anything",
            conversation: Conversation(projectRoot: tmp)
        ) { _ in }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: victim.path),
            "delete_file rehearsed inside <think> must not execute"
        )
        let toolRows = convo.messages.filter { $0.role == .tool }
        XCTAssertTrue(
            toolRows.isEmpty,
            "no tool results expected; got \(toolRows.map { $0.content.prefix(80) })"
        )
    }

    // MARK: - Grounding uses raw think-tagged content

    /// Finish-path grounding uses raw stream content (including <think>),
    /// so honest language in the think block suppresses a visible success
    /// claim after a failed *non-mutating* tool (read_file — no EditVerify).
    func testGroundingUsesDisplayContentNotThinkTags() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-ground-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let failed: [ChatChunk] = [
            .toolCallDelta(
                index: 0, id: "r1", name: "read_file",
                argumentsAppend: #"{"path":"does-not-exist.txt"}"#),
            .done(finishReason: "tool_calls"),
        ]
        // Visible body claims success; think tags contain honest failure words.
        let claim: [ChatChunk] = [
            .contentDelta(
                "<think>I cannot read it, the call failed.</think>\nDone! Successfully created the file."
            ),
            .done(finishReason: "stop"),
        ]
        let honest: [ChatChunk] = [
            .contentDelta("The read failed — the file was not there."),
            .done(finishReason: "stop"),
        ]
        let backend = BugHuntScriptedBackend(turns: [failed, claim, honest])
        let collector = BugHuntEventCollector()
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(verifyEdits: false, dreamEnabled: false)
        )
        _ = try await loop.run(
            userMessage: "read it",
            conversation: Conversation(projectRoot: tmp)
        ) { collector.append($0) }

        XCTAssertGreaterThanOrEqual(
            collector.iterationCount,
            3,
            "grounding must use the visible body (success claim) not think-tag hedges; iters=\(collector.iterationCount) events=\(collector.events.map { String(describing: $0).prefix(80) })"
        )
    }

    func testClaimsUnverifiedSuccessDoesNotFireOnNotCompleted() {
        XCTAssertFalse(
            ChatLoop.claimsUnverifiedSuccess("I have not completed the task."),
            "honest 'not completed' must not count as a success claim"
        )
        XCTAssertFalse(
            ChatLoop.shouldVerifyBeforeFinish(
                recentToolErrorFlags: [true],
                finalAssistantContent: "I have not completed the task.")
        )
    }

    // MARK: - ask_user must not ride the parallel RO batch

    func testAskUserIsNotParallelSafeReadOnly() async {
        let parallel = await ToolRegistry.shared.isParallelSafeReadOnlyTool("ask_user")
        XCTAssertFalse(
            parallel,
            "ask_user suspends for a human and must be serial like create_plan"
        )
    }

    func testAskUserNextToReadEmitsPendingQuestion() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "hi".write(to: tmp.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

        let asked = BugHuntCounter()
        let reviewer = UserQuestionReviewer { _ in
            asked.increment()
            return "go ahead"
        }

        let batch: [ChatChunk] = [
            .toolCallDelta(
                index: 0, id: "r1", name: "read_file",
                argumentsAppend: #"{"path":"probe.txt"}"#),
            .toolCallDelta(
                index: 1, id: "a1", name: "ask_user",
                argumentsAppend: #"{"question":"Ship it?","options":["yes","no"]}"#),
            .done(finishReason: "tool_calls"),
        ]
        let backend = BugHuntScriptedBackend(turns: [
            batch,
            [.contentDelta("ok"), .done(finishReason: "stop")],
        ])
        let collector = BugHuntEventCollector()
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(
                verifyEdits: false,
                userQuestionReviewer: reviewer,
                dreamEnabled: false)
        )
        _ = try await loop.run(
            userMessage: "check and ask",
            conversation: Conversation(projectRoot: tmp)
        ) { collector.append($0) }

        XCTAssertEqual(
            collector.pendingQuestionCount,
            1,
            "ask_user batched with a read must still emit pendingQuestion; events=\(collector.events.map { String(describing: $0).prefix(60) })"
        )
        XCTAssertEqual(asked.value, 1, "reviewer must still be invoked")
    }

    // MARK: - Governor error counts for BuildGuard-supported toolchains

    func testGovernorErrorCountCountsCargoStyleErrors() {
        let cargo = """
        error: cannot find `foo` in this scope
         --> src/main.rs:1:1
        error[E0425]: cannot find value `bar` in this scope
        """
        XCTAssertGreaterThan(
            Governor.errorCount(inBuildLog: cargo),
            0,
            "BuildGuard runs cargo check; persistence must see cargo 'error:' lines"
        )
    }

    func testGovernorErrorCountCountsTscStyleErrors() {
        let tsc = """
        src/foo.ts:1:1 - error TS2304: Cannot find name 'foo'.
        error TS2322: Type 'string' is not assignable to type 'number'.
        """
        XCTAssertGreaterThan(
            Governor.errorCount(inBuildLog: tsc),
            0,
            "BuildGuard runs tsc --noEmit; persistence must see TS error lines"
        )
    }

    func testVerifierPersistenceTripsOnRepeatedCargoFailures() {
        let cargo = "error: cannot find `foo` in this scope\n --> src/main.rs:1:1\n"
        let counts = Array(repeating: Governor.errorCount(inBuildLog: cargo), count: 3)
        let signal = Governor.evaluate(
            recentToolCalls: [],
            recentErrorCounts: counts,
            lastToolOutput: nil
        )
        guard case .verifierFailurePersistent? = signal else {
            return XCTFail(
                "three failed cargo builds must trip persistence; counts=\(counts) signal=\(String(describing: signal))"
            )
        }
    }

    // MARK: - System prompt context % uses budget as numerator base

    func testContextUsagePercentUsesContextLengthNotBudget() {
        let longUser = String(repeating: "word ", count: 400)
        let input = AgentSystemPromptComposer.Input(
            conversation: Conversation(),
            config: .init(
                contextBudgetTokens: 200,
                dreamEnabled: false,
                fullReplaceCompactEnabled: false
            ),
            model: ModelDescriptor(
                id: "m", displayName: "m", backend: .lmStudio,
                contextLength: 100_000),
            nudges: [],
            messages: [ChatMessage(role: .user, content: longUser)]
        )
        let (prompt, _) = AgentSystemPromptComposer.compose(input)
        guard let line = prompt.split(separator: "\n")
            .first(where: { $0.hasPrefix("Context usage:") })
            .map(String.init)
        else {
            return XCTFail("expected Context usage notice in harnessed prompt")
        }
        // "Context usage: ~USED / CONTEXT tokens (~PCT% used)."
        let parts = line
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: ",", with: "")
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        XCTAssertGreaterThanOrEqual(parts.count, 3, "unparseable notice: \(line)")
        let used = parts[0]
        let shownWindow = parts[1]
        let pct = parts[2]
        XCTAssertEqual(shownWindow, 100_000, "notice window: \(line)")
        let expected = TokenEstimator.percentOfContext(tokens: used, contextSize: 100_000)
        XCTAssertEqual(
            pct,
            expected,
            "percent must be used/contextLength, not used/budget; notice=\(line) expected=\(expected)"
        )
        XCTAssertLessThan(
            pct,
            100,
            "200-token budget vs 100k window must not report 100% of the window; \(line)"
        )
    }

    // MARK: - Pairing / cancel / cap helpers stay honest

    func testAgentLoopEmptyArgumentsStillPairAndDispatch() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-loop-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let backend = BugHuntScriptedBackend(turns: [[
            .toolCallDelta(index: 0, id: "c1", name: "list_directory", argumentsAppend: nil),
            .done(finishReason: "tool_calls"),
        ], [
            .contentDelta("listed"),
            .done(finishReason: "stop"),
        ]])
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(verifyEdits: false, dreamEnabled: false)
        )
        let convo = try await loop.run(
            userMessage: "list",
            conversation: Conversation(projectRoot: tmp)
        ) { _ in }
        XCTAssertTrue(ChatLoop.toolCallPairingIsValid(in: convo.messages))
        let tool = convo.messages.first { $0.role == .tool }
        XCTAssertNotNil(tool)
        XCTAssertFalse(
            (tool?.content ?? "").lowercased().contains("could not parse json"),
            "AgentLoop empty args should become {{}}: \(tool?.content ?? "")"
        )
    }

    func testCanonicalJSONArgumentsIgnoresKeyOrder() {
        let a = ChatLoop.canonicalJSONArguments(#"{"b":1,"a":2}"#)
        let b = ChatLoop.canonicalJSONArguments(#"{"a":2,"b":1}"#)
        XCTAssertEqual(a, b)
        XCTAssertEqual(
            ChatLoop.turnToolSignature(messages: [
                ChatMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [ToolCallInvocation(
                        id: "1", name: "read_file",
                        arguments: #"{"path":"x","offset":1}"#)]
                )
            ]),
            ChatLoop.turnToolSignature(messages: [
                ChatMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [ToolCallInvocation(
                        id: "1", name: "read_file",
                        arguments: #"{"offset":1,"path":"x"}"#)]
                )
            ])
        )
    }

    func testCompactHistoryPreservesToolPairing() {
        var messages: [ChatMessage] = []
        for i in 0..<10 {
            let id = "c\(i)"
            messages.append(ChatMessage(
                role: .assistant, content: String(repeating: "a", count: 5_000),
                toolCalls: [ToolCallInvocation(id: id, name: "read_file", arguments: "{}")]))
            messages.append(ChatMessage(
                role: .tool, content: String(repeating: "b", count: 8_000),
                toolCallID: id))
        }
        let out = ChatLoop.compactHistory(
            messages, systemPromptTokens: 0, budgetTokens: 500, keepRecent: 2)
        XCTAssertTrue(ChatLoop.toolCallPairingIsValid(in: out))
        XCTAssertEqual(out.count, messages.count)
    }

    func testToolResultCompressorDoesNotBreakPairing() {
        var messages: [ChatMessage] = []
        for i in 0..<4 {
            let id = "c\(i)"
            messages.append(ChatMessage(
                role: .assistant, content: "",
                toolCalls: [ToolCallInvocation(
                    id: id, name: "read_file",
                    arguments: #"{"path":"/f\#(i).txt"}"#)]))
            messages.append(ChatMessage(
                role: .tool,
                content: String(repeating: "x\n", count: 2_000),
                toolCallID: id))
        }
        let out = ToolResultCompressor.compress(messages)
        XCTAssertTrue(ChatLoop.toolCallPairingIsValid(in: out))
        XCTAssertEqual(out.filter { $0.role == .tool }.count, 4)
    }

    func testIterationCapZeroStillEmitsFinished() async throws {
        let backend = BugHuntScriptedBackend(turns: [[
            .contentDelta("should not run"),
            .done(finishReason: "stop"),
        ]])
        let collector = BugHuntEventCollector()
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(maxIterations: 0, verifyEdits: false, dreamEnabled: false)
        )
        let convo = try await loop.run(
            userMessage: "hi",
            conversation: Conversation()
        ) { collector.append($0) }
        XCTAssertTrue(
            collector.events.contains { if case .finished = $0 { return true }; return false },
            "maxIterations 0 must still finish; events=\(collector.events)"
        )
        XCTAssertEqual(backend.capturedRequests.count, 0,
                       "maxIterations 0 must not call the model")
        XCTAssertEqual(convo.messages.first?.role, .user)
    }

    func testOrchestratorEmptyTaskReturnsEmptyPlan() async {
        let backend = BugHuntScriptedBackend(turns: [[.contentDelta("plan"), .done(finishReason: "stop")]])
        let plan = await Orchestrator.plan(
            task: "   ",
            backend: backend,
            model: model
        )
        XCTAssertFalse(plan.succeeded)
        XCTAssertEqual(backend.capturedRequests.count, 0)
    }

    func testInterjectionEnqueueCurrentEpochRejectedAfterClear() async {
        let id = UUID()
        await InterjectionBuffer.shared.clear(conversationId: id)
        _ = await InterjectionBuffer.shared.enqueueCurrentEpoch(
            conversationId: id, text: "live")
        await InterjectionBuffer.shared.clear(conversationId: id)
        let accepted = await InterjectionBuffer.shared.enqueue(
            conversationId: id, text: "stale",
            expectedEpoch: 0
        )
        // After two clears, epoch is >= 2; expected 0 must fail.
        XCTAssertFalse(accepted)
        await InterjectionBuffer.shared.clear(conversationId: id)
    }
}
