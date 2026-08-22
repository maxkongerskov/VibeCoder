//
//  ToolCallGroupingTests.swift
//
//  Explore grouping + file-change family grouping + shell cards +
//  stop-when-done (ZCode §3). Does not grow AgentLoop.
//

import XCTest
@testable import AgentCore

final class ToolCallGroupingTests: XCTestCase {

    func testFamilyMapsVibeCoderToolNames() {
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "read_file"), .fileRead)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "grep_code"), .search)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "grep"), .search)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "glob_files"), .search)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "glob"), .search)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "list_directory"), .explore)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "list_dir"), .explore)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "write_file"), .fileWrite)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "edit_file"), .fileWrite)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "run_shell"), .shell)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "update_todo"), .todo)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "load_skill"), .skill)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "task"), .agent)
        XCTAssertEqual(ToolCallGrouping.fileWriteKind(forToolName: "write_file"), .write)
        XCTAssertEqual(ToolCallGrouping.fileWriteKind(forToolName: "edit_file"), .update)
        XCTAssertEqual(ToolCallGrouping.fileWriteKind(forToolName: "delete_file"), .delete)
        XCTAssertEqual(ToolCallGrouping.fileWriteKind(forToolName: "apply_patch"), .update)
    }

    func testConsecutiveReadOnlyCollapseToOneExploreCard() {
        let events = [
            ToolCallEvent(name: "grep_code"),
            ToolCallEvent(name: "glob_files"),
            ToolCallEvent(name: "list_directory"),
            ToolCallEvent(name: "read_file"),
            ToolCallEvent(name: "read_file"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 1)
        guard case .explore(let counts, let members) = groups[0] else {
            return XCTFail("expected one Explore group")
        }
        XCTAssertEqual(counts.searches, 2)
        XCTAssertEqual(counts.lists, 1)
        XCTAssertEqual(counts.files, 2)
        XCTAssertEqual(members, [0, 1, 2, 3, 4])
    }

    func testWriteBreaksExploreGroup() {
        let events = [
            ToolCallEvent(name: "grep_code"),
            ToolCallEvent(name: "read_file"),
            ToolCallEvent(name: "write_file"),
            ToolCallEvent(name: "list_directory"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 3)
        guard case .explore(let first, _) = groups[0] else {
            return XCTFail("first should be explore")
        }
        XCTAssertEqual(first.searches, 1)
        XCTAssertEqual(first.files, 1)
        guard case .fileChange(let counts, let members) = groups[1] else {
            return XCTFail("write is a file-change family")
        }
        XCTAssertEqual(members, [2])
        XCTAssertEqual(counts.writes, 1)
        XCTAssertEqual(counts.fileCount, 1)
        guard case .explore(let third, _) = groups[2] else {
            return XCTFail("list after write starts a new explore")
        }
        XCTAssertEqual(third.lists, 1)
        XCTAssertEqual(third.files, 0)
    }

    func testConsecutiveFileWritesCollapseToOneFamily() {
        let events = [
            ToolCallEvent(name: "write_file", path: "a.swift", added: 10, deleted: 0),
            ToolCallEvent(name: "edit_file", path: "b.swift", added: 3, deleted: 2),
            ToolCallEvent(name: "delete_file", path: "c.swift", added: 0, deleted: 8),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 1)
        guard case .fileChange(let counts, let members) = groups[0] else {
            return XCTFail("expected one file-change group")
        }
        XCTAssertEqual(members, [0, 1, 2])
        XCTAssertEqual(counts.writes, 1)
        XCTAssertEqual(counts.updates, 1)
        XCTAssertEqual(counts.deletes, 1)
        XCTAssertEqual(counts.fileCount, 3)
        XCTAssertEqual(counts.added, 13)
        XCTAssertEqual(counts.deleted, 10)
        XCTAssertEqual(
            ToolCallGrouping.fileChangeGroupLabel(events: events, memberIndices: members),
            "Updated"
        )
    }

    func testSamePathCountsOnceInFileChangeGroup() {
        let events = [
            ToolCallEvent(name: "write_file", path: "./src/Foo.swift", added: 4),
            ToolCallEvent(name: "edit_file", path: "src/Foo.swift", added: 1, deleted: 1),
        ]
        let groups = ToolCallGrouping.group(events)
        guard case .fileChange(let counts, _) = groups[0] else {
            return XCTFail("expected file-change group")
        }
        XCTAssertEqual(counts.fileCount, 1)
        XCTAssertEqual(counts.added, 5)
        XCTAssertEqual(counts.deleted, 1)
    }

    func testFileWriteActivityLabels() {
        XCTAssertEqual(ToolCallGrouping.fileWriteActivityLabel(name: "write_file", isRunning: true), "Writing")
        XCTAssertEqual(ToolCallGrouping.fileWriteActivityLabel(name: "write_file", isRunning: false), "Wrote")
        XCTAssertEqual(ToolCallGrouping.fileWriteActivityLabel(name: "edit_file", isRunning: true), "Updating")
        XCTAssertEqual(ToolCallGrouping.fileWriteActivityLabel(name: "edit_file", isRunning: false), "Updated")
        XCTAssertEqual(ToolCallGrouping.fileWriteActivityLabel(name: "apply_patch", isRunning: true), "Updating")
        XCTAssertEqual(ToolCallGrouping.fileWriteActivityLabel(name: "delete_file", isRunning: false), "Deleted")
    }

    func testTurnTotalsFromExistingChangeSummary() {
        let summary = TurnChangeSummary(files: [
            .init(path: "a.swift", added: 4, removed: 1, status: .created),
            .init(path: "b.swift", added: 0, removed: 3, status: .deleted),
        ])
        let totals = FileChangeTurnTotals.from(summary)
        XCTAssertEqual(totals.fileCount, 2)
        XCTAssertEqual(totals.added, 4)
        XCTAssertEqual(totals.deleted, 4)
        XCTAssertEqual(summary.fileCount, 2)
        XCTAssertEqual(summary.totalAdded, 4)
        XCTAssertEqual(summary.totalRemoved, 4)
    }

    func testEmptyExploreShowsZeroFiles() {
        let groups = ToolCallGrouping.group([])
        XCTAssertTrue(groups.isEmpty)
        let onlyShell = ToolCallGrouping.group([ToolCallEvent(name: "run_shell", parsedCommand: "ls")])
        XCTAssertEqual(onlyShell.count, 1)
        guard case .shell(let card) = onlyShell[0] else {
            return XCTFail("shell is a shell card")
        }
        XCTAssertEqual(card.command, "ls")
        XCTAssertEqual(card.kindLabel, "Ran")
        XCTAssertNil(card.statusLabel)
    }

    func testHidesRunningShellWithEmptyCommand() {
        let events = [
            ToolCallEvent(name: "grep_code"),
            ToolCallEvent(name: "run_shell", isRunning: true, parsedCommand: ""),
            ToolCallEvent(name: "read_file"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 1)
        guard case .explore(let counts, let members) = groups[0] else {
            return XCTFail("noisy in-flight bash skipped; reads stay one Explore")
        }
        XCTAssertEqual(counts.searches, 1)
        XCTAssertEqual(counts.files, 1)
        XCTAssertEqual(members, [0, 2])
    }

    func testEmptyRunningShellDoesNotBreakFileChangeGroup() {
        let events = [
            ToolCallEvent(name: "write_file", path: "a.swift", added: 2),
            ToolCallEvent(name: "run_shell", isRunning: true, parsedCommand: ""),
            ToolCallEvent(name: "edit_file", path: "b.swift", added: 1, deleted: 1),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 1)
        guard case .fileChange(let counts, let members) = groups[0] else {
            return XCTFail("empty in-flight bash skipped; writes stay one family")
        }
        XCTAssertEqual(members, [0, 2])
        XCTAssertEqual(counts.writes, 1)
        XCTAssertEqual(counts.updates, 1)
        XCTAssertEqual(counts.fileCount, 2)
    }

    func testFinishedShellDoesNotJoinExplore() {
        let events = [
            ToolCallEvent(name: "read_file"),
            ToolCallEvent(name: "run_shell", isRunning: false, parsedCommand: "gh pr view 1"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 2)
        guard case .explore = groups[0] else { return XCTFail("read is explore") }
        guard case .shell(let card) = groups[1] else {
            return XCTFail("finished shell is its own card")
        }
        XCTAssertEqual(card.command, "gh pr view 1")
        XCTAssertEqual(card.status, .success)
        XCTAssertEqual(card.kindLabel, "Ran")
    }

    func testStopWhenMergedBanner() {
        XCTAssertTrue(GitHubPRStatusPolicy.shouldStopAfterMerged("PR_STATUS: MERGED\nrest"))
        XCTAssertTrue(ToolCallGrouping.shouldStopToolBurst(
            lastResultContent: GitHubPRStatusPolicy.mergedBanner,
            toolEvents: []))
        XCTAssertFalse(GitHubPRStatusPolicy.shouldStopAfterMerged(nil))
        XCTAssertFalse(GitHubPRStatusPolicy.shouldStopAfterMerged(""))
        XCTAssertFalse(GitHubPRStatusPolicy.shouldStopAfterMerged(#"{"merged": false}"#))
    }

    func testStopWhenExploreBurstFinished() {
        let events = [
            ToolCallEvent(name: "grep_code"),
            ToolCallEvent(name: "list_directory"),
            ToolCallEvent(name: "read_file"),
        ]
        XCTAssertTrue(ToolCallGrouping.exploreBurstFinished(events))
        XCTAssertTrue(ToolCallGrouping.shouldStopToolBurst(
            lastResultContent: "ok",
            toolEvents: events))
    }

    func testDoesNotStopWhileExploreStillRunning() {
        let events = [
            ToolCallEvent(name: "grep_code"),
            ToolCallEvent(name: "read_file", isRunning: true),
        ]
        XCTAssertFalse(ToolCallGrouping.exploreBurstFinished(events))
        XCTAssertFalse(ToolCallGrouping.shouldStopToolBurst(
            lastResultContent: "searching",
            toolEvents: events))
    }

    func testGroupingHelperDoesNotClaimVibeCoderIsZCode() {
        let src = try! String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentCore/Tools/ToolCallGrouping.swift"),
            encoding: .utf8)
        let lower = src.lowercased()
        XCTAssertFalse(lower.contains("vibecoder is zcode"))
        XCTAssertFalse(lower.contains("we are zcode"))
        XCTAssertTrue(src.contains("Consecutive read-only tools → one Explore card."))
    }

    func testDoesNotStopOnStandaloneWrite() {
        let events = [ToolCallEvent(name: "write_file")]
        XCTAssertFalse(ToolCallGrouping.exploreBurstFinished(events))
        XCTAssertFalse(ToolCallGrouping.shouldStopToolBurst(
            lastResultContent: "wrote",
            toolEvents: events))
    }

    func testRunningShellWithCommandShowsRunningKind() {
        let events = [ToolCallEvent(name: "run_shell", isRunning: true, parsedCommand: "swift test")]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 1)
        guard case .shell(let card) = groups[0] else {
            return XCTFail("expected shell card")
        }
        XCTAssertEqual(card.status, .running)
        XCTAssertEqual(card.kindLabel, "Running")
        XCTAssertNil(card.statusLabel)
        XCTAssertEqual(card.command, "swift test")
        XCTAssertEqual(card.index, 0)
    }

    func testWhitespaceOnlyInFlightShellIsSkipped() {
        let events = [
            ToolCallEvent(name: "run_shell", isRunning: true, parsedCommand: " \t  "),
            ToolCallEvent(name: "update_todo"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 1)
        guard case .standalone(_, .todo) = groups[0] else {
            return XCTFail("noisy in-flight bash skipped")
        }
    }

    func testShellFailedDeniedStoppedOverlays() {
        let cases: [(ShellToolStatus, String)] = [
            (.failed, "Failed"),
            (.denied, "Denied"),
            (.stopped, "Stopped"),
        ]
        for (status, label) in cases {
            let events = [ToolCallEvent(
                name: "run_shell",
                parsedCommand: "rm -rf /tmp/x",
                shellStatus: status)]
            let groups = ToolCallGrouping.group(events)
            guard case .shell(let card) = groups[0] else {
                return XCTFail("expected shell card for \(status)")
            }
            XCTAssertEqual(card.kindLabel, "Ran")
            XCTAssertEqual(card.statusLabel, label)
            XCTAssertEqual(card.status, status)
        }
        XCTAssertEqual(ToolCallGrouping.shellKindLabel(.running), "Running")
        XCTAssertEqual(ToolCallGrouping.shellKindLabel(.success), "Ran")
        XCTAssertNil(ToolCallGrouping.shellStatusLabel(.success))
        XCTAssertNil(ToolCallGrouping.shellStatusLabel(.running))
    }

    func testShellStatusRunningWithoutIsRunningFlagStillSkippedWhenEmpty() {
        let events = [
            ToolCallEvent(name: "grep_code"),
            ToolCallEvent(name: "run_shell", parsedCommand: nil, shellStatus: .running),
            ToolCallEvent(name: "read_file"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 1)
        guard case .explore(let counts, let members) = groups[0] else {
            return XCTFail("empty running shell skipped")
        }
        XCTAssertEqual(counts.searches, 1)
        XCTAssertEqual(counts.files, 1)
        XCTAssertEqual(members, [0, 2])
    }

    func testFinishedEmptyCommandShellStillShowsCard() {
        let events = [ToolCallEvent(name: "run_shell", parsedCommand: "", shellStatus: .success)]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 1)
        guard case .shell(let card) = groups[0] else {
            return XCTFail("finished empty command is still a card")
        }
        XCTAssertEqual(card.command, "")
        XCTAssertEqual(card.kindLabel, "Ran")
    }

    func testLongRunningShellCarriesStartAndChipLabel() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let now = start.addingTimeInterval(12)
        let events = [ToolCallEvent(
            name: "run_shell",
            isRunning: true,
            parsedCommand: "sleep 30",
            startedAt: start)]
        let groups = ToolCallGrouping.group(events)
        guard case .shell(let card) = groups[0] else {
            return XCTFail("expected running shell card")
        }
        XCTAssertEqual(card.startedAt, start)
        XCTAssertEqual(card.elapsedSeconds(now: now), 12)
        XCTAssertEqual(card.longRunningChipLabel(now: now), "Running for 12s")
        XCTAssertEqual(card.kindLabel, "Running")
        let listed = ToolCallGrouping.longRunningShells(events)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].command, "sleep 30")
    }

    func testLongRunningChipFormatsMinutes() {
        XCTAssertEqual(ToolCallGrouping.longRunningChipLabel(elapsedSeconds: 0), "Running for 0s")
        XCTAssertEqual(ToolCallGrouping.longRunningChipLabel(elapsedSeconds: 59), "Running for 59s")
        XCTAssertEqual(ToolCallGrouping.longRunningChipLabel(elapsedSeconds: 60), "Running for 1m 0s")
        XCTAssertEqual(ToolCallGrouping.longRunningChipLabel(elapsedSeconds: 125), "Running for 2m 5s")
        XCTAssertEqual(ToolCallGrouping.longRunningChipLabel(elapsedSeconds: -3), "Running for 0s")
    }

    func testFinishedShellHasNoLongRunningChip() {
        let start = Date(timeIntervalSince1970: 50)
        let events = [ToolCallEvent(
            name: "run_shell",
            parsedCommand: "ls",
            shellStatus: .success,
            startedAt: start)]
        guard case .shell(let card) = ToolCallGrouping.group(events)[0] else {
            return XCTFail("expected shell")
        }
        XCTAssertEqual(card.startedAt, start)
        XCTAssertNil(card.longRunningChipLabel(now: start.addingTimeInterval(8)))
        XCTAssertTrue(ToolCallGrouping.longRunningShells(events).isEmpty)
    }

    func testEmptyInFlightShellIsNotALongRunningChip() {
        let events = [ToolCallEvent(
            name: "run_shell",
            isRunning: true,
            parsedCommand: "",
            startedAt: Date())]
        XCTAssertTrue(ToolCallGrouping.group(events).isEmpty)
        XCTAssertTrue(ToolCallGrouping.longRunningShells(events).isEmpty)
    }

    func testShellDoesNotJoinAdjacentShells() {
        let events = [
            ToolCallEvent(name: "run_shell", parsedCommand: "ls"),
            ToolCallEvent(name: "run_shell", parsedCommand: "pwd", shellStatus: .failed),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 2)
        guard case .shell(let a) = groups[0], case .shell(let b) = groups[1] else {
            return XCTFail("each shell is its own card")
        }
        XCTAssertEqual(a.command, "ls")
        XCTAssertEqual(b.statusLabel, "Failed")
    }
}
