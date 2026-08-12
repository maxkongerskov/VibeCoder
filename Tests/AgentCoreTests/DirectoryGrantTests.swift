//
//  DirectoryGrantTests.swift
//  Durable "Always allow this folder" grants skip re-prompts.
//

import XCTest
@testable import AgentCore

final class DirectoryGrantTests: XCTestCase {

    func testAllowsPathUnderDirectoryGrant() {
        let projectKey = "/Users/me/proj"
        let dir = URL(fileURLWithPath: "/Users/me/proj/src", isDirectory: true)
        let file = URL(fileURLWithPath: "/Users/me/proj/src/App/Foo.swift")
        let outside = URL(fileURLWithPath: "/Users/me/other/x.swift")

        let key = GrantKey(
            projectKey: projectKey,
            toolName: RememberedGrants.pathGrantToolName,
            commandFingerprint: PathConfinement.directoryGrantFingerprint(dir)
        )
        let grants: [GrantKey: GrantDecision] = [key: .allow]

        XCTAssertTrue(
            RememberedGrants.allowsPath(file, toolName: "write_file", projectKey: projectKey, grants: grants)
        )
        XCTAssertTrue(
            RememberedGrants.allowsPath(dir, toolName: "list_directory", projectKey: projectKey, grants: grants)
        )
        XCTAssertFalse(
            RememberedGrants.allowsPath(outside, toolName: "write_file", projectKey: projectKey, grants: grants)
        )
    }

    func testCommonDirectoryForSiblingFiles() {
        let a = URL(fileURLWithPath: "/tmp/ws/a/x.swift")
        let b = URL(fileURLWithPath: "/tmp/ws/a/y.swift")
        let common = PathConfinement.commonDirectory(for: [a, b])
        XCTAssertNotNil(common)
        let path = SafeModeConfig.normalizePath(common!.path)
        XCTAssertTrue(path.hasSuffix("/tmp/ws/a") || path == "/tmp/ws/a", path)
    }

    func testDirectoryFingerprintForFileUsesParent() {
        let file = URL(fileURLWithPath: "/tmp/ws/a/x.swift")
        let fp = PathConfinement.directoryGrantFingerprint(file)
        XCTAssertTrue(fp.hasPrefix("dir:"))
        XCTAssertTrue(fp.contains("/tmp/ws/a"), fp)
    }
}
