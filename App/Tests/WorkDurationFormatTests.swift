//
//  WorkDurationFormatTests.swift
//

import XCTest
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
}
