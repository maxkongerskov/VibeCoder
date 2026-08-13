//
//  BugHuntPlanProjectWorktreeTests.swift
//
//  Runtime proofs for Plan / Project / Worktree / Patch / EditBlock bugs.
//  Each test asserts the correct behavior; failures confirm the defect.
//

import XCTest
@testable import AgentCore

final class BugHuntPlanProjectWorktreeTests: XCTestCase {

    // MARK: - Issue: GoalAssessment hasFailures hides open work

    func testGoalAssessmentFailedTodosStillListOpenPendingGaps() {
        let plan = Plan(goal: "Ship feature", todos: [
            Todo(id: "1", text: "Write code", status: .done),
            Todo(id: "2", text: "Fix build", status: .pending),
            Todo(id: "3", text: "Docs", status: .failed, result: "blocked"),
        ])
        let r = GoalAssessment.assess(
            goalDescription: "Ship feature",
            plan: plan,
            recentErrorFlags: [])
        XCTAssertFalse(r.achieved)
        XCTAssertTrue(
            r.gaps.contains { $0.contains("Fix build") },
            "pending work must remain visible in gaps; got \(r.gaps)")
    }

    func testGoalAssessmentFailedShortCircuitFreezesStallFingerprint() {
        let planA = Plan(goal: "Ship", todos: [
            Todo(id: "1", text: "A", status: .pending),
            Todo(id: "2", text: "B", status: .failed),
        ])
        let planB = Plan(goal: "Ship", todos: [
            Todo(id: "1", text: "A", status: .inProgress),
            Todo(id: "2", text: "B", status: .failed),
        ])
        let a = GoalAssessment.assess(goalDescription: "Ship", plan: planA, recentErrorFlags: [])
        let b = GoalAssessment.assess(goalDescription: "Ship", plan: planB, recentErrorFlags: [])
        XCTAssertNotEqual(
            GapFingerprint(gaps: a.gaps),
            GapFingerprint(gaps: b.gaps),
            "progressing a pending todo while another is failed must change the fingerprint; a=\(a.gaps) b=\(b.gaps)")
    }

    // MARK: - Issue: PlanStore.clear does not drop durable JSON

    func testPlanStoreClearRemovesDurableFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-plan-clear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let convo = UUID()
        let store = PlanStore()
        await store.setPlan(
            Plan.make(goal: "Old", todoTexts: ["a"]),
            for: convo,
            workingDirectory: root)
        let file = PlanStore.durableFileURL(workingDirectory: root, conversation: convo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        await store.clear(for: convo)

        let cold = PlanStore()
        let revived = await cold.hydrateIfNeeded(for: convo, messages: [], workingDirectory: root)
        XCTAssertNil(
            revived,
            "clear() must drop durable plan.json; cold hydrate revived \(String(describing: revived))")
    }

    // MARK: - Issue: ProjectsService prunes temporarily missing externals

    func testMissingExternalFolderIsNotPermanentlyPruned() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-proj-prune-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("ManagedRoot", isDirectory: true)
        let elsewhere = base.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let mine = elsewhere.appendingPathComponent("Removable", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)

        let first = ProjectsService(rootURL: root)
        _ = try await first.register(existingFolder: mine).get()

        let parked = elsewhere.appendingPathComponent("Removable-parked", isDirectory: true)
        try FileManager.default.moveItem(at: mine, to: parked)
        _ = ProjectsService(rootURL: root)
        try FileManager.default.moveItem(at: parked, to: mine)

