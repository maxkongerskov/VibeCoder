//
//  ToolArgumentsTests.swift
//
//  Tests for `ToolArguments` — the parameter-unwrapping joint between
//  the model's tool-call JSON and every tool's `execute(...)` body. Bugs
//  here surface as misdiagnosed "Missing X" errors that look like model
//  mistakes; pinning the contract down with tests keeps that
//  confusion off the radar.
//

import XCTest
@testable import AgentCore

final class ToolArgumentsTests: XCTestCase {

    // MARK: - JSON init

    func testParsesValidJSON() throws {
        let json = #"{"path": "Sources/foo.swift", "lines": 10}"#
        let args = try ToolArguments(json: json)
        XCTAssertEqual(try args.string("path"), "Sources/foo.swift")
        XCTAssertEqual(try args.int("lines"), 10)
    }

    func testThrowsOnInvalidJSON() {
        XCTAssertThrowsError(try ToolArguments(json: "not-json-at-all")) { error in
            guard case ToolError.invalidArguments = error else {
                return XCTFail("Expected ToolError.invalidArguments, got \(error)")
            }
        }
    }

    func testThrowsOnNonObjectJSON() {
        // JSON arrays at root are invalid for tool args (they must be
        // a key/value dict).
        XCTAssertThrowsError(try ToolArguments(json: "[1, 2, 3]"))
    }

    func testInitFromDictionary() {
        let args = ToolArguments(dictionary: ["path": "x", "lines": 5])
        XCTAssertEqual(try? args.string("path"), "x")
        XCTAssertEqual(try? args.int("lines"), 5)
    }

    // MARK: - string

    func testStringThrowsOnMissing() {
        let args = ToolArguments(dictionary: [:])
        XCTAssertThrowsError(try args.string("path")) { error in
            guard case ToolError.invalidArguments(let msg) = error else {
                return XCTFail("Expected invalidArguments, got \(error)")
            }
            XCTAssertTrue(msg.contains("path"),
                          "Error message should name the missing key: \(msg)")
        }
    }

    func testStringThrowsOnWrongType() {
        let args = ToolArguments(dictionary: ["path": 42])
        XCTAssertThrowsError(try args.string("path"))
    }

    func testStringOptionalReturnsNilOnMissing() {
        let args = ToolArguments(dictionary: [:])
        XCTAssertNil(args.stringOptional("path"))
    }

    func testStringOptionalReturnsNilOnWrongType() {
        let args = ToolArguments(dictionary: ["path": 42])
        XCTAssertNil(args.stringOptional("path"))
    }

    // MARK: - int

    func testIntFromInteger() throws {
        let args = ToolArguments(dictionary: ["count": 42])
        XCTAssertEqual(try args.int("count"), 42)
    }

    func testIntCoercesFromDouble() throws {
        // JSON numbers come back as Double from JSONSerialization for
        // any value without a decimal point AND for ones with. The int
        // accessor must accept Double and truncate.
        let args = ToolArguments(dictionary: ["count": 42.0])
        XCTAssertEqual(try args.int("count"), 42)
    }

    func testIntTruncatesDoubleWithDecimal() throws {
        let args = ToolArguments(dictionary: ["count": 42.7])
        XCTAssertEqual(try args.int("count"), 42, "Should truncate, not round")
    }

    func testIntThrowsOnMissing() {
        let args = ToolArguments(dictionary: [:])
        XCTAssertThrowsError(try args.int("count"))
    }

    func testIntThrowsOnString() {
        // We do NOT auto-parse string representations of numbers —
        // the model should be sending real numbers.
        let args = ToolArguments(dictionary: ["count": "42"])
        XCTAssertThrowsError(try args.int("count"))
    }

    func testIntOptionalCoercesDouble() {
        let args = ToolArguments(dictionary: ["count": 42.0])
        XCTAssertEqual(args.intOptional("count"), 42)
    }

    func testIntOptionalReturnsNilOnMissing() {
        let args = ToolArguments(dictionary: [:])
        XCTAssertNil(args.intOptional("count"))
    }

    // MARK: - bool

    func testBoolDefaultsToFalse() {
        let args = ToolArguments(dictionary: [:])
        XCTAssertFalse(args.bool("enabled"))
    }

    func testBoolHonoursExplicitDefault() {
        let args = ToolArguments(dictionary: [:])
        XCTAssertTrue(args.bool("enabled", default: true))
    }

    func testBoolReadsPresent() {
        let trueArgs = ToolArguments(dictionary: ["enabled": true])
        XCTAssertTrue(trueArgs.bool("enabled"))

        let falseArgs = ToolArguments(dictionary: ["enabled": false])
        XCTAssertFalse(falseArgs.bool("enabled"))
    }

    func testBoolDoesNotCoerceNumeric() {
        // 1/0 ↛ true/false. Strict type matching keeps surprises out.
        let args = ToolArguments(dictionary: ["enabled": 1])
        XCTAssertFalse(args.bool("enabled"),
                       "Numeric 1 should NOT coerce to true; got true (bad)")
    }

    // MARK: - stringArray

    func testStringArrayDecodes() {
        let args = ToolArguments(dictionary: ["tags": ["a", "b", "c"]])
        XCTAssertEqual(args.stringArray("tags"), ["a", "b", "c"])
    }

    func testStringArrayReturnsEmptyOnMissing() {
        let args = ToolArguments(dictionary: [:])
        XCTAssertEqual(args.stringArray("tags"), [])
    }

    func testStringArrayReturnsEmptyOnWrongType() {
        let args = ToolArguments(dictionary: ["tags": "not-an-array"])
        XCTAssertEqual(args.stringArray("tags"), [])
    }
}
