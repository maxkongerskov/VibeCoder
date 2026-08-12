//
//  BugHuntW02EditSurfaceTests.swift
//
//  Wave C W02 — regression tests for edit_file / write_file / apply_patch /
//  PathConfinement / SessionReadTracker / HunkTracker bug fixes.
//

import XCTest
@testable import AgentCore

final class BugHuntW02EditSurfaceTests: XCTestCase {

    private var root: URL!
    private var registry: ToolRegistry!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-w02-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        registry = ToolRegistry.shared
        await registry.registerBuiltins()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func ctx(preRead: [URL] = [], conversationID: UUID = UUID(),
                     remembered: [GrantKey: GrantDecision] = [:]) -> ToolContext {
        let reads = Set(preRead.map { SafeModeConfig.normalizePath($0.path) })
        return ToolContext(
            projectRoot: root,
            conversationID: conversationID,
            executionMode: .yolo,
            authorization: AuthorizationConfig(
                remembered: remembered,
                useInlineRememberedOnly: true
            ),
            sessionReadPaths: reads
        )
    }

    // MARK: - ToolArguments.bool string coercion

    func testBoolCoercesStringTrueFalse() {
        let t = ToolArguments(dictionary: ["replace_all": "true", "partial_ok": "yes"])
        XCTAssertTrue(t.bool("replace_all"))
        XCTAssertTrue(t.bool("partial_ok"))
        let f = ToolArguments(dictionary: ["replace_all": "false", "n": "0"])
        XCTAssertFalse(f.bool("replace_all"))
        XCTAssertFalse(f.bool("n"))
        let missing = ToolArguments(dictionary: [:])
        XCTAssertFalse(missing.bool("x", default: false))
        XCTAssertTrue(missing.bool("x", default: true))
    }

    func testEditFileReplaceAllFromStringBool() async throws {
        let file = root.appendingPathComponent("r.swift")
        try "foo\nbar\nfoo\n".write(to: file, atomically: true, encoding: .utf8)
        let edits = """
        <<<<<<< SEARCH
        foo
        =======
        baz
        >>>>>>> REPLACE
        """
        let result = try await registry.execute(
            name: "edit_file",
            arguments: ToolArguments(dictionary: [
                "path": "r.swift",
                "edits": edits,
                "replace_all": "true",
            ]),
            context: ctx(preRead: [file]))
        XCTAssertFalse(result.isError, result.content)
        let body = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(body.components(separatedBy: "baz").count - 1, 2)
    }

    // MARK: - No-op SEARCH/REPLACE

