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
