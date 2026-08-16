//
//  StatusCapsuleUITests.swift
//
//  Wave U3 — status capsule parse/format (no live `git`, no View host).
//

import XCTest
@testable import VibeCoderApp

final class StatusCapsuleUITests: XCTestCase {

    // MARK: - Porcelain → dirty count

    func testPorcelainDirtyCountIncludesModifiedAndUntracked() {
        let porcelain = """
         M Sources/Foo.swift
        ?? new.txt
        M  staged.swift
         D deleted.swift
        R  old.swift -> renamed.swift
        """
        XCTAssertEqual(GitWorkingCopySummary.dirtyCount(fromPorcelain: porcelain), 5)
    }

    func testPorcelainSkipsBlankAndIgnoredLines() {
        let porcelain = """

        !! build/Ignored.bin
         M keep.swift

        """
        XCTAssertEqual(GitWorkingCopySummary.dirtyCount(fromPorcelain: porcelain), 1)
        XCTAssertEqual(GitWorkingCopySummary.dirtyCount(fromPorcelain: ""), 0)
        XCTAssertEqual(GitWorkingCopySummary.dirtyCount(fromPorcelain: "\n\n"), 0)
    }

    // MARK: - Branch

    func testBranchTrimAndDetachedHEADStillShows() {
        XCTAssertEqual(GitWorkingCopySummary.trimmedBranch("  main\n"), "main")
        XCTAssertEqual(GitWorkingCopySummary.trimmedBranch("HEAD\n"), "HEAD")
        XCTAssertEqual(GitWorkingCopySummary.trimmedBranch("  feature/foo  "), "feature/foo")
        XCTAssertNil(GitWorkingCopySummary.trimmedBranch("  \n"))
        XCTAssertNil(GitWorkingCopySummary.trimmedBranch(""))
    }

    func testCaptureDetachedHEADStillShows() {
        let runner: GitWorkingCopySummary.Runner = { args, _, _ in
            if args == ["rev-parse", "--abbrev-ref", "HEAD"] {
                return .init(stdout: "  HEAD\n", exitCode: 0)
            }
            if args == ["status", "--porcelain"] {
                return .init(stdout: " M a.swift\n?? b.txt\n", exitCode: 0)
            }
            return .init(stdout: "", exitCode: 1)
        }
        let snap = GitWorkingCopySummary.capture(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            runner: runner)
        XCTAssertEqual(snap?.branch, "HEAD")
        XCTAssertEqual(snap?.dirtyCount, 2)
    }

    // MARK: - Collapsed label

    func testCollapsedLabelOmitsEmptySegments() {
        XCTAssertEqual(
            GitWorkingCopySummary.collapsedLabel(
                branch: "main", dirtyCount: 3, fileCount: 2, todoDone: 1, todoTotal: 4),
            "main · 3 dirty · 2 files · 1/4 todos"
        )
        XCTAssertEqual(
            GitWorkingCopySummary.collapsedLabel(
                branch: "main", dirtyCount: 0, fileCount: 0, todoDone: 0, todoTotal: 0),
            "main"
        )
        XCTAssertEqual(
            GitWorkingCopySummary.collapsedLabel(
                branch: nil, dirtyCount: 3, fileCount: 0, todoDone: 0, todoTotal: 0),
            "3 dirty"
        )
        XCTAssertEqual(
            GitWorkingCopySummary.collapsedLabel(
                branch: "  ", dirtyCount: 0, fileCount: 1, todoDone: 0, todoTotal: 2),
            "1 file · 0/2 todos"
        )
        XCTAssertEqual(
            GitWorkingCopySummary.collapsedLabel(
                branch: nil, dirtyCount: 0, fileCount: 0, todoDone: 1, todoTotal: 0),
            ""
        )
    }

    // MARK: - Hide when not a repo

    func testCaptureReturnsNilWhenRunnerExits128() {
        let runner: GitWorkingCopySummary.Runner = { _, _, _ in
            .init(stdout: "fatal: not a git repository\n", exitCode: 128)
        }
        let snap = GitWorkingCopySummary.capture(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            runner: runner)
        XCTAssertNil(snap)
    }

    // MARK: - Todos

    func testTodoFractionString() {
        XCTAssertEqual(GitWorkingCopySummary.todoFraction(done: 1, total: 4), "1/4 todos")
        XCTAssertEqual(GitWorkingCopySummary.todoFraction(done: 0, total: 3), "0/3 todos")
        XCTAssertEqual(GitWorkingCopySummary.todoFraction(done: 4, total: 4), "4/4 todos")
        XCTAssertNil(GitWorkingCopySummary.todoFraction(done: 0, total: 0))
        XCTAssertNil(GitWorkingCopySummary.todoFraction(done: 1, total: 0))
    }
}
