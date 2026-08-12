//
//  BugHuntPhaseAHunkLedgerTests.swift
//
//  Phase A PA2 — single TrackedHunk source of truth.
//  Registry must not append empty-original siblings next to tool-recorded hunks.
//

import XCTest
@testable import AgentCore

final class BugHuntPhaseAHunkLedgerTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await HunkTracker.shared.clear()
        await RememberedGrants.shared.clear()
    }

    override func tearDown() async throws {
        await HunkTracker.shared.clear()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pa2-hunk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - write_file via registry → exactly one full hunk; reject works

    func testWriteFileViaRegistryExactlyOneFullHunkAndReject() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ledger.swift")
        try "original-body".write(to: file, atomically: true, encoding: .utf8)
        let convo = UUID()
        let context = ToolContext(
            projectRoot: root,
            conversationID: convo,
            executionMode: .yolo,
            sessionReadPaths: [SafeModeConfig.normalizePath(file.path)])

        let result = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": file.path,
                "content": "changed-body",
            ]),
            context: context)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("hunk_id="), result.content)

        let hunks = await HunkTracker.shared.hunks(for: convo)
        XCTAssertEqual(
            hunks.count, 1,
            "ghost double bookkeeping: expected 1 full hunk, got \(hunks.map { "orig=\($0.originalContent.prefix(20)) upd=\($0.updatedContent.prefix(20))" })")
        let hunk = hunks[0]
        XCTAssertEqual(hunk.originalContent, "original-body")
        XCTAssertEqual(hunk.updatedContent, "changed-body")
        XCTAssertNotEqual(hunk.updatedContent, "write_file",
                          "must not be thin registry sibling")

        // Origin still classified as agent via recordAgentPath.
        let origin = await HunkTracker.shared.classify(path: file.path)
        XCTAssertEqual(origin, .agent)

        let ok = try await HunkTracker.shared.reject(id: hunk.id)
        XCTAssertTrue(ok, "reject must roll back full-content hunk")
        let body = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(body, "original-body")
    }

    // MARK: - apply_patch includes hunk_id; single full hunk; reject

    func testApplyPatchEmitsHunkIDAndSingleFullHunk() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("p.swift")
        try "line1\nline2\n".write(to: file, atomically: true, encoding: .utf8)
        let convo = UUID()
        let context = ToolContext(
            projectRoot: root,
            conversationID: convo,
            executionMode: .yolo,
            sessionReadPaths: [SafeModeConfig.normalizePath(file.path)])

        let patch = """
        --- a/p.swift
        +++ b/p.swift
        @@ -1,2 +1,2 @@
         line1
        -line2
        +line2-patched
        """
        let result = try await ToolRegistry.shared.execute(
            name: "apply_patch",
            arguments: ToolArguments(dictionary: ["patch": patch]),
            context: context)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(
            result.content.range(of: #"hunk_id=[0-9A-Fa-f-]{36}"#, options: .regularExpression) != nil,
            "apply_patch success must include hunk_id UUID: \(result.content)")

        let hunks = await HunkTracker.shared.hunks(for: convo)
        XCTAssertEqual(hunks.count, 1, "expected one full hunk, got \(hunks.count)")
        let hunk = hunks[0]
        XCTAssertTrue(hunk.originalContent.contains("line2"))
        XCTAssertTrue(hunk.updatedContent.contains("line2-patched"))
        XCTAssertTrue(result.content.contains(hunk.id.uuidString), result.content)

        let ok = try await HunkTracker.shared.reject(id: hunk.id)
        XCTAssertTrue(ok)
        let body = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(body, "line1\nline2\n")
    }

    // MARK: - recordAgentPath does not invent ledger rows

    func testRecordAgentPathDoesNotCreateTrackedHunk() async {
        let path = "/tmp/pa2-origin-only-\(UUID().uuidString)"
        await HunkTracker.shared.recordAgentPath(path)
        let recent = await HunkTracker.shared.recent(limit: 50)
        XCTAssertFalse(recent.contains { $0.path == path })
        let origin = await HunkTracker.shared.classify(path: path)
        XCTAssertEqual(origin, .agent)
    }
}
