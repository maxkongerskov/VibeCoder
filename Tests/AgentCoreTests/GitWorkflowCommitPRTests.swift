//
//  GitWorkflowCommitPRTests.swift
//
//  Product S3: git_commit + create_pull_request (gh) with honest failures.
//

import XCTest
@testable import AgentCore

final class GitWorkflowCommitPRTests: XCTestCase {

    private var repo: URL!

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-s3-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"])
        try runGit(["config", "user.email", "test@example.com"])
        try runGit(["config", "user.name", "S3 Test"])
    }

    override func tearDown() async throws {
        if let repo {
            try? FileManager.default.removeItem(at: repo)
        }
    }

    private func runGit(_ args: [String]) throws {
        let r = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git"] + args,
            workingDirectory: repo,
            timeout: 30)
        if r.exitCode != 0 {
            throw NSError(
                domain: "GitWorkflowCommitPRTests",
                code: Int(r.exitCode),
                userInfo: [NSLocalizedDescriptionKey: r.stderr + r.stdout])
        }
    }

    private func writeFile(_ name: String, _ contents: String) throws {
        let url = repo.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Commit

    func testCommitEmptyMessageFails() {
        let r = GitWorkflow.commit(message: "  ", workingDirectory: repo)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.message.lowercased().contains("empty"), r.message)
    }

    func testCommitCleanTreeFails() {
        let r = GitWorkflow.commit(message: "nothing", workingDirectory: repo)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.message.lowercased().contains("nothing")
                      || r.message.lowercased().contains("clean"),
                      r.message)
    }

    func testCommitStagesAndCreatesSHA() throws {
        try writeFile("hello.txt", "hello s3\n")
        let r = GitWorkflow.commit(message: "feat: add hello", workingDirectory: repo)
        XCTAssertTrue(r.success, r.display)
        XCTAssertTrue(r.message.lowercased().contains("commit"), r.message)

        let log = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "log", "-1", "--pretty=%s"],
            workingDirectory: repo,
            timeout: 10)
        XCTAssertEqual(log.exitCode, 0)
        XCTAssertTrue(log.stdout.contains("feat: add hello"), log.stdout)
    }

    func testGitCommitToolViaRegistry() async throws {
        try writeFile("tool.txt", "via tool\n")
        let ctx = ToolContext(
            projectRoot: repo,
            conversationID: UUID(),
            executionMode: .yolo)
        let result = try await ToolRegistry.shared.execute(
            name: "git_commit",
            arguments: ToolArguments(dictionary: [
                "message": "chore: tool commit",
            ]),
            context: ctx)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.lowercased().contains("commit"), result.content)
    }

    // MARK: - PR honesty

    func testCreatePREmptyTitleFails() {
        let r = GitWorkflow.createPullRequest(title: " ", workingDirectory: repo)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.message.lowercased().contains("title"), r.message)
    }

    func testCreatePRWithoutRemoteFailsHonestly() throws {
        // Fresh repo has no remote; gh may or may not be installed.
        try writeFile("a.txt", "a\n")
        _ = GitWorkflow.commit(message: "init", workingDirectory: repo)

        let r = GitWorkflow.createPullRequest(
            title: "Test PR",
            body: "body",
            workingDirectory: repo)
        XCTAssertFalse(r.success, "should fail without remote or without gh")
        let lower = r.display.lowercased()
        // Honest: either no gh or no remote (or both paths)
        XCTAssertTrue(
            lower.contains("gh")
                || lower.contains("remote")
                || lower.contains("not found")
                || lower.contains("install"),
            r.display)
    }

    func testCreatePullRequestToolRegistered() async {
        let names = await ToolRegistry.shared.registeredNames()
        XCTAssertTrue(names.contains("git_commit"))
        XCTAssertTrue(names.contains("create_pull_request"))
    }

    func testCreatePullRequestPushDefaultsFalse() {
        let desc = CreatePullRequestTool.schema.parameters.properties["push"]?.description ?? ""
        XCTAssertTrue(
            desc.lowercased().contains("default false"),
            "schema must not advertise push-by-default: \(desc)")
        XCTAssertTrue(
            CreatePullRequestTool.schema.description.lowercased().contains("does not push"),
            CreatePullRequestTool.schema.description)
        // Omitted `pushIfRemote` must not push: no remote → fail at remote
        // check, never "git push failed before opening PR".
        let r = GitWorkflow.createPullRequest(title: "No push default", workingDirectory: repo)
        XCTAssertFalse(r.success)
        XCTAssertFalse(
            r.message.lowercased().contains("git push failed before opening pr"),
            r.display)
    }

    func testResolveGHReturnsPathOrNil() {
        // Should not crash; may return path when gh installed.
        let path = GitWorkflow.resolveGH()
        if let path {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), path)
        }
    }

    func testPushCurrentBranchFailsWithoutRemote() throws {
        try writeFile("p.txt", "p\n")
        _ = GitWorkflow.commit(message: "init", workingDirectory: repo)
        let r = GitWorkflow.pushCurrentBranch(workingDirectory: repo)
        XCTAssertFalse(r.success)
        XCTAssertTrue(
            r.message.lowercased().contains("remote") || r.message.lowercased().contains("push"),
            r.message)
    }
}
