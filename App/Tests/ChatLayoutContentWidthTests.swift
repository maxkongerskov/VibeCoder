//
//  ChatLayoutContentWidthTests.swift
//  Wave LAYOUT W1 — locks Theme.ChatLayout fluid column math.
//

import XCTest
@testable import VibeCoderApp

final class ChatLayoutContentWidthTests: XCTestCase {

    private typealias L = Theme.ChatLayout

    // MARK: - sideGutter

    func testSideGutterClampedToMinMax() {
        XCTAssertEqual(L.sideGutter(forPaneWidth: 0), L.sideGutter)
        XCTAssertEqual(L.sideGutter(forPaneWidth: 100), L.sideGutter) // 6% = 6 → floor 24
        XCTAssertEqual(L.sideGutter(forPaneWidth: 400), L.sideGutter) // 6% = 24
        XCTAssertEqual(L.sideGutter(forPaneWidth: 800), 48, accuracy: 0.001)
        XCTAssertEqual(L.sideGutter(forPaneWidth: 1600), L.maxSideGutter)
        XCTAssertEqual(L.sideGutter(forPaneWidth: 3000), L.maxSideGutter)
    }

    // MARK: - contentWidth

    func testZeroAndNegativePane() {
        XCTAssertEqual(L.contentWidth(paneWidth: 0), 0)
        XCTAssertEqual(L.contentWidth(paneWidth: -10), 0)
    }

    func testUltraNarrowUsesFullPane() {
        // Cannot fit 2×24 gutters — column = pane (usable split).
        XCTAssertEqual(L.contentWidth(paneWidth: 40), 40)
        XCTAssertEqual(L.contentWidth(paneWidth: 48), 48)
    }

    func testNarrowSplitUsesAvailableBelowMin() {
        // 280 − 2×24 = 232 < minContentWidth 320 → still 232 (no overflow).
        let w = L.contentWidth(paneWidth: 280)
        XCTAssertEqual(w, 232, accuracy: 0.001)
        XCTAssertLessThan(w, L.minContentWidth)
        XCTAssertLessThanOrEqual(w, 280)
    }

    func testMidPaneGrowsWithWindow() {
        // 800: gutter = 48 → available 704.
        let w = L.contentWidth(paneWidth: 800)
        XCTAssertEqual(w, 704, accuracy: 0.001)
        XCTAssertGreaterThan(w, L.minContentWidth)
        XCTAssertLessThan(w, L.maxContentWidth)
    }

    func testWidePaneSoftMax() {
        // Once available ≥ 1040, column stays at soft max (not stuck at 720).
        let atCap = L.contentWidth(paneWidth: 1200) // gutters 72 → avail 1056 → 1040
        XCTAssertEqual(atCap, L.maxContentWidth, accuracy: 0.001)
        let ultra = L.contentWidth(paneWidth: 2000) // gutters 96 → avail 1808 → 1040
        XCTAssertEqual(ultra, L.maxContentWidth, accuracy: 0.001)
        XCTAssertEqual(L.maxContentWidth, 1040, "soft max is 1040 (was 720 island)")
    }

    func testColumnNeverExceedsPane() {
        for pane in stride(from: CGFloat(0), through: 2400, by: 37) {
            let w = L.contentWidth(paneWidth: pane)
            XCTAssertLessThanOrEqual(w, pane + 0.001, "pane \(pane)")
            XCTAssertGreaterThanOrEqual(w, 0)
        }
    }

    func testMonotonicNonDecreasingUntilSoftMax() {
        // Growing the pane should not shrink the column (until already at max).
        var prev: CGFloat = 0
        for pane in stride(from: CGFloat(50), through: 1400, by: 25) {
            let w = L.contentWidth(paneWidth: pane)
            XCTAssertGreaterThanOrEqual(w, prev - 0.001, "pane \(pane): \(w) < prev \(prev)")
            prev = w
        }
        XCTAssertEqual(prev, L.maxContentWidth, accuracy: 0.001)
    }
}
