//
//  CLIApprovalsTests.swift
//  C3: TTY `always` is durable (same as in-app Always). Empty / n deny.
//  No live TTY — scripted line reader.
//

import XCTest
import AgentCore
@testable import VibeCoderCLILib

final class CLIApprovalsTests: XCTestCase {

    func testParseShellYIsOnce() {
        XCTAssertEqual(TTYApprovals.parseShellDecision("y"), .once)
        XCTAssertEqual(TTYApprovals.parseShellDecision("YES"), .once)
    }

    func testParseShellAlways() {
        XCTAssertEqual(TTYApprovals.parseShellDecision("always"), .always)
        XCTAssertEqual(TTYApprovals.parseShellDecision(" Always "), .always)
    }

    func testParseShellEmptyAndNDeny() {
        XCTAssertEqual(TTYApprovals.parseShellDecision(nil), .deny)
        XCTAssertEqual(TTYApprovals.parseShellDecision(""), .deny)
        XCTAssertEqual(TTYApprovals.parseShellDecision("   "), .deny)
        XCTAssertEqual(TTYApprovals.parseShellDecision("n"), .deny)
        XCTAssertEqual(TTYApprovals.parseShellDecision("no"), .deny)
        XCTAssertEqual(TTYApprovals.parseShellDecision("garbage"), .deny)
    }

    func testParsePatchFailClosed() {
        XCTAssertEqual(TTYApprovals.parsePatchChoice("y"), .acceptOnce)
        XCTAssertEqual(TTYApprovals.parsePatchChoice("always"), .always)
        XCTAssertEqual(TTYApprovals.parsePatchChoice(""), .reject)
        XCTAssertEqual(TTYApprovals.parsePatchChoice("n"), .reject)
        XCTAssertEqual(TTYApprovals.parsePatchChoice(nil), .reject)
        XCTAssertEqual(TTYApprovals.parsePatchChoice("maybe"), .reject)
    }

    func testScriptedAlwaysDoesNotNeedTTY() async {
        let reviewer = TTYApprovals.shellReviewer(readLine: { "always" })
        let decision = await reviewer.review(
            ShellApprovalRequest(toolName: "run_shell", reason: "test", command: "ls")
        )
        XCTAssertEqual(decision, .always)
    }

    func testScriptedEmptyDenies() async {
        let reviewer = TTYApprovals.shellReviewer(readLine: { "" })
        let decision = await reviewer.review(
            ShellApprovalRequest(toolName: "run_shell", reason: "test", command: "ls")
        )
        XCTAssertEqual(decision, .deny)
    }

    func testAlwaysPersistsDurableGrant() async throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("c3-grant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let projectKey = project.path
        await RememberedGrants.shared.clear(projectKey: projectKey)

        let coordinator = TTYApprovals.shellReviewer(readLine: { "always" })
        let context = ToolContext(
            projectRoot: project,
            shellApprovalCoordinator: coordinator,
            conversationID: UUID()
        )
        try await ShellApproval.resolveAsk(
            toolName: "run_shell",
            arguments: ToolArguments(dictionary: ["command": "ls"]),
            reason: "list",
            context: context
        )
        let key = ShellApproval.grantKey(
            toolName: "run_shell",
            arguments: ToolArguments(dictionary: ["command": "ls"]),
            context: context
        )
        let process = await RememberedGrants.shared.decision(for: key)
        XCTAssertEqual(process, .allow, "Always must land in process grants")
        let durable = await DurableGrantStore.shared.decision(for: key)
        XCTAssertEqual(durable, .allow, "Always must persist to DurableGrantStore")
        await RememberedGrants.shared.clear(projectKey: projectKey)
    }

    func testOnceDoesNotPersistGrant() async throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("c3-once-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let projectKey = project.path
        await RememberedGrants.shared.clear(projectKey: projectKey)

        let coordinator = TTYApprovals.shellReviewer(readLine: { "y" })
        let context = ToolContext(
            projectRoot: project,
            shellApprovalCoordinator: coordinator,
            conversationID: UUID()
        )
        try await ShellApproval.resolveAsk(
            toolName: "run_shell",
            arguments: ToolArguments(dictionary: ["command": "ls"]),
            reason: "list",
            context: context
        )
        let key = ShellApproval.grantKey(
            toolName: "run_shell",
            arguments: ToolArguments(dictionary: ["command": "ls"]),
            context: context
        )
        let process = await RememberedGrants.shared.decision(for: key)
        XCTAssertNil(process, "y/once must not write Always grants")
        await RememberedGrants.shared.clear(projectKey: projectKey)
    }

    func testPatchAlwaysPersistsDirectoryGrant() async throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("c3-patch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let projectKey = project.path
        await RememberedGrants.shared.clear(projectKey: projectKey)

        let file = project.appendingPathComponent("a.swift")
        try "ok".write(to: file, atomically: true, encoding: .utf8)
        let preview = PatchPreview(
            path: file.path,
            originalContent: "ok",
            updatedContent: "ok2",
            hunks: []
        )
        let reviewer = TTYApprovals.patchReviewer(
            projectKey: projectKey,
            readLine: { "always" }
        )
        let decision = await reviewer.review([preview])
        XCTAssertEqual(decision, .acceptAll)

        let grants = await RememberedGrants.shared.snapshot(projectKey: projectKey)
        XCTAssertTrue(
            RememberedGrants.allowsPath(
                file,
                toolName: "write_file",
                projectKey: projectKey,
                grants: grants
            ),
            "patch always must persist a directory grant covering the file"
        )
        await RememberedGrants.shared.clear(projectKey: projectKey)
    }

    func testPatchEmptyRejectsAndDoesNotGrant() async throws {
        let projectKey = "/tmp/c3-patch-deny-\(UUID().uuidString)"
        await RememberedGrants.shared.clear(projectKey: projectKey)

        let preview = PatchPreview(
            path: "/tmp/x.swift",
            originalContent: "",
            updatedContent: "x",
            hunks: []
        )
        let reviewer = TTYApprovals.patchReviewer(
            projectKey: projectKey,
            readLine: { "" }
        )
        let decision = await reviewer.review([preview])
        XCTAssertEqual(decision, .rejectAll)
        let grants = await RememberedGrants.shared.snapshot(projectKey: projectKey)
        XCTAssertTrue(grants.isEmpty, "empty/n must not persist Always")
        await RememberedGrants.shared.clear(projectKey: projectKey)
    }
}
