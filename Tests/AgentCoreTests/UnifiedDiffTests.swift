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

    func testReviewPreviewBuildsUnifiedFromHunks() {
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
        let preview = UnifiedDiff.reviewPreview(filePatch: parsed[0])
        XCTAssertTrue(preview.hasPrefix("--- a/hello.swift\n+++ b/hello.swift\n@@ -1,3 +1,3 @@\n"))
        XCTAssertTrue(preview.contains("-    print(\"hello\")"))
        XCTAssertTrue(preview.contains("+    print(\"hello, world\")"))
        let again = UnifiedDiff.parse(preview)
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again[0].path, "hello.swift")
        XCTAssertEqual(again[0].hunks.count, 1)
        XCTAssertEqual(again[0].hunks[0].oldStart, 1)
        XCTAssertEqual(again[0].hunks[0].newLen, 3)
    }

    func testReviewPreviewTruncatesHugeDiff() {
        let hunk = UnifiedDiff.Hunk(
            oldStart: 1,
            oldLen: 50,
            newStart: 1,
            newLen: 50,
            lines: (0..<50).map { UnifiedDiff.Line.context("line \($0)") }
        )
        let preview = UnifiedDiff.reviewPreview(
            path: "big.swift",
            hunks: [hunk],
            maxLines: 10
        )
        let lines = preview.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 11) // 10 kept + truncation notice
        XCTAssertTrue(preview.hasPrefix("--- a/big.swift"))
        XCTAssertTrue(preview.contains("+++ b/big.swift"))
        XCTAssertTrue(String(lines.last!).hasPrefix("Diff preview truncated:"))
        XCTAssertTrue(String(lines.last!).contains("43 lines omitted"))
        XCTAssertTrue(String(lines.last!).hasSuffix("…"))
    }

    func testReviewPreviewEmptyHunksStillHasHeaders() {
        let preview = UnifiedDiff.reviewPreview(path: "empty.swift", hunks: [])
        XCTAssertEqual(preview, "--- a/empty.swift\n+++ b/empty.swift")
    }

}
