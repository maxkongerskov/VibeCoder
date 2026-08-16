//
//  TenSliceRegressionTests.swift
//  Consensus follow-ups: OAuth buffer, disabled tools on task, swift package RO.
//

import XCTest
@testable import AgentCore

final class TenSliceRegressionTests: XCTestCase {

    func testSwiftPackageMutatingSubsAreNotReadOnly() {
        XCTAssertTrue(SafeBash.isReadOnlyCommand("swift package describe"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("swift package update"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("swift package add-dependency x"))
    }

    func testToolContextCarriesDisabledToolNames() {
        let ctx = ToolContext(
            projectRoot: nil,
            conversationID: UUID(),
            disabledToolNames: ["run_shell", "delete_file"])
        XCTAssertTrue(ctx.disabledToolNames.contains("run_shell"))
        XCTAssertEqual(ctx.disabledToolNames.subtracting(["run_shell", "delete_file"]).count, 0)
    }

    func testDisabledNamesSubtractFromTaskAllowList() {
        let parentDisabled: Set<String> = ["run_shell", "delete_file"]
        let allowed: Set<String> = ["read_file", "run_shell", "grep_code"]
        let child = allowed.subtracting(parentDisabled)
        XCTAssertFalse(child.contains("run_shell"))
        XCTAssertTrue(child.contains("read_file"))
    }

    func testOAuthWaitConsumesCallbackThatArrivedFirst() async throws {
        let server = MCPCallbackServer()
        let redirect = try server.start(preferredPort: 0)
        defer { server.stop() }
        guard let url = URL(string: redirect + "?code=abc&state=xyz") else {
            return XCTFail("bad redirect \(redirect)")
        }
        // Hit /callback before waitForCallback (cached-consent race).
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        _ = try? await URLSession.shared.data(for: req)
        let cb = try await server.waitForCallback(timeout: 3)
        XCTAssertEqual(cb.code, "abc")
        XCTAssertEqual(cb.state, "xyz")
    }
}
