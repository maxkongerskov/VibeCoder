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

    // MARK: - Default worktree on git bind

    func testBindGitProjectEnablesWorktreeAndConfinesCommit() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let project = try makeGitRepo(prefix: "vc-bind-git")
        defer { try? FileManager.default.removeItem(at: project) }

        var convo = Conversation()
        let result = try WorktreeService.bindProjectEnablingWorktree(
            &convo, projectRoot: project)
        guard case .enabled(let created) = result else {
            return XCTFail("expected enabled worktree, got \(result)")
        }
        defer {
            try? WorktreeService.discard(
                worktreePath: created.path,
                branch: created.branch,
                projectFolder: project.path)
        }

        XCTAssertEqual(convo.projectRoot?.path, project.path)
        XCTAssertEqual(convo.worktreeBranch, created.branch)
        XCTAssertEqual(convo.worktreeRootURL?.path, created.path)

        // Dirty main only — commit must not stage it while worktree is on.
        try "main-only".write(
            to: project.appendingPathComponent("main-only.txt"),
            atomically: true, encoding: .utf8)
        try "wt-only".write(
            to: URL(fileURLWithPath: created.path).appendingPathComponent("wt-only.txt"),
            atomically: true, encoding: .utf8)

        let ctx = ToolContext(
            projectRoot: project,
            worktreeRoot: URL(fileURLWithPath: created.path),
            conversationID: convo.id,
            executionMode: .yolo,
            authorization: AuthorizationConfig(useInlineRememberedOnly: true)
        )
        let commit = try await ToolRegistry.shared.execute(
            name: "git_commit",
            arguments: ToolArguments(dictionary: ["message": "wt: isolated"]),
            context: ctx)
        XCTAssertFalse(commit.isError, commit.content)

        let mainHasFile = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "ls-files", "main-only.txt"],
            workingDirectory: project, timeout: 10)
        XCTAssertTrue(
            mainHasFile.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "git_commit must not stage main-only.txt into the main tree: \(mainHasFile.stdout)")

        let wtHasFile = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "ls-files", "wt-only.txt"],
            workingDirectory: URL(fileURLWithPath: created.path), timeout: 10)
        XCTAssertTrue(
            wtHasFile.stdout.contains("wt-only.txt"),
            "worktree commit should include wt-only.txt: \(wtHasFile.stdout)")
    }

    /// W2: write via the same confinement cwd git_commit uses; main porcelain
    /// must not list that file; it exists only under the worktree path.
    func testWorktreeMutationDoesNotDirtyMain() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let project = try makeGitRepo(prefix: "vc-w2-dirty")
        defer { try? FileManager.default.removeItem(at: project) }

        var convo = Conversation()
        let result = try WorktreeService.bindProjectEnablingWorktree(
            &convo, projectRoot: project)
        guard case .enabled(let created) = result else {
            return XCTFail("expected enabled worktree, got \(result)")
        }
        defer {
            try? WorktreeService.discard(
                worktreePath: created.path,
                branch: created.branch,
                projectFolder: project.path)
        }

        let worktreeURL = URL(fileURLWithPath: created.path)
        let markerName = "w2-isolated.txt"
        let ctx = ToolContext(
            projectRoot: project,
            worktreeRoot: worktreeURL,
            conversationID: convo.id,
            executionMode: .yolo,
            authorization: AuthorizationConfig(useInlineRememberedOnly: true)
        )
        let write = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": markerName,
                "content": "w2 isolation marker\n",
            ]),
            context: ctx)
        XCTAssertFalse(write.isError, write.content)

        let wtFile = worktreeURL.appendingPathComponent(markerName)
        let mainFile = project.appendingPathComponent(markerName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wtFile.path),
            "file must exist in the worktree")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: mainFile.path),
            "file must not exist in the main checkout")

        let porcelain = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "status", "--porcelain"],
            workingDirectory: project,
            timeout: 10)
        XCTAssertEqual(porcelain.exitCode, 0, porcelain.stderr)
        let lines = porcelain.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { $0.contains(markerName) }
        XCTAssertTrue(
            lines.isEmpty,
            "main git status must not list \(markerName); got:\n\(porcelain.stdout)")
    }

    /// Yolo `run_shell` must not write the main checkout while a worktree is on.
    func testYoloRunShellWriteIntoMainDoesNotDirtyMain() async throws {
        await ToolRegistry.shared.registerBuiltins()
        // Seatbelt always allows /tmp and /var/folders — put the repo in
        // Caches so a write to main is actually outside the fence.
        let project = try makeGitRepo(prefix: "vc-yolo-shell", inCaches: true)
        defer { try? FileManager.default.removeItem(at: project) }

        var convo = Conversation()
        let result = try WorktreeService.bindProjectEnablingWorktree(
            &convo, projectRoot: project)
        guard case .enabled(let created) = result else {
            return XCTFail("expected enabled worktree, got \(result)")
        }
        defer {
            try? WorktreeService.discard(
                worktreePath: created.path,
                branch: created.branch,
                projectFolder: project.path)
        }

        let leakName = "yolo-shell-leak.txt"
        let mainLeak = project.appendingPathComponent(leakName)
        let quoted = mainLeak.path.replacingOccurrences(of: "'", with: "'\\''")
        let ctx = ToolContext(
            projectRoot: project,
            worktreeRoot: URL(fileURLWithPath: created.path),
            conversationID: convo.id,
            executionMode: .yolo,
            authorization: AuthorizationConfig(useInlineRememberedOnly: true)
        )
        let shell = try await ToolRegistry.shared.execute(
            name: "run_shell",
            arguments: ToolArguments(dictionary: [
                "command": "printf leaked > '\(quoted)'",
            ]),
            context: ctx)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: mainLeak.path),
            "yolo run_shell must not create \(mainLeak.path); shell said:\n\(shell.content)")
        let porcelain = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "status", "--porcelain"],
            workingDirectory: project,
            timeout: 10)
        let leakLines = porcelain.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { $0.contains(leakName) }
        XCTAssertTrue(
            leakLines.isEmpty,
            "main porcelain must not list \(leakName):\n\(porcelain.stdout)")
    }

    /// Main checkout in `/tmp` (or `/var/folders`) must not inherit the
    /// default temp write allow-list while a worktree is on.
    func testYoloRunShellWriteIntoTmpMainDoesNotDirtyMain() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let project = try makeGitRepo(prefix: "vc-yolo-tmp")
        defer { try? FileManager.default.removeItem(at: project) }

        var convo = Conversation()
        let result = try WorktreeService.bindProjectEnablingWorktree(
            &convo, projectRoot: project)
        guard case .enabled(let created) = result else {
            return XCTFail("expected enabled worktree, got \(result)")
        }
        defer {
            try? WorktreeService.discard(
                worktreePath: created.path,
                branch: created.branch,
                projectFolder: project.path)
        }

        let leakName = "yolo-tmp-leak.txt"
        let mainLeak = project.appendingPathComponent(leakName)
        let quoted = mainLeak.path.replacingOccurrences(of: "'", with: "'\\''")
        let ctx = ToolContext(
            projectRoot: project,
            worktreeRoot: URL(fileURLWithPath: created.path),
            conversationID: convo.id,
            executionMode: .yolo,
            authorization: AuthorizationConfig(useInlineRememberedOnly: true)
        )
        let shell = try await ToolRegistry.shared.execute(
            name: "run_shell",
            arguments: ToolArguments(dictionary: [
                "command": "printf leaked > '\(quoted)'",
            ]),
            context: ctx)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: mainLeak.path),
            "tmp-hosted main must not be written (\(mainLeak.path)); shell:\n\(shell.content)")
        let porcelain = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "status", "--porcelain"],
            workingDirectory: project,
            timeout: 10)
        let leakLines = porcelain.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { $0.contains(leakName) }
        XCTAssertTrue(
            leakLines.isEmpty,
            "main porcelain must not list \(leakName):\n\(porcelain.stdout)")
    }

    func testMergeThenEnsureRecreatesWorktree() throws {
        let project = try makeGitRepo(prefix: "vc-merge-ensure")
        defer { try? FileManager.default.removeItem(at: project) }

        var convo = Conversation()
        let first = try WorktreeService.bindProjectEnablingWorktree(
            &convo, projectRoot: project)
        guard case .enabled(let created) = first else {
            return XCTFail("expected enabled, got \(first)")
        }
        try "from-wt".write(
            to: URL(fileURLWithPath: created.path).appendingPathComponent("from-wt.txt"),
            atomically: true, encoding: .utf8)
        try WorktreeService.mergeAndRemove(
            worktreePath: created.path,
            branch: created.branch,
            projectFolder: project.path,
            commitMessage: "W2 merge then re-isolate")
        convo.worktreeBranch = nil

        let again = try WorktreeService.ensureDefaultWorktreeIfNeeded(&convo)
        guard case .enabled(let created2) = again else {
            return XCTFail("after merge, ensure must re-isolate, got \(again)")
        }
        defer {
            try? WorktreeService.discard(
                worktreePath: created2.path,
                branch: created2.branch,
                projectFolder: project.path)
        }
        XCTAssertNotNil(convo.worktreeRootURL)
        XCTAssertFalse(convo.worktreeOptOut)
        XCTAssertTrue(WorktreeService.worktreeExists(at: created2.path))
    }

    /// After merge + ensure, a ConversationStore round-trip keeps `worktreeBranch`.
    func testMergeThenEnsurePersistsWorktreeBranch() async throws {
        let project = try makeGitRepo(prefix: "vc-merge-persist")
        defer { try? FileManager.default.removeItem(at: project) }
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-merge-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }

        var convo = Conversation()
        let first = try WorktreeService.bindProjectEnablingWorktree(
            &convo, projectRoot: project)
        guard case .enabled(let created) = first else {
            return XCTFail("expected enabled, got \(first)")
        }
        try "from-wt".write(
            to: URL(fileURLWithPath: created.path).appendingPathComponent("from-wt.txt"),
            atomically: true, encoding: .utf8)
        try WorktreeService.mergeAndRemove(
            worktreePath: created.path,
            branch: created.branch,
            projectFolder: project.path,
            commitMessage: "persist re-isolate")
        convo.worktreeBranch = nil
        let again = try WorktreeService.ensureDefaultWorktreeIfNeeded(&convo)
        guard case .enabled(let created2) = again else {
            return XCTFail("ensure after merge must set a branch, got \(again)")
        }
        defer {
            try? WorktreeService.discard(
                worktreePath: created2.path,
                branch: created2.branch,
                projectFolder: project.path)
        }
        XCTAssertNotNil(convo.worktreeBranch)

        let store = ConversationStore(directory: storeDir)
        try await store.save(convo)
        let loaded = try await store.load(id: convo.id)
        XCTAssertEqual(loaded?.worktreeBranch, convo.worktreeBranch)
        XCTAssertNotNil(loaded?.worktreeBranch, "saved conversation must keep isolation after merge")
        XCTAssertFalse(loaded?.worktreeOptOut ?? true)
    }

    func testBindNonGitFolderDoesNotTrapAndLeavesWorktreeOff() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vc-nongit-bind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var convo = Conversation()
        let result = try WorktreeService.bindProjectEnablingWorktree(&convo, projectRoot: dir)
        guard case .skippedNotGit(let path) = result else {
            return XCTFail("non-git bind must be skippedNotGit, not \(result)")
        }
        XCTAssertEqual(path, dir.path)
        XCTAssertEqual(
            result.userVisibleReason,
            WorktreeError.notAGitRepo(dir.path).errorDescription)
        XCTAssertTrue(
            result.userVisibleReason?.contains("Not a git repository") == true,
            result.userVisibleReason ?? "")
        XCTAssertEqual(convo.projectRoot?.path, dir.path)
        XCTAssertNil(convo.worktreeBranch)
        XCTAssertNil(convo.worktreeRootURL)
        if case .enabled = result {
            XCTFail("must not succeed-with-worktree for a non-git folder")
        }
    }

    /// W4: dirty main must not block worktree create; uncommitted files stay in main.
    func testDirtyMainDoesNotBlockWorktreeCreate() throws {
        let project = try makeGitRepo(prefix: "vc-w4-dirty")
        defer { try? FileManager.default.removeItem(at: project) }

        let untracked = project.appendingPathComponent("uncommitted-main.txt")
        try "stays-in-main".write(to: untracked, atomically: true, encoding: .utf8)
        try "readme dirty".write(
            to: project.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)

        var convo = Conversation()
        let result = try WorktreeService.bindProjectEnablingWorktree(
            &convo, projectRoot: project)
        guard case .enabled(let created) = result else {
            return XCTFail("dirty main must not block worktree create, got \(result)")
        }
        defer {
            try? WorktreeService.discard(
                worktreePath: created.path,
                branch: created.branch,
                projectFolder: project.path)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: untracked.path))
        let wtUntracked = URL(fileURLWithPath: created.path)
            .appendingPathComponent("uncommitted-main.txt")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: wtUntracked.path),
            "uncommitted main file must not appear in the worktree")

        let wtReadme = try String(
            contentsOf: URL(fileURLWithPath: created.path).appendingPathComponent("README.md"),
            encoding: .utf8)
        XCTAssertEqual(wtReadme.trimmingCharacters(in: .whitespacesAndNewlines), "readme",
                       "worktree must be HEAD, not the dirty main working tree")
        let mainReadme = try String(
            contentsOf: project.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertEqual(mainReadme.trimmingCharacters(in: .whitespacesAndNewlines), "readme dirty")

        let porcelain = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "status", "--porcelain"],
            workingDirectory: project, timeout: 10)
        XCTAssertTrue(
            porcelain.stdout.contains("uncommitted-main.txt"),
            "main must stay dirty: \(porcelain.stdout)")
        XCTAssertTrue(
            porcelain.stdout.contains("README.md"),
            "modified README must stay in main: \(porcelain.stdout)")
    }

    func testBindGitWorktreeFailureDoesNotLeaveMainBound() throws {
        let project = try makeGitRepo(prefix: "vc-bind-fail")
        defer { try? FileManager.default.removeItem(at: project) }

        var convo = Conversation()
        let short = WorktreeService.conversationShortId(from: convo.id)
        let stale = "\(project.path)-agentcore-\(short)"
        try FileManager.default.createDirectory(atPath: stale, withIntermediateDirectories: true)
        try "not-git".write(
            to: URL(fileURLWithPath: stale).appendingPathComponent("x.txt"),
            atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: stale) }

        XCTAssertThrowsError(
            try WorktreeService.bindProjectEnablingWorktree(&convo, projectRoot: project)
        )
        XCTAssertNil(convo.projectRoot, "failed worktree must not leave git main bound")
        XCTAssertNil(convo.worktreeBranch)
    }

    func testDisableWorktreeModeClearsBranchWithoutDiscard() throws {
        let project = try makeGitRepo(prefix: "vc-disable-wt")
        defer { try? FileManager.default.removeItem(at: project) }

        var convo = Conversation()
        let result = try WorktreeService.bindProjectEnablingWorktree(
            &convo, projectRoot: project)
        guard case .enabled(let created) = result else {
            return XCTFail("expected enabled, got \(result)")
        }
        defer {
            try? WorktreeService.discard(
                worktreePath: created.path,
                branch: created.branch,
                projectFolder: project.path)
        }

        WorktreeService.disableWorktreeMode(&convo)
        XCTAssertEqual(convo.projectRoot?.path, project.path)
        XCTAssertNil(convo.worktreeBranch)
        XCTAssertNil(convo.worktreeRootURL)
        XCTAssertTrue(convo.worktreeOptOut)
        XCTAssertTrue(
            WorktreeService.worktreeExists(at: created.path),
            "disable is the escape hatch — disk worktree stays until discard")
    }

    /// Saved git-bound chats with nil branch isolate on load; opt-out stays on main.
    func testEnsureOnLoadIsolatesLegacyGitBindUnlessOptedOut() throws {
        let project = try makeGitRepo(prefix: "vc-load-wt")
        defer { try? FileManager.default.removeItem(at: project) }

        // Old JSON: projectRoot + nil branch + missing worktreeOptOut → false.
        let legacy = Conversation(projectRoot: project, worktreeBranch: nil)
        XCTAssertFalse(legacy.worktreeOptOut)
        let encoded = try JSONEncoder().encode(legacy)
        var obj = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        obj.removeValue(forKey: "worktreeOptOut")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        var loaded = try JSONDecoder().decode(Conversation.self, from: stripped)
        XCTAssertFalse(loaded.worktreeOptOut, "old files must default to isolate")
        XCTAssertNil(loaded.worktreeBranch)

        let isolated = try WorktreeService.ensureDefaultWorktreeIfNeeded(&loaded)
        guard case .enabled(let created) = isolated else {
            return XCTFail("legacy git bind must isolate, got \(isolated)")
        }
        defer {
            try? WorktreeService.discard(
                worktreePath: created.path,
                branch: created.branch,
                projectFolder: project.path)
        }
        XCTAssertEqual(loaded.worktreeBranch, created.branch)
        XCTAssertFalse(loaded.worktreeOptOut)
        XCTAssertNotNil(loaded.worktreeRootURL)

        // Second ensure is a no-op.
        let again = try WorktreeService.ensureDefaultWorktreeIfNeeded(&loaded)
        XCTAssertEqual(again, .alreadyIsolated)

        var opted = Conversation(projectRoot: project, worktreeBranch: nil, worktreeOptOut: true)
        let skipped = try WorktreeService.ensureDefaultWorktreeIfNeeded(&opted)
        XCTAssertEqual(skipped, .skippedOptOut)
        XCTAssertNil(opted.worktreeBranch)
        XCTAssertTrue(opted.worktreeOptOut)
        XCTAssertNil(opted.worktreeRootURL)
    }

    func testRemoteControlStartStillDisabled() async throws {
        XCTAssertFalse(RemoteControlServer.isEnabled)
        let server = RemoteControlServer()
        do {
            _ = try await server.start(port: 18765, lifetime: 30)
            XCTFail("remote start must stay disabled")
        } catch let err as RemoteControlServer.ServerError {
            XCTAssertEqual(err, .disabled)
        }
        let running = await server.isRunning()
        XCTAssertFalse(running)
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

    private func makeGitRepo(prefix: String, inCaches: Bool = false) throws -> URL {
        let parent: URL
        if inCaches {
            parent = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        } else {
            parent = URL(fileURLWithPath: NSTemporaryDirectory())
        }
        let project = parent
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
