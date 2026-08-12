//
//  GovernorTests.swift
//
//  Pins the Governor's hard-fail logic, especially the verifier-persistence
//  "progress" rule that is the whole reason this exists.
//

import XCTest
@testable import AgentCore

final class GovernorTests: XCTestCase {

    // MARK: identical-repetition

    func testDetectsIdenticalRepetition() {
        let call = ToolCallSnapshot(tool: "patch", arguments: #"{"path":"x.swift"}"#)
        let recent = Array(repeating: call, count: 6)
        let signal = Governor.evaluate(recentToolCalls: recent, recentErrorCounts: [], lastToolOutput: nil)
        guard case .identicalToolCallRepetition(let tool, _)? = signal else {
            return XCTFail("expected repetition signal, got \(String(describing: signal))")
        }
        XCTAssertEqual(tool, "patch")
    }

    func testNoRepetitionWhenArgumentsDiffer() {
        let recent = (0..<6).map {
            ToolCallSnapshot(tool: "patch", arguments: #"{"path":"f\#($0).swift"}"#)
        }
        XCTAssertNil(Governor.evaluate(recentToolCalls: recent, recentErrorCounts: [], lastToolOutput: nil))
    }

    func testNoRepetitionBelowThreshold() {
        let call = ToolCallSnapshot(tool: "patch", arguments: "{}")
        let recent = Array(repeating: call, count: 2)
        XCTAssertNil(Governor.evaluate(recentToolCalls: recent, recentErrorCounts: [], lastToolOutput: nil))
    }

    // MARK: verifier-persistence — the progress rule

    func testDetectsPersistenceWhenErrorsFlat() {
        let signal = Governor.evaluate(recentToolCalls: [], recentErrorCounts: [4, 4, 4], lastToolOutput: nil)
        guard case .verifierFailurePersistent? = signal else {
            return XCTFail("expected persistence signal, got \(String(describing: signal))")
        }
    }

    func testDetectsPersistenceWhenErrorsRising() {
        let signal = Governor.evaluate(recentToolCalls: [], recentErrorCounts: [2, 3, 5], lastToolOutput: nil)
        guard case .verifierFailurePersistent? = signal else {
            return XCTFail("expected persistence signal, got \(String(describing: signal))")
        }
    }

    func testNoPersistenceWhenErrorsShrink() {
        // 5 → 3 → 1: making progress → KEEP GOING. The rule that separates a
        // useful fix-loop from the 5/10 thrash.
        XCTAssertNil(Governor.evaluate(recentToolCalls: [], recentErrorCounts: [5, 3, 1], lastToolOutput: nil))
    }

    func testNoPersistenceWhenACountIsZero() {
        XCTAssertNil(Governor.evaluate(recentToolCalls: [], recentErrorCounts: [2, 0, 2], lastToolOutput: nil))
    }

    func testNoPersistenceBelowWindow() {
        XCTAssertNil(Governor.evaluate(recentToolCalls: [], recentErrorCounts: [4, 4], lastToolOutput: nil))
    }

    // MARK: runaway output

    func testDetectsRunawayOutput() {
        let signal = Governor.evaluate(recentToolCalls: [], recentErrorCounts: [],
                                       lastToolOutput: ("read_file", 100 * 1024 + 1))
        guard case .runawayOutput? = signal else {
            return XCTFail("expected runaway signal, got \(String(describing: signal))")
        }
    }

    func testNoRunawayAtExactThreshold() {
        XCTAssertNil(Governor.evaluate(recentToolCalls: [], recentErrorCounts: [],
                                       lastToolOutput: ("read_file", 100 * 1024)))
    }

    // MARK: priority + healthy

    func testRepetitionTakesPriorityOverPersistence() {
        let call = ToolCallSnapshot(tool: "patch", arguments: "{}")
        let signal = Governor.evaluate(recentToolCalls: Array(repeating: call, count: 6),
                                       recentErrorCounts: [4, 4, 4], lastToolOutput: nil)
        guard case .identicalToolCallRepetition? = signal else {
            return XCTFail("expected repetition to win, got \(String(describing: signal))")
        }
    }

    func testHealthySessionReturnsNil() {
        let recent = [
            ToolCallSnapshot(tool: "read_file", arguments: #"{"path":"a"}"#),
            ToolCallSnapshot(tool: "patch", arguments: #"{"path":"b"}"#),
        ]
        XCTAssertNil(Governor.evaluate(recentToolCalls: recent, recentErrorCounts: [1],
                                       lastToolOutput: ("read_file", 100)))
    }

    // MARK: errorCount log parser

    func testErrorCountParsesSwiftBuildLog() {
        let log = """
        Compiling AgentCore Governor.swift
        /path/Foo.swift:12:5: error: cannot find 'bar' in scope
        /path/Foo.swift:20:1: error: expected '}'
        /path/Baz.swift:3:9: warning: unused variable
        """
        XCTAssertEqual(Governor.errorCount(inBuildLog: log), 2)
    }

    func testErrorCountZeroOnCleanLog() {
        XCTAssertEqual(Governor.errorCount(inBuildLog: "Build complete!"), 0)
    }
}
