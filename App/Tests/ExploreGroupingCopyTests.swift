//
//  ExploreGroupingCopyTests.swift
//
//  Characterization of Explore grouping copy/structure (Sable, local).
//  Consecutive searches/lists/reads collapse to one Explore group; chat
//  cards show one Explore line when the burst is 2+. Product is VibeCoder.
//  Looks like ZCode grouping. Not ZCode. Not Electron. Does not stamp 99%.
//

import XCTest
@testable import AgentCore
@testable import VibeCoderApp

final class ExploreGroupingCopyTests: XCTestCase {

    func testConsecutiveReadOnlyToolsCollapseToOneExploreGroup() {
        let events = [
            ToolCallEvent(name: "grep_code"),
            ToolCallEvent(name: "glob_files"),
            ToolCallEvent(name: "list_directory"),
            ToolCallEvent(name: "read_file"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 1, "consecutive read-only tools are one Explore group")
        guard case .explore(let counts, let members) = groups[0] else {
            return XCTFail("expected Explore group")
        }
        XCTAssertEqual(counts.searches, 2)
        XCTAssertEqual(counts.lists, 1)
        XCTAssertEqual(counts.files, 1)
        XCTAssertEqual(members.count, 4)
        XCTAssertEqual(counts.total, 4)
    }

    func testWriteBreaksExploreSoChatDoesNotInventASecondChromeFamily() {
        let groups = ToolCallGrouping.group([
            ToolCallEvent(name: "read_file"),
            ToolCallEvent(name: "write_file"),
            ToolCallEvent(name: "grep_code"),
        ])
        XCTAssertEqual(groups.count, 3)
        guard case .explore = groups[0] else { return XCTFail("read is explore") }
        guard case .fileChange(let counts, let members) = groups[1] else {
            return XCTFail("write stays its own file-change card — no invented chrome")
        }
        XCTAssertEqual(counts.writes, 1)
        XCTAssertEqual(members.count, 1)
        guard case .explore = groups[2] else { return XCTFail("search after write is a new explore") }
    }

    func testExploreCardCopyIsOneLineExploreDotBuckets() {
        XCTAssertEqual(ExploreCardCopy.verb, "Explore")
        XCTAssertEqual(
            ExploreCardCopy.status(counts: ExploreBucketCounts(searches: 2, lists: 1, files: 3)),
            "2 searches, 1 list, 3 files")
        XCTAssertEqual(
            ExploreCardCopy.status(counts: ExploreBucketCounts(searches: 1, lists: 0, files: 1)),
            "1 search, 1 file")
        XCTAssertEqual(
            ExploreCardCopy.status(counts: ExploreBucketCounts()),
            "0 files")
        let line = "\(ExploreCardCopy.verb) · \(ExploreCardCopy.status(counts: ExploreBucketCounts(searches: 2, lists: 0, files: 1)))"
        XCTAssertEqual(line, "Explore · 2 searches, 1 file")
        XCTAssertFalse(line.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("electron"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("99%"))
    }

    func testChatStackCollapsesTwoPlusReadsToOneExploreLine() throws {
        let src = try appSource("Views/Chat/ZCodeActivityLineView.swift")
        XCTAssertTrue(
            src.contains("Consecutive searches/lists/reads collapse to one Explore card (2+)"),
            "chat stack documents 2+ collapse")
        XCTAssertTrue(src.contains("if counts.total >= 2"))
        XCTAssertTrue(src.contains("items.append(.explore(id: id, counts: counts, running: running))"))
        XCTAssertTrue(src.contains("Text(ExploreCardCopy.verb)"))
        XCTAssertTrue(src.contains("Text(ExploreCardCopy.status(counts: counts))"))
        XCTAssertTrue(src.contains("accessibilityLabel(\"\\(ExploreCardCopy.verb) · \\(ExploreCardCopy.status(counts: counts))\")"))
        // One explore row builder — not a second invented card.
        let exploreRowCount = src.components(separatedBy: "private func exploreRow(").count - 1
        XCTAssertEqual(exploreRowCount, 1)
        XCTAssertFalse(
            src.contains("Ask ZCode"),
            "Explore card must not use Ask ZCode")
        assertNotProductIdentityLies(in: src, file: "ZCodeActivityLineView.swift")
    }

    func testExploreCopyFilesDoNotClaimVibeCoderIsZCode() throws {
        let files = [
            "Utilities/SettingsDiscoverabilityCopy.swift",
            "Views/Chat/ZCodeActivityLineView.swift",
        ]
        for rel in files {
            assertNotProductIdentityLies(in: try appSource(rel), file: rel)
        }
        XCTAssertFalse(ExploreCardCopy.verb.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(ExploreCardCopy.verb.localizedCaseInsensitiveContains("vibecoder is zcode"))
        XCTAssertFalse(ExploreCardCopy.status(counts: ExploreBucketCounts(searches: 1)).localizedCaseInsensitiveContains("zcode"))
    }

    func testExploreGroupingDoesNotStamp99PercentOrUnslothSpeed() {
        let status = ExploreCardCopy.status(counts: ExploreBucketCounts(searches: 2, lists: 1, files: 3))
        XCTAssertFalse(status.localizedCaseInsensitiveContains("99%"))
        XCTAssertFalse(status.localizedCaseInsensitiveContains("unsloth"))
        XCTAssertFalse(ExploreCardCopy.verb.localizedCaseInsensitiveContains("99%"))
        XCTAssertEqual(ExploreCardCopy.verb, "Explore")
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
