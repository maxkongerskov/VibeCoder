//
//  FileChangeGroupingCopyTests.swift
//
//  Characterization of file-change grouping copy/structure (Sable, local).
//  Consecutive writes/updates/deletes collapse to one file-change card
//  (2+); a single edit stays one activity line. Product is VibeCoder.
//  Looks like ZCode grouping. Not ZCode. Not Electron. Does not stamp 99%.
//

import XCTest
@testable import AgentCore
@testable import VibeCoderApp

final class FileChangeGroupingCopyTests: XCTestCase {

    func testConsecutiveWritesUpdatesDeletesCollapseToOneFileChangeGroup() {
        let events = [
            ToolCallEvent(name: "write_file"),
            ToolCallEvent(name: "write_file"),
            ToolCallEvent(name: "edit_file"),
            ToolCallEvent(name: "delete_file"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 1, "consecutive file writes are one file-change group")
        guard case .fileChange(let counts, let members) = groups[0] else {
            return XCTFail("expected file-change group")
        }
        XCTAssertEqual(counts.writes, 2)
        XCTAssertEqual(counts.updates, 1)
        XCTAssertEqual(counts.deletes, 1)
        XCTAssertEqual(members.count, 4)
        XCTAssertEqual(counts.total, 4)
        XCTAssertGreaterThanOrEqual(counts.total, 2)
    }

    func testSingleEditStaysOneMemberSoChatKeepsOneLine() {
        let groups = ToolCallGrouping.group([
            ToolCallEvent(name: "edit_file"),
        ])
        XCTAssertEqual(groups.count, 1)
        guard case .fileChange(let counts, let members) = groups[0] else {
            return XCTFail("single edit is still a file-change family of size 1")
        }
        XCTAssertEqual(counts.total, 1)
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(counts.updates, 1)
        XCTAssertLessThan(counts.total, 2, "chat stack only collapses when total >= 2")
    }

    func testExploreBreaksFileChangeSoChatDoesNotInventASecondChromeFamily() {
        let groups = ToolCallGrouping.group([
            ToolCallEvent(name: "write_file"),
            ToolCallEvent(name: "read_file"),
            ToolCallEvent(name: "delete_file"),
        ])
        XCTAssertEqual(groups.count, 3)
        guard case .fileChange(let first, _) = groups[0] else {
            return XCTFail("write is file-change")
        }
        XCTAssertEqual(first.writes, 1)
        XCTAssertEqual(first.total, 1)
        guard case .explore = groups[1] else { return XCTFail("read is explore") }
        guard case .fileChange(let third, _) = groups[2] else {
            return XCTFail("delete after read is a new file-change card")
        }
        XCTAssertEqual(third.deletes, 1)
    }

    func testFileChangeCardCopyIsOneLineWroteDotBuckets() {
        let twoWrites = FileChangeGroupCounts(writes: 2)
        XCTAssertEqual(FileChangeCardCopy.status(counts: twoWrites), "2 writes")
        let writeEvents = [
            ToolCallEvent(name: "write_file"),
            ToolCallEvent(name: "write_file"),
        ]
        XCTAssertEqual(
            FileChangeCardCopy.verb(events: writeEvents, memberIndices: [0, 1]),
            "Wrote")
        let line = "\(FileChangeCardCopy.verb(events: writeEvents, memberIndices: [0, 1])) · \(FileChangeCardCopy.status(counts: twoWrites))"
        XCTAssertEqual(line, "Wrote · 2 writes")
        XCTAssertEqual(
            FileChangeCardCopy.status(counts: FileChangeGroupCounts(writes: 2, updates: 1, deletes: 1)),
            "2 writes, 1 update, 1 delete")
        XCTAssertEqual(
            FileChangeCardCopy.status(counts: FileChangeGroupCounts(writes: 1)),
            "1 write")
        XCTAssertFalse(line.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("electron"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("99%"))
    }

    func testChatStackCollapsesTwoPlusFileChangesToOneCardSingleStaysLine() throws {
        let src = try appSource("Views/Chat/ZCodeActivityLineView.swift")
        XCTAssertTrue(src.contains("if counts.total >= 2"))
        XCTAssertTrue(src.contains("items.append(.fileChange("))
        XCTAssertTrue(src.contains("items.append(.line(states[i]))"))
        XCTAssertTrue(src.contains("Text(verb)"))
        XCTAssertTrue(src.contains("Text(status)"))
        XCTAssertTrue(src.contains("FileChangeCardCopy.verb"))
        XCTAssertTrue(src.contains("FileChangeCardCopy.status(counts: counts)"))
        XCTAssertTrue(src.contains("accessibilityLabel(\"\\(verb) · \\(status)\")"))
        let fileChangeRowCount = src.components(separatedBy: "private func fileChangeRow(").count - 1
        XCTAssertEqual(fileChangeRowCount, 1)
        XCTAssertFalse(
            src.contains("Ask ZCode"),
            "file-change card must not use Ask ZCode")
        assertNotProductIdentityLies(in: src, file: "ZCodeActivityLineView.swift")
    }

    func testFileChangeCopyFilesDoNotClaimVibeCoderIsZCode() throws {
        let files = [
            "Utilities/SettingsDiscoverabilityCopy.swift",
            "Views/Chat/ZCodeActivityLineView.swift",
        ]
        for rel in files {
            assertNotProductIdentityLies(in: try appSource(rel), file: rel)
        }
        let verb = FileChangeCardCopy.verb(
            events: [ToolCallEvent(name: "write_file")],
            memberIndices: [0])
        XCTAssertFalse(verb.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(verb.localizedCaseInsensitiveContains("vibecoder is zcode"))
        XCTAssertFalse(
            FileChangeCardCopy.status(counts: FileChangeGroupCounts(writes: 2))
                .localizedCaseInsensitiveContains("zcode"))
    }

    func testFileChangeGroupingDoesNotStamp99PercentOrUnslothSpeed() {
        let status = FileChangeCardCopy.status(
            counts: FileChangeGroupCounts(writes: 2, updates: 1, deletes: 1))
        XCTAssertFalse(status.localizedCaseInsensitiveContains("99%"))
        XCTAssertFalse(status.localizedCaseInsensitiveContains("unsloth"))
        let verb = FileChangeCardCopy.verb(
            events: [ToolCallEvent(name: "write_file"), ToolCallEvent(name: "write_file")],
            memberIndices: [0, 1])
        XCTAssertFalse(verb.localizedCaseInsensitiveContains("99%"))
        XCTAssertEqual(verb, "Wrote")
    }

    // MARK: - helpers

    private func assertNotProductIdentityLies(in text: String, file: String) {
        let lower = text.lowercased()
        XCTAssertFalse(
            lower.contains("vibecoder is zcode"),
            "\(file) must not claim VibeCoder IS ZCode")
        XCTAssertFalse(
            lower.contains("we are zcode"),
            "\(file) must not claim the product is ZCode")
        XCTAssertFalse(
            lower.contains("this app is electron")
                || lower.contains("vibecoder is electron"),
            "\(file) must not claim Electron")
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func appSource(_ relative: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(relative), encoding: .utf8)
    }
}
