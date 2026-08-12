//
//  GrantManagerViewModelTests.swift
//
//  Phase C PC1 — grant list formatting + revoke against RememberedGrants.
//

import XCTest
@testable import VibeCoderApp
@testable import AgentCore

@MainActor
final class GrantManagerViewModelTests: XCTestCase {

    override func setUp() async throws {
        await RememberedGrants.shared.clear()
    }

    override func tearDown() async throws {
        await RememberedGrants.shared.clear()
    }

    func testFormattingItemsSortedAndLabels() {
        let project = "/Users/me/Code/Demo"
        let entries: [GrantKey: GrantDecision] = [
            GrantKey(projectKey: project, toolName: "run_shell",
                     commandFingerprint: "npm install"): .allow,
            GrantKey(projectKey: project, toolName: "write_file"): .never,
            GrantKey(projectKey: project, toolName: RememberedGrants.pathGrantToolName,
                     commandFingerprint: "dir:/tmp/sandbox"): .allow,
        ]
        let items = GrantManagerFormatting.items(from: entries)
        XCTAssertEqual(items.count, 3)
        // Sorted by tool name among same project
        let tools = items.map(\.toolName)
        XCTAssertEqual(tools, [
            RememberedGrants.pathGrantToolName,
            "run_shell",
            "write_file",
        ])
        let shell = items.first { $0.toolName == "run_shell" }!
        XCTAssertEqual(shell.decisionLabel, "Always allow")
        XCTAssertTrue(shell.subtitle.contains("npm install"))
        XCTAssertTrue(shell.subtitle.contains("Demo"))
        let path = items.first { $0.toolName == RememberedGrants.pathGrantToolName }!
        XCTAssertEqual(path.title, "Path / folder access")
        XCTAssertTrue(path.subtitle.contains("folder:"))
    }

    func testRulesSummaryEmptyAndNonEmpty() {
        let empty = GrantManagerFormatting.rulesSummary(snapshot: .empty)
        XCTAssertTrue(empty.lowercased().contains("no permission"))

        let snap = PermissionRulesSnapshot(
            rules: [
                AuthorizationRule(kind: .deny, toolName: "run_shell", commandContains: "rm"),
            ],
            grants: [
                GrantKey(projectKey: "/p", toolName: "edit_file"): .allow,
            ],
            sourcePaths: ["/p/.vibecoder/permissions.json"]
        )
        let text = GrantManagerFormatting.rulesSummary(snapshot: snap)
        XCTAssertTrue(text.contains("1 file"))
        XCTAssertTrue(text.contains("1 rule"))
        XCTAssertTrue(text.contains("1 file-seeded grant"))
    }

    func testRemovingKey() {
        let k1 = GrantKey(projectKey: "/a", toolName: "edit_file")
        let k2 = GrantKey(projectKey: "/a", toolName: "run_shell")
        let map: [GrantKey: GrantDecision] = [k1: .allow, k2: .never]
        let out = GrantManagerFormatting.removing(k1, from: map)
        XCTAssertNil(out[k1])
        XCTAssertEqual(out[k2], .never)
    }

    func testViewModelReloadAndRevoke() async throws {
        let project = "/tmp/pc1-grant-test-\(UUID().uuidString)"
        let key = GrantKey(projectKey: project, toolName: "run_shell",
                           commandFingerprint: "git status")
        await RememberedGrants.shared.remember(.allow, for: key)
        let other = GrantKey(projectKey: project, toolName: "write_file")
        await RememberedGrants.shared.remember(.never, for: other)

        let vm = GrantManagerViewModel(projectRoot: URL(fileURLWithPath: project))
        await vm.reload()
        XCTAssertEqual(vm.items.count, 2)

        let shellItem = try XCTUnwrap(vm.items.first { $0.toolName == "run_shell" })
        await vm.revoke(shellItem)
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(vm.items[0].toolName, "write_file")
        XCTAssertEqual(vm.items[0].decision, .never)

        let remaining = await RememberedGrants.shared.decision(for: key)
        XCTAssertNil(remaining)
        let still = await RememberedGrants.shared.decision(for: other)
        XCTAssertEqual(still, .never)
        // Single-key forget must not have wiped the sibling via clear+reseed.
        let leftCount = await RememberedGrants.shared.allEntries().count
        XCTAssertEqual(leftCount, 1, "revoke uses forget, not clear-all")
    }

    func testViewModelClearProject() async {
        let p1 = "/tmp/pc1-a-\(UUID().uuidString)"
        let p2 = "/tmp/pc1-b-\(UUID().uuidString)"
        await RememberedGrants.shared.remember(
            .allow, for: GrantKey(projectKey: p1, toolName: "edit_file"))
        await RememberedGrants.shared.remember(
            .never, for: GrantKey(projectKey: p2, toolName: "delete_file"))

        let vm = GrantManagerViewModel()
        await vm.reload()
        XCTAssertGreaterThanOrEqual(vm.items.count, 2)

        await vm.clearProject(p1)
        let left = await RememberedGrants.shared.allEntries()
        XCTAssertNil(left[GrantKey(projectKey: p1, toolName: "edit_file")])
        XCTAssertEqual(left[GrantKey(projectKey: p2, toolName: "delete_file")], .never)
    }
}
