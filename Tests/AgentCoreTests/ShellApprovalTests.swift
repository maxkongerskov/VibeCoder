//
//  ShellApprovalTests.swift
//
//  Wave B S4 — resolveAsk Once/Always/Never + fail-closed without reviewer.
//

import XCTest
@testable import AgentCore

final class ShellApprovalTests: XCTestCase {

    private func tempProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-approval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testResolveAskWithoutReviewerFailsClosed() async throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = ToolContext(projectRoot: root, conversationID: UUID())
        let args = ToolArguments(dictionary: ["command": "npm install"])
        do {
            try await ShellApproval.resolveAsk(
                toolName: "run_shell",
                arguments: args,
                reason: "Ask mode requires approval",
                context: ctx)
            XCTFail("expected permissionDenied")
        } catch let error as ToolError {
            if case .permissionDenied = error {
                // ok
            } else {
                XCTFail("wrong error \(error)")
            }
        }
    }

    func testOnceAllowsWithoutGrant() async throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        await RememberedGrants.shared.clear()

        let reviewer = ShellApprovalReviewer { _ in .once }
        let ctx = ToolContext(
            projectRoot: root,
            shellApprovalCoordinator: reviewer,
            conversationID: UUID()
        )
        let args = ToolArguments(dictionary: ["command": "npm install lodash"])
        try await ShellApproval.resolveAsk(
            toolName: "run_shell",
            arguments: args,
            reason: "approval required",
            context: ctx)

        let key = ShellApproval.grantKey(
            toolName: "run_shell",
            arguments: args,
            context: ctx)
        let snap = await RememberedGrants.shared.snapshot(projectKey: key.projectKey)
        XCTAssertNil(snap[key], "Once must not write a grant")
    }

    func testAlwaysWritesAllowGrant() async throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        await RememberedGrants.shared.clear()

        let reviewer = ShellApprovalReviewer { _ in .always }
        let ctx = ToolContext(
            projectRoot: root,
            shellApprovalCoordinator: reviewer,
            conversationID: UUID()
        )
        let args = ToolArguments(dictionary: ["command": "swift test"])
        try await ShellApproval.resolveAsk(
            toolName: "run_shell",
            arguments: args,
            reason: "approval required",
            context: ctx)

        let key = ShellApproval.grantKey(
            toolName: "run_shell",
            arguments: args,
            context: ctx)
        let decision = await RememberedGrants.shared.decision(for: key)
        XCTAssertEqual(decision, .allow)
    }

    func testNeverWritesNeverGrantAndThrows() async throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        await RememberedGrants.shared.clear()

        let reviewer = ShellApprovalReviewer { _ in .never }
        let ctx = ToolContext(
            projectRoot: root,
            shellApprovalCoordinator: reviewer,
            conversationID: UUID()
        )
        let args = ToolArguments(dictionary: ["command": "curl evil.example"])
        do {
            try await ShellApproval.resolveAsk(
                toolName: "run_shell",
                arguments: args,
                reason: "approval required",
                context: ctx)
            XCTFail("expected deny")
        } catch is ToolError {
            // expected
        }

        let key = ShellApproval.grantKey(
            toolName: "run_shell",
            arguments: args,
            context: ctx)
        let decision = await RememberedGrants.shared.decision(for: key)
        XCTAssertEqual(decision, .never)
    }

    func testAlwaysOnDangerousDoesNotPersist() async throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        await RememberedGrants.shared.clear()

        let reviewer = ShellApprovalReviewer { _ in .always }
        let ctx = ToolContext(
            projectRoot: root,
            shellApprovalCoordinator: reviewer,
            conversationID: UUID()
        )
        // Substring that SafeBash treats as dangerous (rm -rf pattern).
        let args = ToolArguments(dictionary: ["command": "rm -rf /tmp/scratch"])
        try await ShellApproval.resolveAsk(
            toolName: "run_shell",
            arguments: args,
            reason: "dangerous",
            context: ctx)

        let key = ShellApproval.grantKey(
            toolName: "run_shell",
            arguments: args,
            context: ctx)
        let decision = await RememberedGrants.shared.decision(for: key)
        XCTAssertNil(decision, "dangerous Always must not persist")
    }

    func testGateKindClassifiesTools() {
        XCTAssertEqual(ShellApprovalGate.kind(for: "run_shell"), .shell)
        XCTAssertEqual(ShellApprovalGate.kind(for: "github__create_issue"), .mcp)
        XCTAssertEqual(ShellApprovalGate.kind(for: "task"), .executes)
    }
}
