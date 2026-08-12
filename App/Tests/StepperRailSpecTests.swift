//
//  StepperRailSpecTests.swift
//

import SwiftUI
import XCTest
@testable import VibeCoderApp

final class StepperRailSpecTests: XCTestCase {

    private let spec = StepperRailSpec.standard

    func testSpecUsesTopIconAlignment() {
        XCTAssertEqual(spec.iconFrameAlignment, .top)
        XCTAssertEqual(spec.iconCenterY, 7)
        XCTAssertLessThan(spec.iconCenterY, spec.rowWithSubtitleHeight / 2)
    }

    func testConnectorHeightIsZeroForSingleStep() {
        XCTAssertEqual(spec.connectorHeight(stepCount: 0), 0)
        XCTAssertEqual(spec.connectorHeight(stepCount: 1), 0)
        XCTAssertEqual(spec.connectorHeight(rowHeights: [36]), 0)
    }

    func testConnectorHeightScalesWithUniformRowCount() {
        XCTAssertEqual(spec.connectorHeight(stepCount: 3), 72)
        XCTAssertEqual(spec.connectorHeight(stepCount: 5), 144)
    }

    func testRowHeightAccountsForSubtitle() {
        XCTAssertEqual(spec.rowHeight(hasSubtitle: false), 36)
        XCTAssertEqual(spec.rowHeight(hasSubtitle: true), 52)
        XCTAssertGreaterThan(
            spec.rowHeight(hasSubtitle: true),
            spec.rowHeight(hasSubtitle: false)
        )
    }

    func testConnectorHeightSumsNonFinalRowHeights() {
        let mixed: [CGFloat] = [36, 52, 36]
        XCTAssertEqual(spec.connectorHeight(rowHeights: mixed), 88)
        let allTall: [CGFloat] = [52, 52, 52]
        XCTAssertEqual(spec.connectorHeight(rowHeights: allTall), 104)
    }
}