        let restored = ProjectsService(rootURL: root)
        let names = await restored.projects().map { $0.url.standardizedFileURL.path }
        XCTAssertTrue(
            names.contains(mine.standardizedFileURL.path),
            "temporarily missing external project must not be wiped from the registry; got \(names)")
    }

    // MARK: - Issue: WorktreeDiffParser numstat rename path

    func testNumstatRenameArrowMapsToDestinationPath() {
        let status = "R  old.txt -> new.txt\n"
        let numstat = "3\t1\told.txt => new.txt\n"
        let unified = """
        diff --git a/old.txt b/new.txt
        rename from old.txt
        rename to new.txt
        --- a/old.txt
        +++ b/new.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
        """
        let files = WorktreeDiffParser.parse(
            statusShort: status, numstat: numstat, unified: unified)
        XCTAssertFalse(
            files.contains { $0.path.contains("=>") },
            "numstat rename must not leak 'old => new' as a path: \(files.map(\.path))")
        let neu = files.first { $0.path == "new.txt" }
        XCTAssertEqual(neu?.linesAdded, 3, "stats must attach to destination, got \(files)")
        XCTAssertEqual(neu?.linesRemoved, 1)
    }

    // MARK: - Issue: WorktreeService reuses unrelated git repo

    func testCreateOrReuseRejectsUnrelatedGitRepoAtConventionalPath() throws {
        let project = try makeGitRepo(prefix: "bughunt-wt-unrelated")
        defer { try? FileManager.default.removeItem(at: project) }

        let shortId = "other001"
        let hijack = URL(fileURLWithPath: "\(project.path)-agentcore-\(shortId)")
        try FileManager.default.createDirectory(at: hijack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: hijack) }

        func git(_ args: [String], cwd: URL) {
            let r = ShellRunner.run(
                executable: "/usr/bin/env",
                arguments: ["git"] + args,
                workingDirectory: cwd,
                timeout: 15)
            XCTAssertEqual(r.exitCode, 0, r.stderr)
        }
        git(["init"], cwd: hijack)
        git(["config", "user.email", "x@y.z"], cwd: hijack)
        git(["config", "user.name", "X"], cwd: hijack)
        try "nope".write(to: hijack.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        git(["add", "README.md"], cwd: hijack)
        git(["commit", "-m", "other"], cwd: hijack)

        XCTAssertThrowsError(
            try WorktreeService.createOrReuseWorktree(
                projectFolder: project.path,
                conversationShortId: shortId)
        ) { err in
            XCTAssertTrue(
                "\(err)".lowercased().contains("not")
                    || (err as? WorktreeError) != nil,
                "unrelated git repo at the conventional path must not be reused: \(err)")
        }
    }

    // MARK: - Issue: UnifiedDiff delete path / header collision / clamp / timestamps

    func testParseDeletePatchUsesOriginalPathNotDevNull() {
        let patch = """
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -line1
        -line2
        """
        let parsed = UnifiedDiff.parse(patch)
        XCTAssertEqual(parsed.count, 1, "delete hunk must parse as one file patch")
        XCTAssertEqual(
            parsed.first?.path, "gone.txt",
            "deletion must keep the source path, not \(parsed.first?.path ?? "nil")")
    }

    func testApplyPatchStandardDeleteTargetsSourceFile() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-del-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("gone.txt")
        try "line1\nline2\n".write(to: file, atomically: true, encoding: .utf8)

        let patch = """
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -line1
        -line2
        """
        let ctx = ToolContext(
            projectRoot: root,
            conversationID: UUID(),
            executionMode: .yolo,
            sessionReadPaths: [SafeModeConfig.normalizePath(file.path)])
        do {
            let result = try await ToolRegistry.shared.execute(
                name: "apply_patch",
                arguments: ToolArguments(dictionary: ["patch": patch]),
                context: ctx)
            XCTAssertFalse(result.isError, result.content)
            if FileManager.default.fileExists(atPath: file.path) {
                let leftover = try String(contentsOf: file, encoding: .utf8)
                XCTAssertTrue(leftover.isEmpty, "delete patch left \(leftover)")
            }
        } catch {
            XCTFail("delete patch must target gone.txt inside the project, not /dev/null: \(error)")
        }
    }

    func testApplyRejectsContextFreeInsertPastEndOfFile() {
        let original = "a\nb\nc\n"
        let patch = """
        --- a/f.txt
        +++ b/f.txt
        @@ -99,0 +100,1 @@
        +injected
        """
        let parsed = UnifiedDiff.parse(patch)
        XCTAssertEqual(parsed.count, 1)
        let result = UnifiedDiff.apply(filePatch: parsed[0], to: original)
        guard case .failure = result else {
            return XCTFail("insert hunk far past EOF must fail closed, got \(result)")
        }
    }

    func testParseDoesNotTreatRemovedSQLCommentAsNewFileHeader() {
        let original = """
        SELECT 1;
        -- keep going
        SELECT 2;
        """
        let patch = """
        --- a/q.sql
        +++ b/q.sql
        @@ -1,3 +1,2 @@
         SELECT 1;
        --- keep going
         SELECT 2;
        """
        let parsed = UnifiedDiff.parse(patch)
        XCTAssertEqual(parsed.count, 1, "got paths \(parsed.map(\.path))")
        XCTAssertEqual(parsed[0].path, "q.sql")
        let result = UnifiedDiff.apply(filePatch: parsed[0], to: original)
        guard case .success(let updated) = result else {
            return XCTFail("removing a '-- comment' line must apply, got \(result)")
        }
        XCTAssertFalse(updated.contains("keep going"), updated)
    }

    func testParseDoesNotTreatAddedPlusPlusAsNewFileHeader() {
        let original = """
        int main() {
            return 0;
        }
        """
        let patch = """
        --- a/p.c
        +++ b/p.c
        @@ -1,3 +1,4 @@
         int main() {
        +++ i;
             return 0;
         }
        """
        let parsed = UnifiedDiff.parse(patch)
        XCTAssertEqual(parsed.first?.path, "p.c", "got \(parsed.map(\.path))")
        let result = UnifiedDiff.apply(filePatch: parsed[0], to: original)
        guard case .success(let updated) = result else {
            return XCTFail("adding a '++ i;' line must apply, got \(result)")
        }
        XCTAssertTrue(updated.contains("++ i;"), updated)
    }

    func testParseStripsTimestampFromPlusPlusHeader() {
        let patch = """
        --- a/hello.txt	2024-01-01 00:00:00
        +++ b/hello.txt	2024-01-01 00:01:00
        @@ -1 +1 @@
        -old
        +new
        """
        let parsed = UnifiedDiff.parse(patch)
        XCTAssertEqual(
            parsed.first?.path, "hello.txt",
            "diff -u timestamp must not become part of the path: \(parsed.first?.path ?? "nil")")
    }

    // MARK: - Issue: EditBlock unique-gate disagrees with apply

    func testCountMatchWindowsAgreesWithApplyOnMixedIndent() {
        let content = "  foo\n"
        let search = "    foo\n"
        let replace = "bar\n"
        let count = EditBlockApplier.countMatchWindows(search: search, in: content)
        let outcome = EditBlockApplier.apply(
            EditBlock(filename: "t.txt", original: search, updated: replace),
            to: content)
        switch outcome {
        case .applied:
            XCTAssertGreaterThan(count, 0, "apply succeeded so countMatchWindows must be > 0")
        case .failed:
            XCTAssertEqual(
                count, 0,
                "apply failed so unique-gate count must be 0, got \(count)")
        }
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
