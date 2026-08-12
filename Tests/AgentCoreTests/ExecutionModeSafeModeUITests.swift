//
//  ExecutionModeSafeModeUITests.swift
//  Wave C: pure mode semantics used by App permission UI.
//

import XCTest
@testable import AgentCore

/// Documents / locks the contract AppViewModel relies on for Safe Mode ↔ mode chip.
final class ExecutionModeSafeModeUITests: XCTestCase {

    func testPlanAndAskEnableSafeModeAutoAndFullDoNot() {
        XCTAssertTrue(ExecutionMode.plan.enablesSafeMode)
        XCTAssertTrue(ExecutionMode.build.enablesSafeMode)
        XCTAssertFalse(ExecutionMode.edit.enablesSafeMode)
        XCTAssertFalse(ExecutionMode.yolo.enablesSafeMode)
    }

    func testPlanIsReadOnly() {
        XCTAssertTrue(ExecutionMode.plan.isReadOnly)
        XCTAssertFalse(ExecutionMode.build.isReadOnly)
        XCTAssertFalse(ExecutionMode.edit.isReadOnly)
        XCTAssertFalse(ExecutionMode.yolo.isReadOnly)
    }

    func testCycleOrder() {
        XCTAssertEqual(ExecutionMode.plan.next(), .build)
        XCTAssertEqual(ExecutionMode.build.next(), .edit)
        XCTAssertEqual(ExecutionMode.edit.next(), .yolo)
        XCTAssertEqual(ExecutionMode.yolo.next(), .plan)
    }

    func testLabelsStableForSettingsUI() {
        XCTAssertEqual(ExecutionMode.plan.shortLabel, "Plan")
        XCTAssertEqual(ExecutionMode.build.shortLabel, "Ask")
        XCTAssertEqual(ExecutionMode.edit.shortLabel, "Auto")
        XCTAssertEqual(ExecutionMode.yolo.shortLabel, "Full")
    }
}
