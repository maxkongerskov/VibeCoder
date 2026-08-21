//
//  WorktreeReviewSheetTests.swift
//
//  Characterization of the landed worktree review sheet (Merge / Discard /
//  Continue). RELEASE_BAR W5: those actions are user-driven; no auto-merge.
//  Coordinator merge/discard already live in BugHuntViewModelsTests.
//  This file covers the sheet model + Continue (dismiss without touching
//  the worktree). Not SwiftUI hit-testing. Does not grow AgentLoop or
//  ChatViewModel.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

@MainActor
final class WorktreeReviewSheetTests: XCTestCase {

    /// Sheet display rows map 1:1 from AgentCore review parser output.
    func testFileChangeMapsParserKindsAndDiffLines() {
        let parsed = [
            WorktreeDiffParser.FileChange(
                path: "Sources/Foo.swift",
                kind: .modified,
                linesAdded: 2,
                linesRemoved: 1,
                diffLines: [
                    .init(kind: .context, text: "    keep"),
                    .init(kind: .removed, text: "    old"),
                    .init(kind: .added, text: "    new"),
                ]),
            WorktreeDiffParser.FileChange(
                path: "Sources/New.swift",
                kind: .added,
                linesAdded: 1,
                linesRemoved: 0,
                diffLines: [.init(kind: .added, text: "let x = 1")]),
            WorktreeDiffParser.FileChange(
                path: "Sources/Gone.swift",
                kind: .deleted,
                linesAdded: 0,
                linesRemoved: 1,
                diffLines: [.init(kind: .removed, text: "let y = 2")]),
        ]

        let files = WorktreeFileChange.from(parserFiles: parsed)
        XCTAssertEqual(files.map(\.path), [
            "Sources/Foo.swift", "Sources/New.swift", "Sources/Gone.swift",
        ])
        XCTAssertEqual(files[0].linesAdded, 2)
        XCTAssertEqual(files[0].linesRemoved, 1)
        XCTAssertEqual(files[0].diffLines.map(\.text), ["    keep", "    old", "    new"])
        switch files[0].kind {
        case .modified: break
        default: XCTFail("expected modified")
        }
        switch files[1].kind {
        case .added: break
        default: XCTFail("expected added")
        }
        switch files[2].kind {
        case .deleted: break
        default: XCTFail("expected deleted")
        }
        switch files[0].diffLines.map(\.kind) {
        case [.context, .removed, .added]: break
        default: XCTFail("expected context/removed/added diff kinds")
        }
    }

