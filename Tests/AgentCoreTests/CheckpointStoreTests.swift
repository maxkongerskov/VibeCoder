//
//  CheckpointStoreTests.swift
//  Phase A PA4 — filesystem turn checkpoints + restore.
//

import XCTest
@testable import AgentCore

final class CheckpointStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: CheckpointStore!
    private var conversationID: UUID!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckpt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let ckptDir = tempRoot.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: ckptDir, withIntermediateDirectories: true)
        store = CheckpointStore(rootDirectory: ckptDir)
        conversationID = UUID()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Snapshot + restore content

    func testSnapshotAndRestoreOverwritesAgentEdit() async throws {
        let file = tempRoot.appendingPathComponent("hello.txt")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)

        let turnID = await store.beginTurn(conversationID: conversationID, projectRoot: tempRoot)
        XCTAssertNotNil(turnID)

        await store.snapshotPath(file, conversationID: conversationID)

        // Agent mutates
        try "agent was here\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "agent was here\n")

        let report = await store.restoreLatest(conversationID: conversationID)
        XCTAssertEqual(report.turnID, turnID)
        XCTAssertEqual(report.restoredPaths.count, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original\n")
        XCTAssertTrue(report.statusSummary.contains("restored"), report.statusSummary)
    }

    func testCreatedFileRemovedOnRestore() async throws {
        let file = tempRoot.appendingPathComponent("new-file.swift")
        // File does not exist yet.
        _ = await store.beginTurn(conversationID: conversationID)

        await store.snapshotPath(file, conversationID: conversationID)
        try "created by agent".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let report = await store.restoreLatest(conversationID: conversationID)
        XCTAssertEqual(report.deletedPaths.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMultiFileCheckpoint() async throws {
        let a = tempRoot.appendingPathComponent("a.txt")
        let b = tempRoot.appendingPathComponent("b.txt")
        try "A0".write(to: a, atomically: true, encoding: .utf8)
        try "B0".write(to: b, atomically: true, encoding: .utf8)

        _ = await store.beginTurn(conversationID: conversationID)
        await store.snapshotPath(a, conversationID: conversationID)
        await store.snapshotPath(b, conversationID: conversationID)

        try "A1".write(to: a, atomically: true, encoding: .utf8)
        try "B1".write(to: b, atomically: true, encoding: .utf8)

        let report = await store.restoreLatest(conversationID: conversationID)
        XCTAssertEqual(report.restoredPaths.count, 2)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A0")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "B0")
    }

    func testFirstSnapshotWinsWithinTurn() async throws {
        let file = tempRoot.appendingPathComponent("once.txt")
        try "v1".write(to: file, atomically: true, encoding: .utf8)
        _ = await store.beginTurn(conversationID: conversationID)
        await store.snapshotPath(file, conversationID: conversationID)
        try "v2".write(to: file, atomically: true, encoding: .utf8)
        // Second snapshot must not replace pre-state with mid-turn content.
        await store.snapshotPath(file, conversationID: conversationID)
        try "v3".write(to: file, atomically: true, encoding: .utf8)

        _ = await store.restoreLatest(conversationID: conversationID)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "v1")
    }

    func testNoCheckpointMessage() async {
        let report = await store.restoreLatest(conversationID: conversationID)
        XCTAssertNil(report.turnID)
        XCTAssertTrue(report.statusSummary.lowercased().contains("no file checkpoint")
            || report.message.lowercased().contains("no file"), report.statusSummary)
    }

    func testRestoredTurnNotRestoredTwice() async throws {
        let file = tempRoot.appendingPathComponent("once-restore.txt")
        try "orig".write(to: file, atomically: true, encoding: .utf8)
        _ = await store.beginTurn(conversationID: conversationID)
        await store.snapshotPath(file, conversationID: conversationID)
        try "mut".write(to: file, atomically: true, encoding: .utf8)

        let first = await store.restoreLatest(conversationID: conversationID)
        XCTAssertEqual(first.restoredPaths.count, 1)

        try "mut2".write(to: file, atomically: true, encoding: .utf8)
        let second = await store.restoreLatest(conversationID: conversationID)
        // Already marked restored and empty unrestored turns → no restore.
        XCTAssertEqual(second.restoredPaths.count, 0, second.statusSummary)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "mut2")
    }

    // MARK: - ToolRegistry hook

    func testToolRegistrySnapshotsBeforeWriteFile() async throws {
        let project = tempRoot.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("tracked.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)

        // Use isolated store via beginTurn on shared — tests share shared actor;
        // use unique conversation id so we don't collide.
        let convo = UUID()
        _ = await CheckpointStore.shared.beginTurn(conversationID: convo, projectRoot: project)
        defer {
            Task { await CheckpointStore.shared.clear(conversationID: convo) }
        }

        await ToolRegistry.shared.registerBuiltins()
        let ctx = ToolContext(
            projectRoot: project,
            worktreeRoot: nil,
            safeMode: nil,
            conversationID: convo,
            sessionReadPaths: [file.path]
        )
        let result = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": "tracked.txt",
                "content": "after-agent",
            ]),
            context: ctx
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after-agent")

        let report = await CheckpointStore.shared.restoreLatest(conversationID: convo)
        XCTAssertGreaterThanOrEqual(report.restoredPaths.count, 1, report.statusSummary)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before")
    }

    // MARK: - restore_checkpoint tool

    func testRestoreCheckpointTool() async throws {
        let project = tempRoot.appendingPathComponent("proj2", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("t.txt")
        try "keep-me".write(to: file, atomically: true, encoding: .utf8)

        let convo = UUID()
        _ = await CheckpointStore.shared.beginTurn(conversationID: convo, projectRoot: project)
        await CheckpointStore.shared.snapshotPath(file, conversationID: convo)
        try "changed".write(to: file, atomically: true, encoding: .utf8)

        await ToolRegistry.shared.registerBuiltins()
        let ctx = ToolContext(
            projectRoot: project,
            conversationID: convo
        )
        let result = try await ToolRegistry.shared.execute(
            name: "restore_checkpoint",
            arguments: ToolArguments(dictionary: [:]),
            context: ctx
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep-me")
        await CheckpointStore.shared.clear(conversationID: convo)
    }

    func testResolveTargetPathsApplyPatch() {
        let base = tempRoot!
        // UnifiedDiff format (same as ApplyPatchTool / UnifiedDiff.parse).
        let patch = """
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,1 +1,1 @@
        -a
        +b
        """
        let urls = CheckpointStore.resolveTargetPaths(
            toolName: "apply_patch",
            arguments: ToolArguments(dictionary: ["patch": patch]),
            workingDirectory: base
        )
        XCTAssertTrue(urls.contains { $0.lastPathComponent == "foo.swift" }, "\(urls)")
    }

    func testPersistAndReloadFromDisk() async throws {
        let file = tempRoot.appendingPathComponent("persist.txt")
        try "disk-orig".write(to: file, atomically: true, encoding: .utf8)

        let ckptDir = tempRoot.appendingPathComponent("checkpoints2", isDirectory: true)
        try FileManager.default.createDirectory(at: ckptDir, withIntermediateDirectories: true)
        let s1 = CheckpointStore(rootDirectory: ckptDir)
        let convo = UUID()
        let turnID = await s1.beginTurn(conversationID: convo)
        await s1.snapshotPath(file, conversationID: convo)
        try "mutated".write(to: file, atomically: true, encoding: .utf8)

        // New store instance — memory empty, disk has turn.
        let s2 = CheckpointStore(rootDirectory: ckptDir)
        let report = await s2.restore(turnID: turnID, conversationID: convo)
        XCTAssertEqual(report.restoredPaths.count, 1, report.statusSummary)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "disk-orig")
    }
}
