//
//  GrokPortHarnessDepthTests.swift
//  Permissions, hooks, agent defs, symbol index, interjections.
//

import XCTest
@testable import AgentCore

final class GrokPortHarnessDepthTests: XCTestCase {

    func testDurableGrantStorePersists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grants-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DurableGrantStore(fileURL: url)
        let key = GrantKey(projectKey: "/tmp/p", toolName: "run_shell", commandFingerprint: "swift build")
        await store.remember(.allow, for: key)
        let store2 = DurableGrantStore(fileURL: url)
        let d = await store2.decision(for: key)
        XCTAssertEqual(d, .allow)
    }

    func testHookDispatcherDenyList() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-\(UUID().uuidString)", isDirectory: true)
        let hooks = root.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "run_shell\n".write(
            to: hooks.appendingPathComponent("deny-tools.txt"),
            atomically: true, encoding: .utf8)
        let denied = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "rm -rf", projectRoot: root)
        XCTAssertFalse(denied.allow)
        let allowed = HookDispatcher.preTool(
            toolName: "read_file", argumentsSummary: "x", projectRoot: root)
        XCTAssertTrue(allowed.allow)
    }

    func testAgentDefinitionDiscoveryParsesFrontmatter() {
        let md = """
        ---
        name: code-reviewer
        description: Reviews code carefully
        tools: read_file, grep_code
        ---
        You are a careful code reviewer.
        """
        let def = AgentDefinitionDiscovery.parse(markdown: md)
        XCTAssertEqual(def?.name, "code-reviewer")
        XCTAssertEqual(def?.description, "Reviews code carefully")
        XCTAssertTrue(def?.systemPrompt.contains("careful code reviewer") == true)
        XCTAssertEqual(def?.tools, ["read_file", "grep_code"])
    }

    func testSymbolIndexFindsTextInTempProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sym-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Foo.swift")
        try "struct UniqueSymbolNameXYZ { }\n".write(to: file, atomically: true, encoding: .utf8)
        let hits = SymbolIndex.find(symbol: "UniqueSymbolNameXYZ", projectRoot: root)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits[0].snippet.contains("UniqueSymbolNameXYZ"))
    }

    func testInterjectionBufferDrain() async {
        let id = UUID()
        await InterjectionBuffer.shared.enqueue(conversationId: id, text: "stop and use MVVM")
        let items = await InterjectionBuffer.shared.drain(conversationId: id)
        XCTAssertEqual(items, ["stop and use MVVM"])
        let empty = await InterjectionBuffer.shared.drain(conversationId: id)
        XCTAssertTrue(empty.isEmpty)
    }

    func testInterjectionBufferMultiEnqueuePeekAndClear() async {
        let id = UUID()
        await InterjectionBuffer.shared.clear(conversationId: id)
        await InterjectionBuffer.shared.enqueue(conversationId: id, text: "  first  ")
        await InterjectionBuffer.shared.enqueue(conversationId: id, text: "")
        await InterjectionBuffer.shared.enqueue(conversationId: id, text: "second")
        let count = await InterjectionBuffer.shared.peekCount(conversationId: id)
        XCTAssertEqual(count, 2, "empty text must not enqueue")
        let peekAgain = await InterjectionBuffer.shared.peekCount(conversationId: id)
        XCTAssertEqual(peekAgain, 2, "peek must not consume")
        await InterjectionBuffer.shared.clear(conversationId: id)
        let peek0 = await InterjectionBuffer.shared.peekCount(conversationId: id)
        XCTAssertEqual(peek0, 0)
        let afterClear = await InterjectionBuffer.shared.drain(conversationId: id)
        XCTAssertTrue(afterClear.isEmpty)
    }

    func testHunkTrackerRecordsAgentEdits() async {
        await HunkTracker.shared.clear()
        // recordAgentEdit is origin-only (no thin TrackedHunk) — PA2.
        await HunkTracker.shared.recordAgentEdit(path: "/tmp/a.swift", summary: "edit_file")
        let origin = await HunkTracker.shared.classify(path: "/tmp/a.swift")
        XCTAssertEqual(origin, HunkTracker.Origin.agent)
        let recent = await HunkTracker.shared.recent(limit: 5)
        XCTAssertTrue(recent.isEmpty, "origin mark must not create ghost hunks")
        // Full restorable content still goes through record(_:)
        let hunk = TrackedHunk(
            conversationID: UUID(),
            path: "/tmp/a.swift",
            originalContent: "a",
            updatedContent: "b")
        await HunkTracker.shared.record(hunk)
        let recent2 = await HunkTracker.shared.recent(limit: 5)
        XCTAssertEqual(recent2.count, 1)
        await HunkTracker.shared.clear()
    }

    func testMemoryToolsRegistered() async {
        await ToolRegistry.shared.registerBuiltins()
        let names = await ToolRegistry.shared.registeredNames()
        XCTAssertTrue(names.contains("memory"), "\(names)")
        XCTAssertTrue(names.contains("memory_search"), "\(names)")
        XCTAssertTrue(names.contains("memory_get"), "\(names)")
        XCTAssertTrue(names.contains("find_symbol"), "\(names)")
    }
}
