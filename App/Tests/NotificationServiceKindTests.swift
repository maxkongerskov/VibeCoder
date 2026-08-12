//
//  NotificationServiceKindTests.swift
//  Product S6 — pure Kind title/body (no system notification post).
//

import XCTest
@testable import VibeCoderApp

final class NotificationServiceKindTests: XCTestCase {

    func testCompletedSummaryAndEmptyFallback() {
        let with = NotificationService.Kind.completed(taskSummary: "Fixed the bug")
        XCTAssertTrue(with.title.lowercased().contains("complete"))
        XCTAssertEqual(with.body, "Fixed the bug")
        XCTAssertNil(with.sound)

        let empty = NotificationService.Kind.completed(taskSummary: "")
        XCTAssertTrue(empty.body.lowercased().contains("finished"))
    }

    func testBudgetAndLoopHaveSound() {
        let budget = NotificationService.Kind.budgetExceeded(iterations: 30)
        XCTAssertTrue(budget.body.contains("30"))
        XCTAssertNotNil(budget.sound)

        let looped = NotificationService.Kind.looped(signature: "read_file")
        XCTAssertTrue(looped.body.contains("read_file"))
        XCTAssertNotNil(looped.sound)
    }
}
