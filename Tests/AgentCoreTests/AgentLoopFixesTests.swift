import XCTest
@testable import AgentCore

/// P0 regression: phantom tools, Xcode MCP dedup, context budget, BuildGuard.
final class AgentLoopFixesTests: XCTestCase {

    private let model = ModelDescriptor(
        id: "test-model", displayName: "Test", backend: .lmStudio)

    private var finishingTurn: [ChatChunk] {
        [.contentDelta("Done."), .done(finishReason: "stop")]
    }

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

        func listModels() async throws -> [ModelDescriptor] { [] }

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

    func testPhantomToolNamesAlignWithRegistry() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let registered = await ToolRegistry.shared.registeredNames()

        let pruning = await ToolClassification.load(
            registry: .shared, xcodeMCPEnabled: false).alwaysRelevant
        XCTAssertTrue(pruning.isSubset(of: registered),
                      "pruning set must only reference registered tools; extras: \(pruning.subtracting(registered))")

        let phantomNames = [
            "search_files", "git_log", "run_xcode_tests",
            "build_swift_package", "run_swift_tests",
        ]
        for name in phantomNames {
            XCTAssertFalse(pruning.contains(name), "phantom tool '\(name)' must not appear in pruning set")
        }

        let subAgentExtras = SubAgentRunner.safeDefault.subtracting(registered)
        XCTAssertTrue(subAgentExtras.isEmpty,
                      "sub-agent allow-list references unregistered tools: \(subAgentExtras)")

        let backend = ScriptedBackend(turns: [finishingTurn])
        let loop = AgentLoop(backend: backend, model: model, config: .init(verifyEdits: false))
        _ = try await loop.run(userMessage: "hi", conversation: Conversation()) { _ in }

        let systemPrompt = backend.capturedRequests.first?.messages
            .first(where: { $0.role == .system })?.content ?? ""
        XCTAssertTrue(systemPrompt.contains("glob_files"),
                      "system prompt must direct models to glob_files")
        XCTAssertTrue(systemPrompt.contains("grep_code"),
                      "system prompt must direct models to grep_code")
        XCTAssertFalse(systemPrompt.contains("search_files"),
                       "system prompt must not reference phantom tool search_files")
        XCTAssertFalse(systemPrompt.contains("`grep`"),
                       "system prompt must not reference bare grep tool name")
    }

    /// Wave B S5 read-before-edit: overwrite of an existing file without a
    /// prior `read_file` must fail closed (tool error) and must NOT run
    /// BuildGuard (no successful mutation).
    func testWriteFileRBEBlocksOverwriteWithoutPriorRead() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-rbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "old".write(to: tmp.appendingPathComponent("existing.swift"),
                        atomically: true, encoding: .utf8)

        let mutate: [ChatChunk] = [
            .toolCallDelta(
                index: 0, id: "w1", name: "write_file",
                argumentsAppend: #"{"path":"existing.swift","content":"new"}"#),
            .done(finishReason: "tool_calls"),
        ]
        let backend = ScriptedBackend(turns: [mutate, finishingTurn])
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(verifyEdits: true))
        let convo = try await loop.run(
            userMessage: "overwrite",
            conversation: Conversation(projectRoot: tmp)) { _ in }

        let toolResults = convo.messages.filter { $0.role == .tool }
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertTrue(
            toolResults[0].content.lowercased().contains("read-before-edit")
                || toolResults[0].content.lowercased().contains("read_file"),
            "RBE deny must surface in tool result: \(toolResults[0].content)")
        let buildGuardMsgs = convo.messages.filter {
            $0.content.contains("BuildGuard:")
        }
        XCTAssertTrue(buildGuardMsgs.isEmpty,
                      "Failed write must not trigger BuildGuard")
        XCTAssertTrue(ChatLoop.toolCallPairingIsValid(in: convo.messages))
    }

    /// Successful create (new path) triggers BuildGuard user-role reminder
    /// when verifyEdits is on. Uses a broken Package.swift so build fails.
    func testBuildGuardFailureProducesSingleTranscriptMessage() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-buildguard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let package = """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "BrokenPkg",
            targets: [.target(name: "BrokenPkg")]
        )
        """
        try package.write(to: tmp.appendingPathComponent("Package.swift"),
                          atomically: true, encoding: .utf8)
        let sourcesDir = tmp.appendingPathComponent("Sources/BrokenPkg")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        // Intentionally do NOT create main.swift — write_file creates a NEW
        // file (no RBE required). Content is syntactically invalid.
        let mutate: [ChatChunk] = [
            .toolCallDelta(
                index: 0, id: "w1", name: "write_file",
                argumentsAppend: #"{"path":"Sources/BrokenPkg/main.swift","content":"let x = "}"#),
            .done(finishReason: "tool_calls"),
        ]
        let backend = ScriptedBackend(turns: [mutate, finishingTurn])
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(verifyEdits: true))
        let convo = try await loop.run(
            userMessage: "fix",
            conversation: Conversation(projectRoot: tmp)) { _ in }

        let toolResults = convo.messages.filter { $0.role == .tool && $0.toolCallID == "w1" }
        XCTAssertEqual(toolResults.count, 1, "write_file must produce one tool result")
        XCTAssertFalse(
            toolResults[0].content.lowercased().contains("read-before-edit"),
            "new file must not hit RBE: \(toolResults[0].content)")

        let buildGuardMsgs = convo.messages.filter {
            $0.content.contains("BuildGuard: build failed")
                || $0.content.contains("BuildGuard: build succeeded")
        }
        XCTAssertEqual(buildGuardMsgs.count, 1,
                       "AgentLoop must inject exactly one BuildGuard system reminder; tools=\(toolResults.map { String($0.content.prefix(120)) })")
        XCTAssertEqual(buildGuardMsgs.first?.role, .user,
                       "BuildGuard must be a user-role system reminder, not an orphan tool row")
        XCTAssertTrue(
            ChatLoop.toolCallPairingIsValid(in: convo.messages),
            "transcript pairing invalid: unpaired=\(ChatLoop.unpairedToolResultIDs(in: convo.messages)) unclosed=\(ChatLoop.unclosedToolCallIDs(in: convo.messages))")
    }

    func testParallelReadOnlyBatchDispatchesAllToolResults() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-parallel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "x".write(to: tmp.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

        let readBatch: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "r1", name: "list_directory",
                           argumentsAppend: #"{"path":"."}"#),
            .toolCallDelta(index: 1, id: "r2", name: "glob_files",
                           argumentsAppend: #"{"pattern":"*.txt"}"#),
            .toolCallDelta(index: 2, id: "r3", name: "read_file",
                           argumentsAppend: #"{"path":"probe.txt"}"#),
            .done(finishReason: "tool_calls"),
        ]
        let backend = ScriptedBackend(turns: [readBatch, finishingTurn])
        let loop = AgentLoop(backend: backend, model: model, config: .init(verifyEdits: false))
        let convo = try await loop.run(
            userMessage: "inspect",
            conversation: Conversation(projectRoot: tmp)) { _ in }

        let toolResults = convo.messages.filter { $0.role == .tool }
        XCTAssertEqual(toolResults.count, 3)
        XCTAssertTrue(toolResults.contains { $0.toolCallID == "r1" })
        XCTAssertTrue(toolResults.contains { $0.toolCallID == "r2" })
        XCTAssertTrue(toolResults.contains { $0.toolCallID == "r3" })
        XCTAssertTrue(ChatLoop.toolCallPairingIsValid(in: convo.messages))
    }
}
