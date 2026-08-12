//
//  UnifiedDiffTests.swift
//

import XCTest
@testable import AgentCore

final class UnifiedDiffTests: XCTestCase {

    func testParsesSingleHunk() {
        let patch = """
        --- a/hello.swift
        +++ b/hello.swift
        @@ -1,3 +1,3 @@
         func greet() {
        -    print("hello")
        +    print("hello, world")
         }
        """
        let parsed = UnifiedDiff.parse(patch)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].path, "hello.swift")
        XCTAssertEqual(parsed[0].hunks.count, 1)
        XCTAssertEqual(parsed[0].hunks[0].lines.count, 4)
    }

    func testAppliesSimpleEdit() {
        let original = """
        func greet() {
            print("hello")
        }
        """
        let patch = """
        --- a/hello.swift
        +++ b/hello.swift
        @@ -1,3 +1,3 @@
         func greet() {
        -    print("hello")
        +    print("hello, world")
         }
        """
        let parsed = UnifiedDiff.parse(patch)
        let result = UnifiedDiff.apply(filePatch: parsed[0], to: original)
        guard case .success(let updated) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertTrue(updated.contains("print(\"hello, world\")"))
        XCTAssertFalse(updated.contains("print(\"hello\")"))
    }

    func testRejectsContextMismatch() {
        let original = """
        func greet() {
            print("hi")
        }
        """
        let patch = """
        --- a/hello.swift
        +++ b/hello.swift
        @@ -1,3 +1,3 @@
         func greet() {
        -    print("hello")
        +    print("hello, world")
         }
        """
        let parsed = UnifiedDiff.parse(patch)
        let result = UnifiedDiff.apply(filePatch: parsed[0], to: original)
        guard case .failure = result else {
            return XCTFail("Expected failure on context mismatch")
        }
    }
}
