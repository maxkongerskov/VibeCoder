//
//  LocalAPIAgentLoopTests.swift
//  Depth D1 — opt-in multi-step AgentLoop on LocalAPI (mock backend).
//

import XCTest
@testable import AgentCore

final class LocalAPIAgentLoopTests: XCTestCase {

    private final class ScriptedBackend: InferenceBackend, @unchecked Sendable {
        let identifier: BackendIdentifier = .custom
        private let lock = NSLock()
        private var turns: [[ChatChunk]]
        private var turnIndex = 0
        private(set) var requestCount = 0
        private(set) var lastToolsCount: Int = -1

        init(turns: [[ChatChunk]]) { self.turns = turns }

        func listModels() async throws -> [ModelDescriptor] {
            [ModelDescriptor(id: "scripted", displayName: "scripted", backend: .custom)]
        }

        func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
            lock.lock()
            requestCount += 1
            lastToolsCount = request.tools.count
            let chunks: [ChatChunk]
            if turnIndex < turns.count {
                chunks = turns[turnIndex]
                turnIndex += 1
            } else {
                chunks = [.contentDelta("done"), .done(finishReason: "stop")]
            }
            lock.unlock()
            return AsyncThrowingStream { cont in
                for c in chunks { cont.yield(c) }
                cont.finish()
            }
        }

        func cancel(streamID: UUID) async {}
    }

    func testSplitHistoryAndUser() {
        let msgs = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "first"),
            ChatMessage(role: .assistant, content: "ok"),
            ChatMessage(role: .user, content: "second"),
        ]
        let (history, user) = LocalAPIServer.splitHistoryAndUser(msgs)
        XCTAssertEqual(user, "second")
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.last?.role, .assistant)
    }

    func testSplitHistoryAndUserSkipsTrailingSystemReminder() {
        let msgs = [
            ChatMessage(role: .user, content: "edit App.swift"),
            ChatMessage(role: .assistant, content: "ok"),
            ChatMessage(
                role: .user,
                content: SystemReminder.autoVerify(path: "App.swift", tail: "let x = 1")
            ),
        ]
        let (history, user) = LocalAPIServer.splitHistoryAndUser(msgs)
        XCTAssertEqual(user, "edit App.swift")
        XCTAssertTrue(history.isEmpty)
    }

    func testAgentLoopTurnExecutesToolThenFinishes() async throws {
        await ToolRegistry.shared.registerBuiltins()
        // Turn 1: model requests list_directory; Turn 2: final prose.
        let toolCall: [ChatChunk] = [
            .toolCallDelta(
                index: 0, id: "c1", name: "list_directory",
                argumentsAppend: #"{"path":"."}"#),
            .done(finishReason: "tool_calls"),
        ]
        let finish: [ChatChunk] = [
            .contentDelta("Listed the directory."),
            .done(finishReason: "stop"),
        ]
        let backend = ScriptedBackend(turns: [toolCall, finish])
        let model = ModelDescriptor(
            id: "scripted", displayName: "scripted", backend: .custom, supportsTools: true)

        var toolStarts = 0
        var toolCompletes = 0
        var sawContent = false

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("d1-localapi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await LocalAPIServer.runAgentLoopTurn(
            backend: backend,
            model: model,
            messages: [ChatMessage(role: .user, content: "list files here")],
            settings: AppSettings(),
            maxIterations: 4,
            projectRoot: root
        ) { event in
            switch event {
            case .toolStarted: toolStarts += 1
            case .toolCompleted: toolCompletes += 1
            case .contentDelta(let s) where !s.isEmpty: sawContent = true
            default: break
            }
        }

        XCTAssertGreaterThanOrEqual(backend.requestCount, 2,
                                    "Agent loop must re-prompt after tool result")
        XCTAssertGreaterThanOrEqual(toolStarts, 1, "expected ≥1 tool start")
        XCTAssertGreaterThanOrEqual(toolCompletes, 1, "expected ≥1 tool completion")
        XCTAssertTrue(sawContent || result.messages.contains(where: {
            $0.role == .assistant && $0.content.contains("Listed")
        }))
        // Second model call should have received tools (agent loop path).
        XCTAssertGreaterThan(backend.lastToolsCount, 0,
                             "AgentLoop ChatRequest should carry tool schemas")
    }

    func testAgentLoopCapsIterationsAtServerHardCap() async throws {
        // Even if caller asks for 100, LocalAPIServer clamps to agentLoopMaxIterations.
        await ToolRegistry.shared.registerBuiltins()
        let foreverTool: [ChatChunk] = [
            .toolCallDelta(
                index: 0, id: "x", name: "list_directory",
                argumentsAppend: #"{"path":"."}"#),
            .done(finishReason: "tool_calls"),
        ]
        // Enough tool turns to hit the cap if uncapped.
        let turns = Array(repeating: foreverTool, count: 20)
        let backend = ScriptedBackend(turns: turns)
        let model = ModelDescriptor(
            id: "scripted", displayName: "scripted", backend: .custom, supportsTools: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("d1-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await LocalAPIServer.runAgentLoopTurn(
            backend: backend,
            model: model,
            messages: [ChatMessage(role: .user, content: "loop")],
            maxIterations: 100,
            projectRoot: root
        ) { _ in }

        XCTAssertLessThanOrEqual(
            backend.requestCount,
            LocalAPIServer.agentLoopMaxIterations + 1,
            "must not exceed LocalAPI hard iteration cap")
    }

    func testAgentLoopTurnRejectsMissingProjectRoot() async {
        let backend = ScriptedBackend(turns: [[.contentDelta("x"), .done(finishReason: "stop")]])
        let model = ModelDescriptor(
            id: "scripted", displayName: "scripted", backend: .custom, supportsTools: true)
        do {
            _ = try await LocalAPIServer.runAgentLoopTurn(
                backend: backend,
                model: model,
                messages: [ChatMessage(role: .user, content: "hi")],
                projectRoot: nil
            )
            XCTFail("expected missingProjectRoot")
        } catch let error as LocalAPIAgentLoopError {
            XCTAssertEqual(error, .missingProjectRoot)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(backend.requestCount, 0, "must not call the model without a workspace")
    }

    func testAgentLoopTurnRejectsFilesystemRoot() async {
        let backend = ScriptedBackend(turns: [[.contentDelta("x"), .done(finishReason: "stop")]])
        let model = ModelDescriptor(
            id: "scripted", displayName: "scripted", backend: .custom, supportsTools: true)
        do {
            _ = try await LocalAPIServer.runAgentLoopTurn(
                backend: backend,
                model: model,
                messages: [ChatMessage(role: .user, content: "hi")],
                projectRoot: URL(fileURLWithPath: "/")
            )
            XCTFail("expected missingProjectRoot for /")
        } catch let error as LocalAPIAgentLoopError {
            XCTAssertEqual(error, .missingProjectRoot)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(backend.requestCount, 0)
    }

    func testRequireUsableProjectRootAcceptsTempDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("localapi-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = try LocalAPIServer.requireUsableProjectRoot(root)
        XCTAssertEqual(
            SafeModeConfig.normalizePath(resolved.path),
            SafeModeConfig.normalizePath(root.path))
    }

    func testDefaultConfigureDoesNotEnableAgentLoop() async {
        let backend = ScriptedBackend(turns: [])
        let server = LocalAPIServer()
        await server.configure(backend: backend, settings: AppSettings())
        let on = await server.isAgentToolsEnabled()
        XCTAssertFalse(on)
        let policy = await server.toolsPolicy()
        XCTAssertEqual(policy, .proxyOnly)
    }
}
