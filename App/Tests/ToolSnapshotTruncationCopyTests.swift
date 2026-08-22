//
//  ToolSnapshotTruncationCopyTests.swift
//
//  Mira QA: characterize truncated tool-card copy as painted (Sable 77fa044).
//  Notice as-is: "N tool field(s) were truncated. Showing preview X / Y.
//  Load full tool data". Product is VibeCoder. Looks like ZCode snapshot
//  chrome. Not ZCode. Not Electron. Does not stamp 99%.
//  PRODUCT_NAME VibeCoderTests.
//
//  Honesty: Activity expand and MCP cards both paint the notice plus a
//  local "Load full tool data" control that uncaps the already-held
//  snapshot in memory — not a network fetch. Approve / Continue / Submit
//  stay labels on other cards (not claimed here).
//

import XCTest
@testable import AgentCore
@testable import VibeCoderApp

final class ToolSnapshotTruncationCopyTests: XCTestCase {

    func testNoticeCopyIsNFieldsShowingPreviewXYLoadFullToolData() {
        XCTAssertNil(ToolSnapshotCardCopy.notice(
            ToolSnapshotTruncation.snapshot(args: "ok", result: "done")))

        let one = ToolSnapshotTruncation.snapshot(
            args: "{}",
            result: String(repeating: "a", count: 5_000))
        XCTAssertEqual(
            ToolSnapshotCardCopy.notice(one),
            "1 tool field(s) were truncated. Showing preview 2000 / 5000. Load full tool data")
        XCTAssertEqual(one.notice, ToolSnapshotCardCopy.notice(one))

        let two = ToolSnapshotTruncation.snapshot(
            args: String(repeating: "b", count: 3_000),
            result: String(repeating: "c", count: 4_000),
            limit: 1_000)
        XCTAssertEqual(
            ToolSnapshotCardCopy.notice(two),
            "2 tool field(s) were truncated. Showing preview 2000 / 7000. Load full tool data")

        XCTAssertEqual(ToolSnapshotCardCopy.loadFullToolData, "Load full tool data")
        XCTAssertFalse(ToolSnapshotCardCopy.loadFullToolData.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(ToolSnapshotCardCopy.loadFullToolData.localizedCaseInsensitiveContains("99%"))
        XCTAssertFalse(ToolSnapshotCardCopy.loadFullToolData.localizedCaseInsensitiveContains("electron"))
    }

    func testActivityCardPaintsNoticeAndLocalLoadControl() throws {
        let src = try appSource("Views/Chat/ZCodeActivityLineView.swift")
        XCTAssertTrue(src.contains("ToolSnapshotCardCopy.notice(toolSnapshot)"))
        XCTAssertTrue(src.contains("Button(ToolSnapshotCardCopy.loadFullToolData)"))
        XCTAssertTrue(src.contains("showFullDetail = true"))
        XCTAssertTrue(src.contains("showFullDetail ? previewText(state.input, limit: nil) : toolSnapshot.args.preview"))
        XCTAssertTrue(src.contains("showFullDetail ? previewText(state.output, limit: nil) : toolSnapshot.result.preview"))
        XCTAssertFalse(
            src.contains("URLSession"),
            "Load full tool data must not be documented as a network fetch")
        XCTAssertFalse(src.localizedCaseInsensitiveContains("99%"))
        assertNotProductIdentityLies(in: src, file: "ZCodeActivityLineView.swift")
    }

    func testMCPCardPaintsNoticeAndLocalLoadControlUncappingInMemorySnapshot() throws {
        let src = try appSource("Views/Chat/ZCodeActivityLineView.swift")
        let start = src.range(of: "private struct MCPActivityCard")
        XCTAssertNotNil(start, "MCP row is MCPActivityCard")
        let rest = src[start!.lowerBound...]
        let end = rest.range(of: "struct ZCodeActivityStack")
        XCTAssertNotNil(end)
        let mcp = String(rest[..<end!.lowerBound])
        XCTAssertTrue(mcp.contains("ToolSnapshotCardCopy.notice(snap)"))
        XCTAssertTrue(mcp.contains("Text(notice)"))
        XCTAssertTrue(
            mcp.contains("Button(ToolSnapshotCardCopy.loadFullToolData)"),
            "MCP Load full tool data is a control that uncaps the in-memory snapshot")
        XCTAssertTrue(mcp.contains("showFull = true"))
        XCTAssertTrue(mcp.contains("showFull ? card.parameters : snap.args.preview"))
        XCTAssertTrue(mcp.contains("showFull ? card.result : snap.result.preview"))
        XCTAssertFalse(
            mcp.contains("URLSession"),
            "Load full tool data must not be a network fetch")
        XCTAssertFalse(mcp.localizedCaseInsensitiveContains("fetch extra"))
        XCTAssertFalse(mcp.localizedCaseInsensitiveContains("99%"))
        let row = try appSource("Views/Chat/ZCodeActivityLineView.swift")
        XCTAssertTrue(row.contains("MCPActivityCard(card: card)"))
    }

    func testPaintedCopyDoesNotClaimZCodeOrStamp99() throws {
        for rel in [
            "Utilities/SettingsDiscoverabilityCopy.swift",
            "Views/Chat/ZCodeActivityLineView.swift",
        ] {
            assertNotProductIdentityLies(in: try appSource(rel), file: rel)
        }
        let notice = ToolSnapshotCardCopy.notice(
            ToolSnapshotTruncation.snapshot(
                args: "{}",
                result: String(repeating: "a", count: 5_000))) ?? ""
        XCTAssertFalse(notice.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(notice.localizedCaseInsensitiveContains("99%"))
        XCTAssertFalse(notice.localizedCaseInsensitiveContains("electron"))
    }

    private func assertNotProductIdentityLies(in text: String, file: String) {
        let lower = text.lowercased()
        XCTAssertFalse(lower.contains("vibecoder is zcode"), "\(file) must not claim VibeCoder IS ZCode")
        XCTAssertFalse(lower.contains("we are zcode"), "\(file) must not claim the product is ZCode")
        XCTAssertFalse(
            lower.contains("this app is electron") || lower.contains("vibecoder is electron"),
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
