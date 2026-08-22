//
//  ToolSnapshotTruncationTests.swift
//
//  Oversized tool args/result → preview + omitted counts (ZCode §3
//  chat.toolCall.snapshot). Does not grow AgentLoop.
//

import XCTest
@testable import AgentCore

final class ToolSnapshotTruncationTests: XCTestCase {

    func testUnderLimitIsPassthrough() {
        let snap = ToolSnapshotTruncation.snapshot(args: #"{"path":"a.swift"}"#, result: "ok")
        XCTAssertFalse(snap.isTruncated)
        XCTAssertNil(snap.notice)
        XCTAssertEqual(snap.truncatedFieldCount, 0)
        XCTAssertEqual(snap.omittedCount, 0)
        XCTAssertEqual(snap.args.preview, #"{"path":"a.swift"}"#)
        XCTAssertEqual(snap.result.preview, "ok")
        XCTAssertEqual(snap.args.omittedCount, 0)
        XCTAssertEqual(snap.result.omittedCount, 0)
    }

    func testOversizedResultTruncatesWithNotice() {
        let full = String(repeating: "a", count: 5_000)
        let snap = ToolSnapshotTruncation.snapshot(args: "{}", result: full)
        XCTAssertTrue(snap.isTruncated)
        XCTAssertEqual(snap.truncatedFieldCount, 1)
        XCTAssertEqual(snap.result.shownCount, 2_000)
        XCTAssertEqual(snap.result.fullCount, 5_000)
        XCTAssertEqual(snap.result.omittedCount, 3_000)
        XCTAssertEqual(snap.result.preview, String(repeating: "a", count: 2_000))
        XCTAssertFalse(snap.args.isTruncated)
        XCTAssertEqual(snap.previewCount, 2_000)
        XCTAssertEqual(snap.fullCount, 5_000)
        XCTAssertEqual(snap.omittedCount, 3_000)
        XCTAssertEqual(
            snap.notice,
            "1 tool field(s) were truncated. Showing preview 2000 / 5000. Load full tool data"
        )
    }

    func testOversizedArgsAndResultCountTwoFields() {
        let args = String(repeating: "b", count: 3_000)
        let result = String(repeating: "c", count: 4_000)
        let snap = ToolSnapshotTruncation.snapshot(args: args, result: result, limit: 1_000)
        XCTAssertEqual(snap.truncatedFieldCount, 2)
        XCTAssertEqual(snap.args.omittedCount, 2_000)
        XCTAssertEqual(snap.result.omittedCount, 3_000)
        XCTAssertEqual(snap.previewCount, 2_000)
        XCTAssertEqual(snap.fullCount, 7_000)
        XCTAssertEqual(snap.omittedCount, 5_000)
        XCTAssertEqual(
            snap.notice,
            "2 tool field(s) were truncated. Showing preview 2000 / 7000. Load full tool data"
        )
    }

    func testExactLimitIsNotTruncated() {
        let text = String(repeating: "x", count: 100)
        let field = ToolSnapshotTruncation.field(name: "result", text: text, limit: 100)
        XCTAssertFalse(field.isTruncated)
        XCTAssertEqual(field.preview, text)
        XCTAssertEqual(field.omittedCount, 0)
    }

    func testNilBodiesAreEmptyFields() {
        let snap = ToolSnapshotTruncation.snapshot(args: nil, result: nil)
        XCTAssertFalse(snap.isTruncated)
        XCTAssertEqual(snap.args.preview, "")
        XCTAssertEqual(snap.result.preview, "")
        XCTAssertEqual(snap.args.fullCount, 0)
    }

    func testCharacterNotByteCountsForExtendedGraphemes() {
        let text = String(repeating: "🎉", count: 10)
        let field = ToolSnapshotTruncation.field(name: "args", text: text, limit: 3)
        XCTAssertTrue(field.isTruncated)
        XCTAssertEqual(field.shownCount, 3)
        XCTAssertEqual(field.fullCount, 10)
        XCTAssertEqual(field.omittedCount, 7)
        XCTAssertEqual(field.preview, "🎉🎉🎉")
    }

    func testZeroLimitOmitsEntireField() {
        let field = ToolSnapshotTruncation.field(name: "result", text: "hello", limit: 0)
        XCTAssertEqual(field.preview, "")
        XCTAssertEqual(field.shownCount, 0)
        XCTAssertEqual(field.omittedCount, 5)
        XCTAssertTrue(field.isTruncated)
    }
}
