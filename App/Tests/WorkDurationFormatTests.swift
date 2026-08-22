//
//  WorkDurationFormatTests.swift
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class WorkDurationFormatTests: XCTestCase {
    func testSecondsUnderOneMinute() {
        XCTAssertEqual(
            WorkDurationFormat.workingLabel(seconds: 1, isLive: true),
            "Working for 1s"
        )
        XCTAssertEqual(
            WorkDurationFormat.workingLabel(seconds: 59, isLive: false),
            "Worked for 59s"
        )
    }

    func testMinutesWholeOnly() {
        XCTAssertEqual(
            WorkDurationFormat.workingLabel(seconds: 60, isLive: true),
            "Working for 1 minute"
        )
        XCTAssertEqual(
            WorkDurationFormat.workingLabel(seconds: 125, isLive: false),
            "Worked for 2 minutes"
        )
        XCTAssertEqual(
            WorkDurationFormat.workingLabel(seconds: 180, isLive: false),
            "Worked for 3 minutes"
        )
    }

    func testShortElapsed() {
        XCTAssertEqual(WorkDurationFormat.shortElapsed(seconds: 12, streaming: true), "12s")
        XCTAssertEqual(WorkDurationFormat.shortElapsed(seconds: 90, streaming: false), "1 minute")
        XCTAssertEqual(WorkDurationFormat.shortElapsed(seconds: 0, streaming: true), "…")
    }

    func testThoughtForAndWorkingForLabels() {
        XCTAssertEqual(
            "Thought for \(WorkDurationFormat.shortElapsed(seconds: 8, streaming: false))",
            "Thought for 8s")
        XCTAssertEqual(
            WorkDurationFormat.workingLabel(seconds: 8, isLive: true),
            "Working for 8s")
    }

    func testComposerAndShellUseSableRunningForAsIsNotWorkDurationRestyle() {
        // Sable chip: "Running for Ns" / "Running for Nm Ns". Do not restyle
        // to WorkDurationFormat ("Working for 1 minute").
        XCTAssertEqual(ToolCallGrouping.longRunningChipLabel(elapsedSeconds: 12), "Running for 12s")
        XCTAssertEqual(ToolCallGrouping.longRunningChipLabel(elapsedSeconds: 125), "Running for 2m 5s")
        XCTAssertNotEqual(
            ToolCallGrouping.longRunningChipLabel(elapsedSeconds: 125),
            "Working for \(WorkDurationFormat.durationPhrase(seconds: 125, allowZero: false))")
        XCTAssertNotEqual(
            ToolCallGrouping.longRunningChipLabel(elapsedSeconds: 60),
            WorkDurationFormat.workingLabel(seconds: 60, isLive: true))

        let start = Date(timeIntervalSince1970: 1_000)
        let running = ShellCard(
            index: 0,
            status: .running,
            command: "sleep 30",
            startedAt: start)
        XCTAssertEqual(running.kindLabel, "Running")
        XCTAssertEqual(
            ShellCardCopy.status(running, now: start.addingTimeInterval(12)),
            "Running for 12s")
        XCTAssertEqual(
            ShellCardCopy.status(running, now: start.addingTimeInterval(125)),
            ToolCallGrouping.longRunningChipLabel(elapsedSeconds: 125))

        let finished = ShellCard(index: 0, status: .success, command: "ls")
        XCTAssertEqual(finished.kindLabel, "Ran")
        XCTAssertEqual(ShellCardCopy.status(finished), "Ran")
        XCTAssertFalse(ShellCardCopy.status(finished).localizedCaseInsensitiveContains("worked for"))
        XCTAssertFalse(ShellCardCopy.status(running, now: start.addingTimeInterval(12))
            .localizedCaseInsensitiveContains("working for"))
        XCTAssertFalse(ShellCardCopy.status(running, now: start.addingTimeInterval(12))
            .localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(ShellCardCopy.status(running, now: start.addingTimeInterval(12))
            .localizedCaseInsensitiveContains("99%"))
    }

    func testChatSourcesPassSableDurationThroughWithoutRestyle() throws {
        let chat = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Views/ChatView.swift"),
            encoding: .utf8)
        XCTAssertTrue(chat.contains("ToolCallGrouping.longRunningChipLabel(elapsedSeconds:"))
        XCTAssertFalse(chat.contains("WorkDurationFormat.workingLabel"))
        XCTAssertFalse(chat.contains("WorkDurationFormat.shortElapsed"))

        let line = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Views/Chat/ZCodeActivityLineView.swift"),
            encoding: .utf8)
        XCTAssertTrue(line.contains("ShellCardCopy.status(card, now:"))
        XCTAssertTrue(line.contains("Text(card.kindLabel)"))
        XCTAssertFalse(line.contains("WorkDurationFormat.workingLabel"))
        XCTAssertFalse(line.contains("WorkDurationFormat.shortElapsed"))
    }
}
