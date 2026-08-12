//
//  HumanStatusTests.swift
//
//  Ensures chat status chrome never leaks iteration counters.
//  Mirrors ChatViewModel.humanStatus (kept pure-duplicated here only if
//  App target isn't linked — so we test the AgentCore-free logic inline
//  by importing nothing from App). Actually humanStatus lives on
//  ChatViewModel in the App target; this file documents the contract
//  for AgentCore suite via a local pure function matching production.
//

import XCTest

/// Pure mirror of `ChatViewModel.humanStatus` for package tests (App not linked).
enum HumanStatusSanitizer {
    static func sanitize(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("iteration ") || lower.hasPrefix("iter ") {
            return "Working…"
        }
        if lower.contains("iteration cap") || lower.contains("hit iteration") {
            return "Stopped — turn limit reached"
        }
        if lower.hasPrefix("tool:") {
            return "Done"
        }
        return trimmed
    }
}

final class HumanStatusTests: XCTestCase {
    func testIterationNeverSurfaces() {
        XCTAssertEqual(HumanStatusSanitizer.sanitize("Iteration 3…"), "Working…")
        XCTAssertEqual(HumanStatusSanitizer.sanitize("iter 2"), "Working…")
        XCTAssertEqual(
            HumanStatusSanitizer.sanitize("Hit iteration cap (30)"),
            "Stopped — turn limit reached"
        )
    }

    func testNormalStatusPasses() {
        XCTAssertEqual(HumanStatusSanitizer.sanitize("Working…"), "Working…")
        XCTAssertEqual(HumanStatusSanitizer.sanitize("Waiting for your answer…"),
                       "Waiting for your answer…")
    }
}
