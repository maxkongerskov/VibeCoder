//
//  ConversationTests.swift
//
//  Tests for the derived helpers on `Conversation` — specifically
//  `worktreeRootURL`, which AgentLoop uses to route mutating tool
//  calls into the isolated checkout when worktree mode is on. The
//  derivation is a string-manipulation joint with the convention
//  `<projectPath>-agentcore-<shortid>`; getting it wrong silently
//  routes writes to the user's main tree (the bug #86 fixed).
//

import XCTest
@testable import AgentCore

final class ConversationWorktreeRootURLTests: XCTestCase {

    func testReturnsNilWhenProjectRootIsNil() {
        var c = Conversation()
        c.projectRoot = nil
        c.worktreeBranch = "agentcore/abc12345"
        XCTAssertNil(c.worktreeRootURL)
    }

    func testReturnsNilWhenWorktreeBranchIsNil() {
        var c = Conversation()
        c.projectRoot = URL(fileURLWithPath: "/Users/m/Projects/foo")
        c.worktreeBranch = nil
        XCTAssertNil(c.worktreeRootURL)
    }

    /// Daily-driver: binding a git project isolates without `enableWorktree`.
    func testBoundProjectIsolatesInWorktreeByDefault() throws {
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vc-bound-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        func git(_ args: [String]) -> ShellResult {
            ShellRunner.run(
                executable: "/usr/bin/env",
                arguments: ["git"] + args,
                workingDirectory: project,
                timeout: 15)
        }
        XCTAssertEqual(git(["init"]).exitCode, 0)
        _ = git(["config", "user.email", "test@example.com"])
        _ = git(["config", "user.name", "Test"])
        try "readme".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(git(["add", "README.md"]).exitCode, 0)
        XCTAssertEqual(git(["commit", "-m", "init"]).exitCode, 0)

        var convo = Conversation()
        let result = try WorktreeService.bindProjectEnablingWorktree(
            &convo, projectRoot: project)
        guard case .enabled(let created) = result else {
            return XCTFail("bound git project must isolate by default, got \(result)")
        }
        defer {
            try? WorktreeService.discard(
                worktreePath: created.path,
                branch: created.branch,
                projectFolder: project.path)
        }
        XCTAssertNotNil(convo.worktreeRootURL)
        XCTAssertEqual(convo.worktreeRootURL?.path, created.path)
        XCTAssertFalse(convo.worktreeOptOut)
    }

    func testWorktreeOptOutMissingInJSONDefaultsFalse() throws {
        var c = Conversation()
        c.projectRoot = URL(fileURLWithPath: "/tmp/proj")
        c.worktreeBranch = nil
        let data = try JSONEncoder().encode(c)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "worktreeOptOut")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let loaded = try JSONDecoder().decode(Conversation.self, from: stripped)
        XCTAssertFalse(loaded.worktreeOptOut)
    }

    func testReturnsNilWhenWorktreeBranchIsEmpty() {
        var c = Conversation()
        c.projectRoot = URL(fileURLWithPath: "/Users/m/Projects/foo")
        c.worktreeBranch = ""
        XCTAssertNil(c.worktreeRootURL)
    }

    func testDerivesPathFromBranchSuffix() {
        var c = Conversation()
        c.projectRoot = URL(fileURLWithPath: "/Users/m/Projects/foo")
        c.worktreeBranch = "agentcore/abc12345"
        XCTAssertEqual(c.worktreeRootURL?.path, "/Users/m/Projects/foo-agentcore-abc12345")
    }

    func testStripsTrailingSlashFromProjectRoot() {
        // URL(fileURLWithPath:) often normalizes trailing slashes but
        // belt-and-suspenders: a path passed straight from user code
        // could carry one and the suffix-append must still produce a
        // sensible result.
        var c = Conversation()
        c.projectRoot = URL(fileURLWithPath: "/Users/m/Projects/foo/")
        c.worktreeBranch = "agentcore/abc12345"
        let path = c.worktreeRootURL?.path ?? ""
        XCTAssertFalse(path.contains("foo/-agentcore-"),
                       "Trailing slash must be stripped before appending the suffix; got: \(path)")
        XCTAssertEqual(path, "/Users/m/Projects/foo-agentcore-abc12345")
    }

    func testFallsBackToWholeBranchWhenNoSlash() {
        // Defensive — if the branch convention changes (no `agentcore/`
        // prefix), use the whole branch as the shortid rather than
        // returning nil.
        var c = Conversation()
        c.projectRoot = URL(fileURLWithPath: "/Users/m/Projects/foo")
        c.worktreeBranch = "feature-experiment"
        XCTAssertEqual(c.worktreeRootURL?.path,
                       "/Users/m/Projects/foo-agentcore-feature-experiment")
    }

    func testNonGitProjectStillProducesPath() {
        // worktreeRootURL doesn't validate that the resulting path
        // exists or that projectRoot is a git repo — that's the
        // WorktreeService's job. Pure string derivation.
        var c = Conversation()
        c.projectRoot = URL(fileURLWithPath: "/tmp/test-project")
        c.worktreeBranch = "agentcore/xyz"
        XCTAssertEqual(c.worktreeRootURL?.path, "/tmp/test-project-agentcore-xyz")
    }
}
