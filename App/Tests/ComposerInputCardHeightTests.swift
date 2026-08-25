//
//  ComposerInputCardHeightTests.swift
//  Locks compact idle composer height vs 6-line max.
//

import XCTest
@testable import VibeCoderApp

final class ComposerInputCardHeightTests: XCTestCase {

    private typealias L = Theme.ChatLayout

    func testIdleEditorHeightIsOneLineNotSix() {
        let idle = L.inputEditorHeight(forLineCount: 1)
        let six = L.inputEditorHeight(forLineCount: L.inputEditorMaxLines)
        XCTAssertEqual(idle, L.inputEditorMinHeight)
        XCTAssertEqual(idle, 36, accuracy: 0.001)
        XCTAssertLessThan(idle, six)
        XCTAssertLessThan(idle * 2, six, "idle must be far below the 6-line cap")
        XCTAssertLessThan(idle, L.inputEditorMaxHeight)
    }

    func testMaxEditorHeightEqualsToken() {
        XCTAssertEqual(
            L.inputEditorHeight(forLineCount: L.inputEditorMaxLines),
            L.inputEditorMaxHeight
        )
        XCTAssertEqual(L.inputEditorHeight(forLineCount: 99), L.inputEditorMaxHeight)
        XCTAssertEqual(L.inputEditorMaxHeight, 100, accuracy: 0.001)
        XCTAssertEqual(L.inputEditorMaxLines, 6)
    }

    func testCardMinHeightStaysCompactToken() {
        XCTAssertEqual(L.inputCardMinHeight, 76, accuracy: 0.001)
        XCTAssertEqual(L.inputCornerRadius, 18, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(L.idleCardContentMinHeight, L.inputCardMinHeight)
        XCTAssertLessThanOrEqual(L.idleCardContentMinHeight, 110)
    }

    func testIdleCardMathIsPadPlusOneLinePlusToolbar() {
        let expected = (L.inputVerticalPad * 2)
            + L.inputEditorMinHeight
            + L.inputStackSpacing
            + L.inputToolbarRowHeight
        XCTAssertEqual(L.idleCardContentMinHeight, expected, accuracy: 0.001)
        XCTAssertEqual(expected, 106, accuracy: 0.001) // 14×2 + 36 + 10 + 32
        XCTAssertEqual(L.inputVerticalPad, 14, accuracy: 0.001)
        XCTAssertEqual(L.inputStackSpacing, 10, accuracy: 0.001)
        XCTAssertEqual(L.inputToolbarRowHeight, 32, accuracy: 0.001)
    }

    func testLineCountHelperClampsOneToMaxLines() {
        XCTAssertEqual(L.draftLineCount(""), 1)
        XCTAssertEqual(L.draftLineCount("hello"), 1)
        XCTAssertEqual(L.clampedEditorLineCount(""), 1)
        XCTAssertEqual(L.clampedEditorLineCount("hello"), 1)
        XCTAssertEqual(L.clampedEditorLineCount("a\nb"), 2)
        XCTAssertEqual(L.clampedEditorLineCount("a\n"), 2)
        let eight = Array(repeating: "x", count: 8).joined(separator: "\n")
        XCTAssertEqual(L.draftLineCount(eight), 8)
        XCTAssertEqual(L.clampedEditorLineCount(eight), L.inputEditorMaxLines)
        XCTAssertEqual(L.inputEditorLineLimit(forLineCount: 0), 1 ... 1)
        XCTAssertEqual(L.inputEditorLineLimit(forLineCount: 1), 1 ... 1)
        XCTAssertEqual(L.inputEditorLineLimit(forLineCount: 3), 1 ... 3)
        XCTAssertEqual(L.inputEditorLineLimit(forLineCount: 99), 1 ... L.inputEditorMaxLines)
    }

    func testLongTokenWrapsWithoutNewlines() {
        let token = String(repeating: "m", count: 80)
        XCTAssertEqual(L.draftLineCount(token), 1)
        XCTAssertEqual(L.clampedEditorLineCount(token), 1)
        let wrapped = L.wrappedLineCount(token, width: 80, fontSize: L.bodyFontSize)
        XCTAssertGreaterThan(wrapped, 1, "a long token must wrap at a narrow width")
        let clamped = L.editorLineCount(token, wrappingInWidth: 80, fontSize: L.bodyFontSize)
        XCTAssertGreaterThan(clamped, 1)
        XCTAssertLessThanOrEqual(clamped, L.inputEditorMaxLines)
        XCTAssertGreaterThan(
            L.inputEditorHeight(forLineCount: clamped),
            L.inputEditorMinHeight
        )
        XCTAssertEqual(L.wrappedLineCount("", width: 80), 1)
        XCTAssertEqual(L.wrappedLineCount("hi", width: 400), 1)
        XCTAssertEqual(L.wrappedLineCount("a\nb\nc", width: 400), 3)
        let huge = String(repeating: "m", count: 400)
        XCTAssertEqual(
            L.editorLineCount(huge, wrappingInWidth: 40, fontSize: L.bodyFontSize),
            L.inputEditorMaxLines
        )
    }

    func testEditorHeightGrowsThenCaps() {
        var prev: CGFloat = 0
        for n in 1 ... L.inputEditorMaxLines {
            let h = L.inputEditorHeight(forLineCount: n)
            XCTAssertGreaterThanOrEqual(h, prev - 0.001)
            XCTAssertLessThanOrEqual(h, L.inputEditorMaxHeight)
            prev = h
        }
        XCTAssertEqual(prev, L.inputEditorMaxHeight, accuracy: 0.001)
        XCTAssertEqual(L.inputEditorHeight(forLineCount: 2), 54, accuracy: 0.001) // 36 + 18
        XCTAssertEqual(L.inputEditorHeight(forLineCount: 4), 90, accuracy: 0.001) // 36 + 3×18
    }
}
