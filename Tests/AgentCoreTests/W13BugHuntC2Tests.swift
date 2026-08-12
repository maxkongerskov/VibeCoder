//
//  W13BugHuntC2Tests.swift
//  Wave C2 — worktree review untracked content, status path quoting,
//  resolvePath normalization, project file dotfile allowlist.
//

import XCTest
@testable import AgentCore

final class W13BugHuntC2Tests: XCTestCase {

    // MARK: - O3 / status quotes

    func testParseStatusShortUnquotesSpacedPaths() {
        let raw = """
        ?? "my file.txt"
         M Sources/Foo.swift
        """
        let map = WorktreeDiffParser.parseStatusShort(raw)
        XCTAssertEqual(map["my file.txt"], .added)
        XCTAssertNil(map["\"my file.txt\""])
        XCTAssertEqual(map["Sources/Foo.swift"], .modified)
    }

    func testUnquoteGitPath() {
        XCTAssertEqual(WorktreeDiffParser.unquoteGitPath(#""a b""#), "a b")
        XCTAssertEqual(WorktreeDiffParser.unquoteGitPath("plain"), "plain")
    }

    func testEnrichUntrackedContentLoadsBody() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-c2-untracked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("new.swift")
        try "let x = 1\nlet y = 2\n".write(to: file, atomically: true, encoding: .utf8)

        let bare = WorktreeDiffParser.FileChange(
            path: "new.swift",
            kind: .added,
            linesAdded: 0,
            linesRemoved: 0,
            diffLines: []
        )
        let enriched = WorktreeDiffParser.enrichUntrackedContent([bare], worktreeRoot: dir.path)
        XCTAssertEqual(enriched.count, 1)
        XCTAssertFalse(enriched[0].diffLines.isEmpty)
        XCTAssertTrue(enriched[0].diffLines.contains { $0.text.contains("let x = 1") })
        XCTAssertGreaterThan(enriched[0].linesAdded, 0)
    }

    func testReviewChangesIncludesUntrackedBody() throws {
        let project = try makeGitRepo(prefix: "vc-c2-review")
        defer { try? FileManager.default.removeItem(at: project) }
        let created = try WorktreeService.createOrReuseWorktree(
            projectFolder: project.path,
            conversationShortId: "c2rev001"
        )
        defer {
            try? WorktreeService.discard(
                worktreePath: created.path,
                branch: created.branch,
                projectFolder: project.path
            )
        }
        let wt = URL(fileURLWithPath: created.path)
        try "func brandNew() {}".write(
            to: wt.appendingPathComponent("BrandNew.swift"),
            atomically: true, encoding: .utf8)

        let changes = WorktreeService.reviewChanges(worktreePath: created.path)
        let hit = changes.first { $0.path.contains("BrandNew") }
        XCTAssertNotNil(hit, "status should list untracked BrandNew.swift: \(changes.map(\.path))")
        XCTAssertEqual(hit?.kind, .added)
        XCTAssertTrue(
            hit?.diffLines.contains(where: { $0.text.contains("brandNew") }) == true,
            "expected file body in review: \(String(describing: hit?.diffLines))"
        )
    }

    // MARK: - resolvePath

    func testResolvePathNormalizesDotDot() {
        let base = URL(fileURLWithPath: "/tmp/project/src")
        let resolved = resolvePath("../Secrets/key", base: base)
        XCTAssertEqual(resolved.path, "/tmp/project/Secrets/key")
    }

    func testResolvePathEmptyIsBase() {
        let base = URL(fileURLWithPath: "/tmp/project")
        XCTAssertEqual(resolvePath("", base: base).path, base.standardizedFileURL.path)
        XCTAssertEqual(resolvePath("  ", base: base).path, base.standardizedFileURL.path)
    }

    // MARK: - ProjectFileIndex dotfiles

    func testListFilesKeepsEnvAndGitignore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-c2-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "SECRET=1".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "node_modules".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "skip".write(to: root.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try "ok".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let files = ProjectFileIndex.listFiles(root: root)
        let names = Set(files.map(\.displayName))
        XCTAssertTrue(names.contains(".env"), "\(names)")
        XCTAssertTrue(names.contains(".gitignore"), "\(names)")
        XCTAssertTrue(names.contains("main.swift"), "\(names)")
        XCTAssertFalse(names.contains(".DS_Store"), "\(names)")
    }

    // MARK: - Helpers

    private func makeGitRepo(prefix: String) throws -> URL {
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func git(_ args: [String]) -> ShellResult {
            ShellRunner.run(
                executable: "/usr/bin/env",
                arguments: ["git"] + args,
                workingDirectory: project,
                timeout: 15)
        }
        XCTAssertEqual(git(["init"]).exitCode, 0)
        _ = git(["config", "user.email", "t@example.com"])
        _ = git(["config", "user.name", "T"])
        try "r".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(git(["add", "README.md"]).exitCode, 0)
        XCTAssertEqual(git(["commit", "-m", "i"]).exitCode, 0)
        return project
    }
}