    func testEditFileNoOpIdenticalSearchReplace() async throws {
        let file = root.appendingPathComponent("noop.swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let edits = """
        <<<<<<< SEARCH
        let x = 1
        =======
        let x = 1
        >>>>>>> REPLACE
        """
        let result = try await registry.execute(
            name: "edit_file",
            arguments: ToolArguments(dictionary: ["path": "noop.swift", "edits": edits]),
            context: ctx(preRead: [file]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("no changes"), result.content)
        XCTAssertTrue(result.mutatedPaths.isEmpty)
    }

    // MARK: - Durable grant honored by body confinement

    func testWriteOutsideProjectAllowedWithInlinePathGrant() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-outside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }

        // Without grant: denied
        let denied = try? await registry.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": outside.path,
                "content": "pwn",
            ]),
            context: ctx())
        // May throw permissionDenied or return error depending on path
        if let denied {
            XCTAssertTrue(denied.isError || denied.content.lowercased().contains("outside")
                          || denied.content.lowercased().contains("permission"),
                          denied.content)
        }

        let projectKey = RememberedGrants.projectKey(from: ctx())
        let fp = PathConfinement.pathGrantFingerprint(outside)
        let key = GrantKey(
            projectKey: projectKey,
            toolName: RememberedGrants.pathGrantToolName,
            commandFingerprint: fp
        )
        // New file outside — RBE not required; grant should allow confinement.
        do {
            let ok = try await registry.execute(
                name: "write_file",
                arguments: ToolArguments(dictionary: [
                    "path": outside.path,
                    "content": "ok-grant",
                ]),
                context: ctx(remembered: [key: .allow]))
            XCTAssertFalse(ok.isError, ok.content)
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "ok-grant")
        } catch {
            // If ToolAuthorization hard-denies before body, still document —
            // body path uses requireInsideWorkspaceAsync which must honor grant.
            XCTFail("expected grant to allow write: \(error)")
        }
    }

    // MARK: - HunkTracker discard + reject drift

    func testHunkDiscardRemovesWithoutDiskWrite() async throws {
        let convo = UUID()
        let file = root.appendingPathComponent("h.txt")
        try "orig".write(to: file, atomically: true, encoding: .utf8)
        let hunk = TrackedHunk(
            conversationID: convo,
            path: file.path,
            originalContent: "orig",
            updatedContent: "new")
        await HunkTracker.shared.record(hunk)
        let count1 = await HunkTracker.shared.hunks(for: convo).count
        XCTAssertEqual(count1, 1)
        await HunkTracker.shared.discard(id: hunk.id)
        let count0 = await HunkTracker.shared.hunks(for: convo).count
        XCTAssertEqual(count0, 0)
        // Disk untouched by discard
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "orig")
        await HunkTracker.shared.clear(conversationID: convo)
    }

    func testHunkRejectFailsClosedWhenFileDrifted() async throws {
        let convo = UUID()
        let file = root.appendingPathComponent("drift.txt")
        try "agent-new".write(to: file, atomically: true, encoding: .utf8)
        let hunk = TrackedHunk(
            conversationID: convo,
            path: file.path,
            originalContent: "orig",
            updatedContent: "agent-new")
        await HunkTracker.shared.record(hunk)
        // User edits after agent
        try "user-changed".write(to: file, atomically: true, encoding: .utf8)
        let ok = try await HunkTracker.shared.reject(id: hunk.id)
        XCTAssertFalse(ok, "must not clobber user edit")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user-changed")
        await HunkTracker.shared.clear(conversationID: convo)
    }

    func testHunkRejectSucceedsWhenFileStillAgentVersion() async throws {
        let convo = UUID()
        let file = root.appendingPathComponent("ok-reject.txt")
        try "agent-new".write(to: file, atomically: true, encoding: .utf8)
        let hunk = TrackedHunk(
            conversationID: convo,
            path: file.path,
            originalContent: "orig",
            updatedContent: "agent-new")
        await HunkTracker.shared.record(hunk)
        let ok = try await HunkTracker.shared.reject(id: hunk.id)
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "orig")
        await HunkTracker.shared.clear(conversationID: convo)
    }

    func testRecordAgentPathMarksOriginWithoutHunk() async {
        let convo = UUID()
        await HunkTracker.shared.recordAgentPath("/tmp/x")
        // Origin-only bookkeeping — no restorable TrackedHunk row (PA2).
        let list = await HunkTracker.shared.hunks(for: convo)
        XCTAssertTrue(list.isEmpty)
        let origin = await HunkTracker.shared.classify(path: "/tmp/x")
        XCTAssertEqual(origin, .agent)
        await HunkTracker.shared.clear()
    }

    // MARK: - SessionReadTracker

    func testSessionReadNormalizesPaths() async {
        let convo = UUID()
        let file = root.appendingPathComponent("s.swift")
        try? "x".write(to: file, atomically: true, encoding: .utf8)
        await SessionReadTracker.shared.recordRead(path: file.path, conversationID: convo)
        let ok = await SessionReadTracker.shared.hasSessionRead(
            path: file.path,
            conversationID: convo,
            sessionReadPaths: [])
        XCTAssertTrue(ok)
        await SessionReadTracker.shared.clear(conversationID: convo)
    }

    // MARK: - Non-overlapping count helper

    func testNonOverlappingCount() {
        XCTAssertEqual(EditFileTool.nonOverlappingCount(of: "a", in: "aaa"), 3)
        XCTAssertEqual(EditFileTool.nonOverlappingCount(of: "aa", in: "aaa"), 1)
        XCTAssertEqual(EditFileTool.nonOverlappingCount(of: "xyz", in: "aaa"), 0)
        XCTAssertEqual(EditFileTool.nonOverlappingCount(of: "", in: "aaa"), 0)
    }

    // MARK: - User journey: read → edit → verify

    func testUserJourneyReadEditVerify() async throws {
        let file = root.appendingPathComponent("Journey.swift")
        try "func f() { return 1 }\n".write(to: file, atomically: true, encoding: .utf8)
        let convo = UUID()
        let context = ctx(conversationID: convo)

        // Full line SEARCH (applier is line-oriented).
        let edits = """
        <<<<<<< SEARCH
        func f() { return 1 }
        =======
        func f() { return 2 }
        >>>>>>> REPLACE
        """

        // Without read: edit denied
        let denied = try await registry.execute(
            name: "edit_file",
            arguments: ToolArguments(dictionary: [
                "path": "Journey.swift",
                "edits": edits,
            ]),
            context: context)
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(denied.content.lowercased().contains("read-before-edit"), denied.content)

        // read_file
        let read = try await registry.execute(
            name: "read_file",
            arguments: ToolArguments(dictionary: ["path": "Journey.swift"]),
            context: context)
        XCTAssertFalse(read.isError, read.content)

        // edit
        let edited = try await registry.execute(
            name: "edit_file",
            arguments: ToolArguments(dictionary: [
                "path": "Journey.swift",
                "edits": edits,
            ]),
            context: context)
        XCTAssertFalse(edited.isError, edited.content)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("return 2"))
        XCTAssertTrue(edited.content.contains("hunk_id="))

        // Hunk recorded for conversation
        let hunks = await HunkTracker.shared.hunks(for: convo)
        XCTAssertFalse(hunks.isEmpty)
        await HunkTracker.shared.clear(conversationID: convo)
    }
}
