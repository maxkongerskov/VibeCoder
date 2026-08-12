//
//  BuildGuardVerifyEditsTests.swift
//  S5 — BuildGuard outcome + system reminder contract.
//

import XCTest
@testable import AgentCore

final class BuildGuardVerifyEditsTests: XCTestCase {

    func testVerifyNoBuildSystemInEmptyDir() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = await BuildGuard.verify(at: dir)
        if case .noBuildSystem = outcome {
            // expected
        } else {
            XCTFail("expected noBuildSystem, got \(outcome)")
        }
    }

    func testSystemReminderBuildGuardMarkers() {
        let ok = SystemReminder.buildGuard(succeeded: true)
        XCTAssertTrue(ok.contains("BuildGuard: build succeeded"))
        XCTAssertTrue(ok.contains("# System reminder — BuildGuard"))

        let fail = SystemReminder.buildGuard(succeeded: false, detail: "error: demo")
        XCTAssertTrue(fail.contains("BuildGuard: build failed"))
        XCTAssertTrue(fail.contains("error: demo"))
    }

    func testDefaultVerifyEditsIsOnInAppSettings() {
        let s = AppSettings()
        XCTAssertTrue(s.verifyEdits, "product default must keep auto-verify on")
    }

    func testAgentLoopConfigDefaultVerifyEdits() {
        let c = AgentLoop.Configuration()
        XCTAssertTrue(c.verifyEdits)
    }
}
