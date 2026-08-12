//
//  ArgumentCoercerTests.swift  (Harness)
//
//  Reliability-regression fixtures for pain #1 (the dispatch seam): the
//  mistyped/missing/malformed argument shapes weak local models actually emit,
//  asserting each is either silently coerced or rejected with an actionable
//  correction.
//

import XCTest
@testable import Harness

final class ArgumentCoercerTests: XCTestCase {

    // A representative tool: a required string, an optional integer, an
    // optional boolean, an optional string-array, an enum.
    private let schema = ToolSchema(
        name: "read_file",
        description: "Read a file",
        parameters: [
            ToolParameter(name: "path", type: .string, required: true),
            ToolParameter(name: "max_lines", type: .integer),
            ToolParameter(name: "follow_symlinks", type: .boolean),
            ToolParameter(name: "globs", type: .array, arrayElementType: .string),
            ToolParameter(name: "mode", type: .string, enumValues: ["text", "binary"]),
        ])

    private func coerce(_ json: String) -> ArgCoercion {
        ArgumentCoercer.coerce(rawJSON: json, against: schema)
    }

    // MARK: - exact match

    func testExactMatchIsOk() {
        guard case .ok(let args) = coerce(#"{"path":"/etc/hosts","max_lines":10}"#) else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(args.string("path"), "/etc/hosts")
        XCTAssertEqual(args.int("max_lines"), 10)
    }

    func testEmptyArgumentsOkWhenNoRequiredMissing() {
        // The schema has a required `path`, so empty args must be rejected...
        guard case .rejected(let c) = coerce("{}") else { return XCTFail("expected rejection") }
        XCTAssertEqual(c.missing, ["path"])
    }

    func testEmptyStringTreatedAsEmptyObject() {
        // Some backends send "" for no-arg calls. Treated as {} → only the
        // required-key rejection, not a parse error.
        guard case .rejected(let c) = coerce("") else { return XCTFail("expected rejection") }
        XCTAssertNil(c.parseError)
        XCTAssertEqual(c.missing, ["path"])
    }

    // MARK: - silent coercions (the cheap cases)

    func testStringIntegerCoercedToInt() {
        guard case .correctable(let args, _) = coerce(#"{"path":"a","max_lines":"25"}"#) else {
            return XCTFail("expected .correctable")
        }
        XCTAssertEqual(args.int("max_lines"), 25)
    }

    func testStringBooleanCoerced() {
        guard case .correctable(let args, _) = coerce(#"{"path":"a","follow_symlinks":"true"}"#) else {
            return XCTFail("expected .correctable")
        }
        XCTAssertEqual(args.bool("follow_symlinks"), true)
    }

    func testIntBooleanCoerced() {
        guard case .correctable(let args, _) = coerce(#"{"path":"a","follow_symlinks":1}"#) else {
            return XCTFail("expected .correctable")
        }
        XCTAssertEqual(args.bool("follow_symlinks"), true)
    }

    func testNumberForStringCoerced() {
        // path given as a number — stringify rather than reject.
        guard case .correctable(let args, _) = coerce(#"{"path":123}"#) else {
            return XCTFail("expected .correctable")
        }
        XCTAssertEqual(args.string("path"), "123")
    }

    func testScalarWrappedIntoArray() {
        // A single glob sent bare instead of as a one-element array.
        guard case .correctable(let args, _) = coerce(#"{"path":"a","globs":"*.swift"}"#) else {
            return XCTFail("expected .correctable")
        }
        XCTAssertEqual(args.stringArray("globs"), ["*.swift"])
    }

    // MARK: - rejections (structured, actionable)

    func testMissingRequiredKeyRejected() {
        guard case .rejected(let c) = coerce(#"{"max_lines":10}"#) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(c.missing, ["path"])
        let msg = c.asToolResult()
        XCTAssertTrue(msg.isError)
        XCTAssertTrue(msg.content.contains("missing required argument `path`"))
    }

    func testUncoercibleTypeRejected() {
        // max_lines given as non-numeric text → a real type error.
        guard case .rejected(let c) = coerce(#"{"path":"a","max_lines":"a lot"}"#) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(c.typeErrors.first?.key, "max_lines")
        XCTAssertEqual(c.typeErrors.first?.expected, "integer")
        XCTAssertTrue(c.asToolResult().content.contains("`max_lines` must be integer"))
    }

    func testMalformedJSONRejectedWithParseError() {
        guard case .rejected(let c) = coerce(#"{"path": "a", oops}"#) else {
            return XCTFail("expected rejection")
        }
        XCTAssertNotNil(c.parseError)
        // Still lists required keys so the model knows what's needed.
        XCTAssertEqual(c.missing, ["path"])
    }

    func testNonObjectJSONRejected() {
        // A bare array is valid JSON but not an arguments object.
        guard case .rejected(let c) = coerce(#"["path","a"]"#) else {
            return XCTFail("expected rejection")
        }
        XCTAssertNotNil(c.parseError)
    }

    func testEnumViolationRejected() {
        guard case .rejected(let c) = coerce(#"{"path":"a","mode":"hex"}"#) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(c.typeErrors.first?.key, "mode")
        XCTAssertTrue(c.typeErrors.first?.got.contains("hex") ?? false)
    }

    func testEnumValidValueOk() {
        guard case .ok(let args) = coerce(#"{"path":"a","mode":"binary"}"#) else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(args.string("mode"), "binary")
    }

    // MARK: - unknown keys are dropped, not fatal

    func testUnknownKeysDroppedWithNote() {
        guard case .correctable(let args, let notes) = coerce(#"{"path":"a","bogus":1,"extra":"x"}"#) else {
            return XCTFail("expected .correctable (unknown keys dropped, not rejected)")
        }
        XCTAssertEqual(args.string("path"), "a")
        XCTAssertNil(args.values["bogus"])
        XCTAssertTrue(notes.contains { $0.contains("bogus") })
    }

    // MARK: - schema → wire spec

    func testToSpecProducesValidFunctionSchema() {
        let spec = schema.toSpec()
        XCTAssertEqual(spec.name, "read_file")
        let obj = try? JSONSerialization.jsonObject(
            with: Data(spec.parametersJSON.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "object")
        let required = obj?["required"] as? [String]
        XCTAssertEqual(required, ["path"])
        let props = obj?["properties"] as? [String: Any]
        let pathProp = props?["path"] as? [String: Any]
        XCTAssertEqual(pathProp?["type"] as? String, "string")
        let globsProp = props?["globs"] as? [String: Any]
        XCTAssertEqual(globsProp?["type"] as? String, "array")
        XCTAssertEqual((globsProp?["items"] as? [String: Any])?["type"] as? String, "string")
    }
}
