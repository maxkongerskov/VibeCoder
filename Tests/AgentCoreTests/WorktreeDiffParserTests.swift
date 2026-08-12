//
//  WorktreeDiffParserTests.swift
//

import XCTest
@testable import AgentCore

final class WorktreeDiffParserTests: XCTestCase {

    func testParseStatusNumstatAndUnified() {
        let status = """
         M Sources/Foo.swift
        A  Sources/New.swift
         D Sources/Old.swift
        """
        let numstat = """
        12\t3\tSources/Foo.swift
        5\t0\tSources/New.swift
        0\t8\tSources/Old.swift
        """
        let unified = """
        diff --git a/Sources/Foo.swift b/Sources/Foo.swift
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -1,3 +1,4 @@
         line one
        -old
        +new
         line three
        """

        let files = WorktreeDiffParser.parse(
            statusShort: status,
            numstat: numstat,
            unified: unified
        )
        XCTAssertEqual(files.count, 3)

        let foo = files.first { $0.path == "Sources/Foo.swift" }
        XCTAssertEqual(foo?.kind, .modified)
        XCTAssertEqual(foo?.linesAdded, 12)
        XCTAssertEqual(foo?.linesRemoved, 3)
        XCTAssertTrue(foo?.diffLines.contains { $0.kind == .added && $0.text == "new" } ?? false)
        XCTAssertTrue(foo?.diffLines.contains { $0.kind == .removed && $0.text == "old" } ?? false)

        let neu = files.first { $0.path == "Sources/New.swift" }
        XCTAssertEqual(neu?.kind, .added)
        XCTAssertEqual(neu?.linesAdded, 5)

        let old = files.first { $0.path == "Sources/Old.swift" }
        XCTAssertEqual(old?.kind, .deleted)
        XCTAssertEqual(old?.linesRemoved, 8)
    }

    func testEmptyInputsYieldEmpty() {
        XCTAssertTrue(WorktreeDiffParser.parse(statusShort: "", numstat: "", unified: "").isEmpty)
    }
}
