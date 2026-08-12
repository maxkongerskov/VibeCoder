//
//  GrokPortMemoryTests.swift
//  Proves shipped memory write → search → dream path (Grok port phase 1).
//

import XCTest
@testable import AgentCore

final class GrokPortMemoryTests: XCTestCase {

    func testRememberThenSearchRetrievesFact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let global = root.appendingPathComponent("global", isDirectory: true)
        let workspace = root.appendingPathComponent("ws", isDirectory: true)
        let storage = MemoryStorage(
            globalDir: global, workspaceDir: workspace,
            workspacePath: root, ephemeral: false)
        try storage.ensureDirs()
        let index = MemoryIndex(indexURL: storage.indexFile)
        let backend = MemoryBackend(storage: storage, index: index)

        try backend.remember(
            text: "Decision: use worktree isolation for all agent edits to protect main.",
            scope: .workspace)

        let hits = backend.search(query: "worktree isolation agent edits", maxResults: 5)
        XCTAssertFalse(hits.isEmpty, "expected search hit for planted decision")
        let blob = hits.map(\.snippet).joined(separator: " ").lowercased()
        XCTAssertTrue(blob.contains("worktree") || blob.contains("isolation"),
                      "hit should mention worktree/isolation, got: \(blob)")
    }

    func testDreamConsolidatesSessionLog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let global = root.appendingPathComponent("global", isDirectory: true)
        let workspace = root.appendingPathComponent("ws", isDirectory: true)
        let storage = MemoryStorage(
            globalDir: global, workspaceDir: workspace,
            workspacePath: root, ephemeral: false)
        try storage.ensureDirs()
        let index = MemoryIndex(indexURL: storage.indexFile)
        let backend = MemoryBackend(storage: storage, index: index)

        try backend.writeSessionLog(
            sessionId: UUID().uuidString,
            content: """
            # Session
            - **user:** Should we use worktrees?
            - **assistant:** Decision: always use git worktrees for agent edits.
            """)

        let ran = try await backend.dreamIfNeeded(minSessions: 1, minHours: 0)
        XCTAssertTrue(ran.didRun, "dream should run with one session log, reason=\(ran.reason)")
        let mem = storage.readMemory(scope: .workspace) ?? ""
        XCTAssertTrue(
            mem.lowercased().contains("worktree") || mem.lowercased().contains("decision")
                || mem.lowercased().contains("session"),
            "workspace memory should contain consolidated content: \(mem.prefix(300))")
    }

    func testRecallBlockNonEmptyAfterRemember() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = MemoryStorage(
            globalDir: root.appendingPathComponent("g"),
            workspaceDir: root.appendingPathComponent("w"),
            workspacePath: root, ephemeral: false)
        try storage.ensureDirs()
        let backend = MemoryBackend(storage: storage, index: MemoryIndex(indexURL: storage.indexFile))
        try backend.remember(text: "Avoid full-file rewrites on large Swift sources.", scope: .workspace)
        let block = backend.recallBlock(query: "Swift rewrites avoid full file")
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("Retrieved") || block!.lowercased().contains("avoid"),
                      block ?? "nil")
    }

    /// Wave C: end-of-turn capture must flush a session log so dream has fuel
    /// (without requiring full-replace compact first).
    func testEndTurnCaptureFlushesThenDreamConsolidates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("endturn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = MemoryStorage(
            globalDir: root.appendingPathComponent("g"),
            workspaceDir: root.appendingPathComponent("w"),
            workspacePath: root, ephemeral: false)
        try storage.ensureDirs()
        let backend = MemoryBackend(storage: storage, index: MemoryIndex(indexURL: storage.indexFile))

        // Empty session list → dream alone would no-op
        XCTAssertTrue(storage.listSessionLogs().isEmpty)
        let emptyDream = try await backend.dreamIfNeeded(minSessions: 1, minHours: 0)
        XCTAssertFalse(emptyDream.didRun)

        let messages: [ChatMessage] = [
            .init(role: .user, content: "Should we isolate agent edits with git worktrees?"),
            .init(role: .assistant, content: "Decision: always use git worktrees for agent edits to protect main."),
        ]
        let ran = try await backend.endTurnCapture(
            sessionId: UUID().uuidString,
            messages: messages,
            dreamEnabled: true,
            minSessions: 1,
            minHours: 0)
        XCTAssertTrue(ran.didFlush && ran.didDream, "endTurnCapture should flush then dream: \(ran)")
        let mem = storage.readMemory(scope: .workspace) ?? ""
        XCTAssertTrue(
            mem.lowercased().contains("worktree") || mem.lowercased().contains("decision"),
            "expected consolidated memory after end-turn flush: \(mem.prefix(400))")
    }

    func testEndTurnCaptureSkipsTrivialUserOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trivial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = MemoryStorage(
            globalDir: root.appendingPathComponent("g"),
            workspaceDir: root.appendingPathComponent("w"),
            workspacePath: root, ephemeral: false)
        try storage.ensureDirs()
        let backend = MemoryBackend(storage: storage, index: MemoryIndex(indexURL: storage.indexFile))

        // Too-short user text, no assistant → no flush
        _ = try await backend.endTurnCapture(
            sessionId: UUID().uuidString,
            messages: [.init(role: .user, content: "hi")],
            dreamEnabled: true)
        XCTAssertTrue(storage.listSessionLogs().isEmpty)
    }

    func testLoadProjectMemoryIncludesSessionHandoff() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        # Session Handoff
        HAND_OFF_MARKER_XYZ: next step is run tests.
        """.write(to: root.appendingPathComponent("SESSION_HANDOFF.md"),
                  atomically: true, encoding: .utf8)

        let block = ChatLoop.loadProjectMemory(projectRoot: root)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("HAND_OFF_MARKER_XYZ"), block ?? "nil")
        XCTAssertTrue(block!.contains("SESSION_HANDOFF"), block ?? "nil")
    }

    func testMemoryToolSchemaIncludesTextForRemember() {
        let props = MemoryTool.schema.parameters.properties
        XCTAssertNotNil(props["text"], "remember action requires `text` in schema")
        XCTAssertTrue(MemoryTool.schema.parameters.properties.keys.contains("text")
                      || props["text"] != nil)
    }

    /// C2: read action must accept file=memory (project MEMORY.md), not only decisions/handoff.
    func testMemoryToolReadProjectMemoryFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "PROJECT_MEMORY_MARKER_C2\n"
            .write(to: root.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)

        let tool = MemoryTool()
        let ctx = ToolContext(projectRoot: root, conversationID: UUID())
        let result = try await tool.execute(
            arguments: ToolArguments(dictionary: [
                "action": "read",
                "file": "memory",
            ]),
            context: ctx)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("PROJECT_MEMORY_MARKER_C2"), result.content)

        let fileEnum = MemoryTool.schema.parameters.properties["file"]?.enum ?? []
        XCTAssertTrue(fileEnum.contains("memory"), "schema file enum should list memory: \(fileEnum)")
    }

    /// C2: same conversation + day must not overwrite prior session logs
    /// when dream is throttled (unique filename suffix).
    func testSessionLogsDoNotOverwriteSameDaySameConversation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sess-uniq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = MemoryStorage(
            globalDir: root.appendingPathComponent("g"),
            workspaceDir: root.appendingPathComponent("w"),
            workspacePath: root, ephemeral: false)
        try storage.ensureDirs()
        let sid = UUID().uuidString
        _ = try storage.writeSessionLog(sessionId: sid, content: "# first\n")
        _ = try storage.writeSessionLog(sessionId: sid, content: "# second\n")
        let logs = storage.listSessionLogs()
        XCTAssertEqual(logs.count, 2, "expected unique session log files, got \(logs.map(\.lastPathComponent))")
    }

    /// C2: default minHours throttles second dream without minHours:0.
    func testEndTurnCaptureDefaultThrottleSkipsImmediateSecondDream() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = MemoryStorage(
            globalDir: root.appendingPathComponent("g"),
            workspaceDir: root.appendingPathComponent("w"),
            workspacePath: root, ephemeral: false)
        try storage.ensureDirs()
        let backend = MemoryBackend(storage: storage, index: MemoryIndex(indexURL: storage.indexFile))
        let messages: [ChatMessage] = [
            .init(role: .user, content: "Decision topic: use worktrees for isolation please"),
            .init(role: .assistant, content: "Decision: always use git worktrees for agent edits."),
        ]
        // Force consolidate first
        let first = try await backend.endTurnCapture(
            sessionId: UUID().uuidString, messages: messages,
            dreamEnabled: true, minHours: 0)
        XCTAssertTrue(first.didDream)
        // Default minHours=1 should skip re-consolidate immediately
        let second = try await backend.endTurnCapture(
            sessionId: UUID().uuidString, messages: messages,
            dreamEnabled: true)
        XCTAssertFalse(second.didDream, "second dream should be throttled by minHours default")
        XCTAssertEqual(second.dreamReason, "too_soon")
        // But session logs should still accumulate (unique names)
        XCTAssertFalse(storage.listSessionLogs().isEmpty)
    }
}
