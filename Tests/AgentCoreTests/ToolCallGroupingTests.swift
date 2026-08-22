//
//  ToolCallGroupingTests.swift
//
//  Explore grouping + stop-when-done (ZCode §3). Does not grow AgentLoop.
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
        guard case .standalone(let idx, let fam) = groups[1] else {
            return XCTFail("write is standalone")
        }
        XCTAssertEqual(idx, 2)
        XCTAssertEqual(fam, .fileWrite)
        guard case .explore(let third, _) = groups[2] else {
            return XCTFail("list after write starts a new explore")
        }
        XCTAssertEqual(third.lists, 1)
        XCTAssertEqual(third.files, 0)
    }

    func testEmptyExploreShowsZeroFiles() {
        let groups = ToolCallGrouping.group([])
        XCTAssertTrue(groups.isEmpty)
        let onlyShell = ToolCallGrouping.group([ToolCallEvent(name: "run_shell", parsedCommand: "ls")])
        XCTAssertEqual(onlyShell.count, 1)
        if case .explore = onlyShell[0] {
            XCTFail("shell is not explore")
        }
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

    func testFinishedShellDoesNotJoinExplore() {
        let events = [
            ToolCallEvent(name: "read_file"),
            ToolCallEvent(name: "run_shell", isRunning: false, parsedCommand: "gh pr view 1"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 2)
        guard case .explore = groups[0] else { return XCTFail("read is explore") }
        guard case .standalone(_, .shell) = groups[1] else {
            return XCTFail("finished shell is its own card")
        }
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

    func testDoesNotStopOnStandaloneWrite() {
        let events = [ToolCallEvent(name: "write_file")]
        XCTAssertFalse(ToolCallGrouping.exploreBurstFinished(events))
        XCTAssertFalse(ToolCallGrouping.shouldStopToolBurst(
            lastResultContent: "wrote",
            toolEvents: events))
    }
}
