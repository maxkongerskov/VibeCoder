//
//  BuildVerifyNoticeTests.swift
//  S5 — Auto-verify transcript notice copy + kinds.
//

import XCTest
@testable import VibeCoderApp

@MainActor
final class BuildVerifyNoticeTests: XCTestCase {

    func testPassedNotice() {
        let n = ChatViewModel.makeBuildVerifyNotice(succeeded: true, detail: nil)
        XCTAssertEqual(n.kind, .buildVerify)
        XCTAssertTrue(n.title.localizedCaseInsensitiveContains("passed"))
        XCTAssertTrue(n.detail.localizedCaseInsensitiveContains("BuildGuard"))
    }

    func testFailedNoticeIncludesLog() {
        let n = ChatViewModel.makeBuildVerifyNotice(
            succeeded: false,
            detail: "error: cannot find type 'Foo' in scope"
        )
        XCTAssertEqual(n.kind, .buildVerify)
        XCTAssertTrue(n.title.localizedCaseInsensitiveContains("failed"))
        XCTAssertTrue(n.detail.contains("Foo"))
    }

    func testSkippedNoticeIsHonest() {
        let n = ChatViewModel.makeBuildVerifyNotice(
            skipped: true,
            detail: "No Package.swift"
        )
        XCTAssertEqual(n.kind, .buildVerify)
        XCTAssertTrue(n.title.localizedCaseInsensitiveContains("skipped"))
        XCTAssertTrue(n.detail.contains("Package.swift"))
    }
}
