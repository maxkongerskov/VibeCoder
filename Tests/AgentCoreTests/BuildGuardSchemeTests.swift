//
//  BuildGuardSchemeTests.swift
//
//  Unit tests for BuildGuard.firstScheme(fromXcodebuildListJSON:preferring:),
//  the pure parser behind scheme autodetection. The old code passed a
//  literal "GENERIC" scheme to xcodebuild, which failed on every real
//  project — these tests pin the replacement behaviour.
//

import XCTest
@testable import AgentCore

final class BuildGuardSchemeTests: XCTestCase {

    func testPicksPreferredSchemeFromProjectList() {
        let json = """
        {"project":{"configurations":["Debug","Release"],
                    "name":"AgentOS",
                    "schemes":["AgentCLI","AgentOS","HelperTool"],
                    "targets":["AgentOS","AgentCLI"]}}
        """
        XCTAssertEqual(BuildGuard.firstScheme(fromXcodebuildListJSON: json, preferring: "AgentOS"),
                       "AgentOS")
    }

    func testFallsBackToFirstSchemeWhenPreferredAbsent() {
        let json = #"{"project":{"name":"Foo","schemes":["Alpha","Beta"]}}"#
        XCTAssertEqual(BuildGuard.firstScheme(fromXcodebuildListJSON: json, preferring: "Foo"),
                       "Alpha")
    }

    func testParsesWorkspaceShape() {
        let json = #"{"workspace":{"name":"Big","schemes":["App","Lib"]}}"#
        XCTAssertEqual(BuildGuard.firstScheme(fromXcodebuildListJSON: json, preferring: "App"),
                       "App")
    }

    func testNoSchemesReturnsNil() {
        XCTAssertNil(BuildGuard.firstScheme(fromXcodebuildListJSON: #"{"project":{"schemes":[]}}"#))
        XCTAssertNil(BuildGuard.firstScheme(fromXcodebuildListJSON: #"{"project":{}}"#))
    }

    func testGarbageInputReturnsNil() {
        XCTAssertNil(BuildGuard.firstScheme(fromXcodebuildListJSON: "xcodebuild: error: ..."))
        XCTAssertNil(BuildGuard.firstScheme(fromXcodebuildListJSON: ""))
    }
}