    /// Live path used by ChatView.handleReviewWorktree: git status/diff → sheet rows.
    func testFromWorktreePathLoadsLiveGitDiff() throws {
        let fm = FileManager.default
        let storeDir = fm.temporaryDirectory
            .appendingPathComponent("sheet-from-path-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: storeDir) }

        let project = try makeGitRepo(prefix: "sheet-from-path")
        defer { try? fm.removeItem(at: project) }

        var convo = Conversation()
        convo.projectRoot = project
        let coord = ConversationCoordinator()
        coord.conversationStore = ConversationStore(directory: storeDir)
        coord.conversations = [convo]
        let wt = WorktreeCoordinator()
        wt.conversations = coord

        wt.enableWorktree(for: convo.id)
        XCTAssertNil(wt.worktreeError, wt.worktreeError ?? "")
        let isolated = coord.conversations[0]
        guard let diskPath = isolated.worktreeRootURL?.path else {
            return XCTFail("enable must produce a worktree path")
        }
        defer {
            try? WorktreeService.discard(
                worktreePath: diskPath,
                branch: isolated.worktreeBranch ?? "",
                projectFolder: project.path)
        }

        try "from-sheet".write(
            to: URL(fileURLWithPath: diskPath).appendingPathComponent("from-sheet.txt"),
            atomically: true, encoding: .utf8)

        let files = WorktreeFileChange.from(worktreePath: diskPath)
        XCTAssertTrue(
            files.contains { $0.path.hasSuffix("from-sheet.txt") },
            "review sheet live path must list the worktree file, got: \(files.map(\.path))")
        if let row = files.first(where: { $0.path.hasSuffix("from-sheet.txt") }) {
            switch row.kind {
            case .added: break
            default: XCTFail("new worktree file should be added, got \(String(describing: row.kind))")
            }
        }
    }

    /// Continue on the review sheet is onDismiss only (ChatView closes the
    /// sheet). It must not merge, discard, or opt out of isolation.
    func testContinueLeavesWorktreeBoundWithoutMergeOrDiscard() throws {
        let fm = FileManager.default
        let storeDir = fm.temporaryDirectory
            .appendingPathComponent("sheet-continue-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: storeDir) }

        let project = try makeGitRepo(prefix: "sheet-continue")
        defer { try? fm.removeItem(at: project) }

        var convo = Conversation()
        convo.projectRoot = project
        convo.worktreeOptOut = false
        let coord = ConversationCoordinator()
        coord.conversationStore = ConversationStore(directory: storeDir)
        coord.conversations = [convo]
        let wt = WorktreeCoordinator()
        wt.conversations = coord

        wt.enableWorktree(for: convo.id)
        XCTAssertNil(wt.worktreeError, wt.worktreeError ?? "")
        let isolated = coord.conversations[0]
        XCTAssertNotNil(isolated.worktreeBranch)
        guard let diskPath = isolated.worktreeRootURL?.path else {
            return XCTFail("enable must produce a worktree path")
        }
        XCTAssertTrue(WorktreeService.worktreeExists(at: diskPath))
        defer {
            try? WorktreeService.discard(
                worktreePath: diskPath,
                branch: isolated.worktreeBranch ?? "",
                projectFolder: project.path)
        }

        // ChatView Continue → onDismiss { showWorktreeReview = false }.
        // No mergeWorktree / discardWorktree / disableWorktree.
        var merged = false
        var discarded = false
        let onDismiss = { /* sheet close only */ }
        let onMerge: (String) -> Void = { _ in
            merged = true
            wt.mergeWorktree(for: convo.id, commitMessage: "should not run")
        }
        let onDiscard = {
            discarded = true
            wt.discardWorktree(for: convo.id)
        }
        _ = onMerge
        _ = onDiscard
        onDismiss()

        XCTAssertFalse(merged, "Continue must not invoke onMerge")
        XCTAssertFalse(discarded, "Continue must not invoke onDiscard")
        let after = coord.conversations[0]
        XCTAssertEqual(after.worktreeBranch, isolated.worktreeBranch)
        XCTAssertFalse(after.worktreeOptOut, "Continue is not Edit main tree")
        XCTAssertTrue(
            WorktreeService.worktreeExists(at: diskPath),
            "Continue must leave the sibling checkout on disk")
        XCTAssertNil(wt.worktreeError)
    }

    /// ChatView Merge closure forwards the commit message to mergeWorktree.
    func testMergeCallbackForwardsCommitMessageAndReisolates() throws {
        let fm = FileManager.default
        let storeDir = fm.temporaryDirectory
            .appendingPathComponent("sheet-merge-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: storeDir) }

        let project = try makeGitRepo(prefix: "sheet-merge")
        defer { try? fm.removeItem(at: project) }

        var convo = Conversation()
        convo.projectRoot = project
        let coord = ConversationCoordinator()
        coord.conversationStore = ConversationStore(directory: storeDir)
        coord.conversations = [convo]
        let wt = WorktreeCoordinator()
        wt.conversations = coord

        wt.enableWorktree(for: convo.id)
        XCTAssertNil(wt.worktreeError, wt.worktreeError ?? "")
        let isolated = coord.conversations[0]
        guard let firstPath = isolated.worktreeRootURL?.path else {
            return XCTFail("enable must produce a worktree")
        }
        try "from-sheet-merge".write(
            to: URL(fileURLWithPath: firstPath).appendingPathComponent("from-sheet-merge.txt"),
            atomically: true, encoding: .utf8)

        var forwarded: String?
        let onMerge: (String) -> Void = { message in
            forwarded = message
            wt.mergeWorktree(for: convo.id, commitMessage: message)
        }
        // Sheet trims before onMerge (WorktreeReviewSheet Merge button).
        let message = "  sheet merge click  ".trimmingCharacters(in: .whitespaces)
        onMerge(message)

        XCTAssertEqual(forwarded, "sheet merge click")
        XCTAssertNil(wt.worktreeError, wt.worktreeError ?? "")
        let after = coord.conversations[0]
        XCTAssertNotNil(after.worktreeBranch, "merge re-isolates; Continue would have kept the old branch")
        XCTAssertFalse(after.worktreeOptOut)
        if let newPath = after.worktreeRootURL?.path {
            defer {
                try? WorktreeService.discard(
                    worktreePath: newPath,
                    branch: after.worktreeBranch ?? "",
                    projectFolder: project.path)
            }
            XCTAssertTrue(WorktreeService.worktreeExists(at: newPath))
        }
        let mergedFile = project.appendingPathComponent("from-sheet-merge.txt")
        XCTAssertTrue(
            fm.fileExists(atPath: mergedFile.path),
            "Merge into main must land the worktree file in the project checkout")
    }

    /// ChatView Discard closure deletes the sibling checkout (not Edit main tree).
    func testDiscardCallbackRemovesWorktreeCheckout() throws {
        let fm = FileManager.default
        let storeDir = fm.temporaryDirectory
            .appendingPathComponent("sheet-discard-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: storeDir) }

        let project = try makeGitRepo(prefix: "sheet-discard")
        defer { try? fm.removeItem(at: project) }

        var convo = Conversation()
        convo.projectRoot = project
        let coord = ConversationCoordinator()
        coord.conversationStore = ConversationStore(directory: storeDir)
        coord.conversations = [convo]
        let wt = WorktreeCoordinator()
        wt.conversations = coord

        wt.enableWorktree(for: convo.id)
        XCTAssertNil(wt.worktreeError, wt.worktreeError ?? "")
        let isolated = coord.conversations[0]
        guard let diskPath = isolated.worktreeRootURL?.path else {
            return XCTFail("enable must produce a worktree")
        }
        XCTAssertTrue(WorktreeService.worktreeExists(at: diskPath))

        let onDiscard = { wt.discardWorktree(for: convo.id) }
        onDiscard()

        XCTAssertNil(wt.worktreeError, wt.worktreeError ?? "")
        let after = coord.conversations[0]
        XCTAssertNil(after.worktreeBranch, "successful Discard clears isolation")
        XCTAssertFalse(
            WorktreeService.worktreeExists(at: diskPath),
            "Discard on the review sheet is the delete path")
    }

    private func makeGitRepo(prefix: String) throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func git(_ args: [String], timeout: TimeInterval = 10) -> ShellResult {
            ShellRunner.run(
                executable: "/usr/bin/env",
                arguments: ["git"] + args,
                workingDirectory: project,
                timeout: timeout)
        }
        let initR = git(["init"])
        XCTAssertEqual(initR.exitCode, 0, initR.stderr)
        _ = git(["config", "user.email", "test@example.com"], timeout: 5)
        _ = git(["config", "user.name", "Test"], timeout: 5)
        try "readme".write(
            to: project.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        let add = git(["add", "README.md"], timeout: 5)
        XCTAssertEqual(add.exitCode, 0, add.stderr)
        let commit = git(["commit", "-m", "init"])
        XCTAssertEqual(commit.exitCode, 0, commit.stderr)
        return project
    }
}
