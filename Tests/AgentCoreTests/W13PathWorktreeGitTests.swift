//
//  W13PathWorktreeGitTests.swift
//  Wave C W13: worktree dirty/untracked, path confinement under worktree,
//  git tool fail-closed messaging, attachment content inject.
//

import XCTest
@testable import AgentCore

final class W13PathWorktreeGitTests: XCTestCase {

    // MARK: - Worktree isDirty includes untracked

    func testIsDirtyTrueForUntrackedOnly() throws {
        let project = try makeGitRepo(prefix: "vc-wt-dirty")
        defer { try? FileManager.default.removeItem(at: project) }

        let created = try WorktreeService.createOrReuseWorktree(
            projectFolder: project.path,
            conversationShortId: "deadbeef"
        )
        defer {
            try? WorktreeService.discard(
                worktreePath: created.path,
                branch: created.branch,
                projectFolder: project.path
            )
        }

        let secret = URL(fileURLWithPath: created.path)
            .appendingPathComponent("untracked-only.txt")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            WorktreeService.isDirty(worktree: created.path),
            "untracked files must count as dirty so merge commits them before remove"
        )
    }

    func testIsDirtyFalseOnCleanWorktree() throws {
        let project = try makeGitRepo(prefix: "vc-wt-clean")
        defer { try? FileManager.default.removeItem(at: project) }

        let created = try WorktreeService.createOrReuseWorktree(
            projectFolder: project.path,
            conversationShortId: "cafebabe"
        )
        defer {
            try? WorktreeService.discard(
                worktreePath: created.path,
                branch: created.branch,
                projectFolder: project.path
            )
        }

        XCTAssertFalse(WorktreeService.isDirty(worktree: created.path))
    }

    /// PA5: UI commit message must reach `git commit` / `git merge -m`,
    /// not be replaced by the silent "AgentCore work" default.
    func testMergeAndRemoveHonorsCommitMessage() throws {
        let project = try makeGitRepo(prefix: "vc-wt-merge-msg")
        defer { try? FileManager.default.removeItem(at: project) }

        let created = try WorktreeService.createOrReuseWorktree(
            projectFolder: project.path,
            conversationShortId: "msg00001"
        )

        let feature = URL(fileURLWithPath: created.path)
            .appendingPathComponent("feature.txt")
        try "hello from worktree".write(to: feature, atomically: true, encoding: .utf8)

        let custom = "PA5 honor merge message \(UUID().uuidString.prefix(8))"
        try WorktreeService.mergeAndRemove(
            worktreePath: created.path,
            branch: created.branch,
            projectFolder: project.path,
            commitMessage: custom
        )

        let log = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "log", "--oneline", "-10"],
            workingDirectory: project,
            timeout: 10
        )
        XCTAssertEqual(log.exitCode, 0, log.stderr)
        XCTAssertTrue(
            log.stdout.contains(custom),
            "expected custom commit message in main log, got:\n\(log.stdout)"
        )
        XCTAssertFalse(
            log.stdout.contains("AgentCore work"),
            "default message must not appear when UI provided one:\n\(log.stdout)"
        )
    }

    func testResolvedCommitMessageEmptyFallsBack() {
        XCTAssertEqual(
            WorktreeService.resolvedCommitMessage("  "),
            WorktreeService.defaultMergeCommitMessage
        )
        XCTAssertEqual(
            WorktreeService.resolvedCommitMessage("  ship it  "),
            "ship it"
        )
    }

    func testCreateOrReuseRejectsStaleNonGitDirectory() throws {
        let project = try makeGitRepo(prefix: "vc-wt-stale")
        defer { try? FileManager.default.removeItem(at: project) }

        let shortId = "stale001"
        let stalePath = "\(project.path)-agentcore-\(shortId)"
        try FileManager.default.createDirectory(
            atPath: stalePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: stalePath) }

        // Write a dummy file so it isn't a git repo
        try "not-git".write(
            to: URL(fileURLWithPath: stalePath).appendingPathComponent("x.txt"),
            atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try WorktreeService.createOrReuseWorktree(
                projectFolder: project.path,
                conversationShortId: shortId)
        ) { err in
            guard let we = err as? WorktreeError else {
                return XCTFail("expected WorktreeError, got \(err)")
            }
            XCTAssertTrue("\(we)".contains("not a git") || we.localizedDescription.contains("not a git"))
        }
    }

    // MARK: - Path confinement: worktree-only when active

    func testWorktreeModeDeniesWriteToMainProjectRoot() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vc-confine-proj-\(UUID().uuidString)", isDirectory: true)
        let worktree = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vc-confine-wt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: worktree)
        }

        let ctx = ToolContext(
            projectRoot: project,
            worktreeRoot: worktree,
            conversationID: UUID(),
            executionMode: .yolo,
            authorization: AuthorizationConfig(useInlineRememberedOnly: true)
        )

        // Absolute path into main project must be denied while worktree is active.
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "write_file",
                arguments: ToolArguments(dictionary: [
                    "path": project.appendingPathComponent("leak.txt").path,
                    "content": "should-not-land-in-main",
                ]),
                context: ctx)
            XCTFail("expected denial for main project path under worktree isolation")
        } catch let e as ToolError {
            guard case .permissionDenied = e else {
                return XCTFail("expected permissionDenied, got \(e)")
            }
        }

        // Worktree path still allowed.
        let ok = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": worktree.appendingPathComponent("ok.txt").path,
                "content": "ok",
            ]),
            context: ctx)
        XCTAssertFalse(ok.isError, ok.content)
    }

    // MARK: - Git tools fail-closed

    func testGitStatusNotCleanOnNonRepo() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vc-nongit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ctx = ToolContext(
            projectRoot: dir,
            conversationID: UUID(),
            authorization: AuthorizationConfig(useInlineRememberedOnly: true)
        )
        let result = try await ToolRegistry.shared.execute(
            name: "git_status",
            arguments: ToolArguments(dictionary: [:]),
            context: ctx)
        XCTAssertTrue(result.isError)
        XCTAssertFalse(
            result.content.trimmingCharacters(in: .whitespacesAndNewlines) == "(clean)",
            "must not report (clean) when git fails: \(result.content)"
        )
    }

    // MARK: - Attachments include content

    func testAttachmentFormatterIncludesFileBody() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vc-attach-\(UUID().uuidString).swift")
        try "func hello() {}".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let composed = ContextAttachmentFormatter.composeUserMessage(
            text: "Please fix",
            attachments: [
                ContextAttachment(path: file.path, displayName: "Hello.swift", byteSize: 16)
            ]
        )
        XCTAssertTrue(composed.contains("func hello() {}"), composed)
        XCTAssertTrue(composed.contains("```"), composed)
        XCTAssertTrue(composed.contains("Please fix"))
    }

    func testAttachmentFormatterTruncatesLargeFiles() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vc-attach-big-\(UUID().uuidString).txt")
        let body = String(repeating: "A", count: 1000)
        try body.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let composed = ContextAttachmentFormatter.composeUserMessage(
            text: "q",
            attachments: [ContextAttachment(path: file.path, displayName: "big.txt")],
            maxBytesPerFile: 50
        )
        XCTAssertTrue(composed.contains("truncated") || composed.contains("…"), composed)
    }

    // MARK: - Helpers

    private func makeGitRepo(prefix: String) throws -> URL {
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let initR = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "init"],
            workingDirectory: project,
            timeout: 10)
        XCTAssertEqual(initR.exitCode, 0, initR.stderr)
        _ = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "config", "user.email", "test@example.com"],
            workingDirectory: project, timeout: 5)
        _ = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "config", "user.name", "Test"],
            workingDirectory: project, timeout: 5)
        try "readme".write(
            to: project.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        let add = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "add", "README.md"],
            workingDirectory: project, timeout: 5)
        XCTAssertEqual(add.exitCode, 0, add.stderr)
        let commit = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "commit", "-m", "init"],
            workingDirectory: project, timeout: 10)
        XCTAssertEqual(commit.exitCode, 0, commit.stderr)
        return project
    }
}
