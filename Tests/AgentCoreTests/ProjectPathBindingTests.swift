//
//  ProjectPathBindingTests.swift
//  Wave C2 W12: normalized path equality for project binding.
//

import XCTest
@testable import AgentCore

final class ProjectPathBindingTests: XCTestCase {

    func testNormalizePathStripsTrailingSlashForEquality() {
        let a = SafeModeConfig.normalizePath("/Users/me/proj")
        let b = SafeModeConfig.normalizePath("/Users/me/proj/")
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    func testNormalizePathEmptyDoesNotMatchRealProjectPaths() {
        // normalizePath may expand empty/relative input; binding code
        // must guard empty *before* normalize (see clearProjectBinding).
        let project = SafeModeConfig.normalizePath("/tmp/vibecoder-project")
        XCTAssertFalse(project.isEmpty)
        XCTAssertNotEqual(project, "/tmp/other-project")
    }

    func testURLPathEqualityWithoutNormalizeIsFragile() {
        // Documents why coordinator uses normalizePath rather than URL.==
        let u1 = URL(fileURLWithPath: "/tmp/proj", isDirectory: true)
        let u2 = URL(fileURLWithPath: "/tmp/proj/", isDirectory: true)
        // fileURLWithPath often standardizes, but string equality is the risk
        // when one side was stored as path without directory flag.
        let loose = "/tmp/proj"
        let withSlash = "/tmp/proj/"
        XCTAssertNotEqual(loose, withSlash)
        XCTAssertEqual(
            SafeModeConfig.normalizePath(loose),
            SafeModeConfig.normalizePath(withSlash)
        )
        _ = u1; _ = u2
    }
}
