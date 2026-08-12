//
//  PermissionRulesTests.swift
//
//  PA6: project/user permissions.json + always-allow grants + Auto≠Full shell.
//

import XCTest
@testable import AgentCore

final class PermissionRulesTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await RememberedGrants.shared.clear()
    }

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pa6-perm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePermissions(_ json: String, under root: URL, relative: String = ".vibecoder/permissions.json") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    private func ctx(
        root: URL,
        mode: ExecutionMode = .yolo,
        auth: AuthorizationConfig = .empty
    ) -> ToolContext {
        ToolContext(
            projectRoot: root,
            conversationID: UUID(),
            executionMode: mode,
            authorization: auth
        )
    }

    // MARK: - Parse

    func testParseDenyRuleAndAlwaysAllow() {
        let json = """
        {
          "version": 1,
          "rules": [
            { "kind": "deny", "tool": "run_shell", "commandContains": "rm -rf" }
          ],
          "alwaysAllow": [
            { "tool": "edit_file" }
          ]
        }
        """
        let snap = PermissionRules.parsePermissionsJSON(string: json, projectKey: "/tmp/proj")
        XCTAssertEqual(snap.rules.count, 1)
        XCTAssertEqual(snap.rules[0].kind, .deny)
        XCTAssertEqual(snap.rules[0].toolName, "run_shell")
        XCTAssertEqual(snap.rules[0].commandContains, "rm -rf")

        let editKey = GrantKey(projectKey: "/tmp/proj", toolName: "edit_file")
        XCTAssertEqual(snap.grants[editKey], .allow)
    }

    func testParseClaudeStyleBashEntry() {
        let rules = PermissionRules.rulesFromClaudeStyleEntry(
            "Bash(git status)", kind: .deny)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].toolName, "run_shell")
        XCTAssertEqual(rules[0].commandContains, "git status")
        XCTAssertEqual(PermissionRules.mapClaudeToolName("Read"), "read_file")
        XCTAssertEqual(PermissionRules.mapClaudeToolName("Write"), "write_file")
    }

    func testParseClaudeSettingsSubset() throws {
        let data = """
        {
          "permissions": {
            "deny": ["Bash(curl)", "Write"],
            "allow": ["Read"],
            "ask": ["Edit"]
          }
        }
        """.data(using: .utf8)!
        let snap = PermissionRules.parseClaudeSettings(data: data, projectKey: "/p")
        XCTAssertTrue(snap.rules.contains { $0.kind == .deny && $0.toolName == "run_shell" })
        XCTAssertTrue(snap.rules.contains { $0.kind == .deny && $0.toolName == "write_file" })
        XCTAssertTrue(snap.rules.contains { $0.kind == .ask && $0.toolName == "edit_file" })
        XCTAssertEqual(snap.grants[GrantKey(projectKey: "/p", toolName: "read_file")], .allow)
    }

    // MARK: - File load + evaluate

    func testMissingFileYieldsEmptyRules() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let snap = PermissionRules.load(
            projectRoot: root, includeHome: false, includeClaudeSettings: false)
        XCTAssertTrue(snap.isEmpty)
    }

    func testFileDenyBlocksRunShellEvenInYolo() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePermissions("""
        {
          "rules": [
            { "kind": "deny", "tool": "run_shell", "commandContains": "forbidden-token-xyz" }
          ]
        }
        """, under: root)

        let snap = PermissionRules.load(
            projectRoot: root, includeHome: false, includeClaudeSettings: false,
            projectKey: root.path)
        XCTAssertFalse(snap.rules.isEmpty, "expected rules from file")

        let auth = PermissionRules.merge(into: .empty, snapshot: snap)
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: [
                "command": "echo forbidden-token-xyz should die"
            ]),
            context: ctx(root: root, mode: .yolo, auth: auth),
            config: auth,
            remembered: [:]
        )
        guard case .deny(let reason) = outcome else {
            return XCTFail("expected deny, got \(outcome)")
        }
        XCTAssertTrue(reason.lowercased().contains("denied") || reason.lowercased().contains("rule"),
                      reason)
    }

    func testAlwaysAllowToolSkipsAskModeForEditFile() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePermissions("""
        {
          "alwaysAllow": [ { "tool": "edit_file" } ]
        }
        """, under: root)

        let snap = PermissionRules.load(
            projectRoot: root, includeHome: false, includeClaudeSettings: false,
            projectKey: root.path)
        let auth = PermissionRules.merge(into: .empty, snapshot: snap)

        // Ask mode (.build) normally asks for mutates without reviewer.
        // alwaysAllow grant should promote to allow (still subject to plan/confinement).
        let path = root.appendingPathComponent("f.swift").path
        let outcome = ToolAuthorization.evaluate(
            toolName: "edit_file",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "path": path,
                "old_string": "a",
                "new_string": "b",
            ]),
            context: ctx(root: root, mode: .build, auth: auth),
            config: auth,
            remembered: snap.grants
        )
        guard case .allow = outcome else {
            return XCTFail("alwaysAllow edit_file should allow in Ask mode, got \(outcome)")
        }
    }

    func testAlwaysDenyNeverGrant() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePermissions("""
        {
          "alwaysDeny": [ { "tool": "delete_file" } ]
        }
        """, under: root)

        let snap = PermissionRules.load(
            projectRoot: root, includeHome: false, includeClaudeSettings: false,
            projectKey: root.path)
        let auth = PermissionRules.merge(into: .empty, snapshot: snap)
        let outcome = ToolAuthorization.evaluate(
            toolName: "delete_file",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "path": root.appendingPathComponent("x.txt").path
            ]),
            context: ctx(root: root, mode: .yolo, auth: auth),
            config: auth,
            remembered: snap.grants
        )
        guard case .deny = outcome else {
            return XCTFail("alwaysDeny must deny, got \(outcome)")
        }
    }

    func testAlwaysAllowShellFingerprint() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cmd = "npm test -- --runInBand"
        try writePermissions("""
        {
          "alwaysAllow": [
            { "tool": "run_shell", "commandPrefix": "\(cmd)" }
          ]
        }
        """, under: root)

        let snap = PermissionRules.load(
            projectRoot: root, includeHome: false, includeClaudeSettings: false,
            projectKey: root.path)
        let fp = RememberedGrants.fingerprint(command: cmd)
        let key = GrantKey(projectKey: root.path, toolName: "run_shell", commandFingerprint: fp)
        XCTAssertEqual(snap.grants[key], .allow, "grants=\(snap.grants)")

        // Auto mode (.edit) would ask for shell; alwaysAllow grant should allow.
        let auth = PermissionRules.merge(into: .empty, snapshot: snap)
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: ["command": cmd]),
            context: ctx(root: root, mode: .edit, auth: auth),
            config: auth,
            remembered: snap.grants
        )
        guard case .allow = outcome else {
            return XCTFail("alwaysAllow shell fingerprint should allow in Auto, got \(outcome)")
        }
    }

    // MARK: - Auto ≠ Full

    func testEditModeAsksForMutatingShell() {
        let root = FileManager.default.temporaryDirectory
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: ["command": "npm install left-pad"]),
            context: ctx(root: root, mode: .edit),
            config: .empty,
            remembered: [:]
        )
        guard case .ask(let reason) = outcome else {
            return XCTFail("Auto mode must ask for npm install, got \(outcome)")
        }
        XCTAssertTrue(reason.lowercased().contains("auto") || reason.lowercased().contains("approval"),
                      reason)
    }

    func testYoloModeAllowsMutatingShell() {
        let root = FileManager.default.temporaryDirectory
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: ["command": "npm install left-pad"]),
            context: ctx(root: root, mode: .yolo),
            config: .empty,
            remembered: [:]
        )
        guard case .allow = outcome else {
            return XCTFail("Full mode should allow non-dangerous shell, got \(outcome)")
        }
    }

    func testEditModeAllowsSafeBashRO() {
        let root = FileManager.default.temporaryDirectory
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: ["command": "echo hello-auto"]),
            context: ctx(root: root, mode: .edit),
            config: .empty,
            remembered: [:]
        )
        guard case .allow = outcome else {
            return XCTFail("Auto must still allow SafeBash RO, got \(outcome)")
        }
    }

    func testEditModeAllowsWriteFile() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pa6-write-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = ToolAuthorization.evaluate(
            toolName: "write_file",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "path": root.appendingPathComponent("a.txt").path,
                "content": "x",
            ]),
            context: ctx(root: root, mode: .edit),
            config: .empty,
            remembered: [:]
        )
        guard case .allow = outcome else {
            return XCTFail("Auto must allow file mutates, got \(outcome)")
        }
    }

    func testMergePrefersRuntimeRememberedOverFileAlwaysAllow() {
        let projectKey = "/tmp/merge-test"
        let fileSnap = PermissionRules.parsePermissionsJSON(string: """
        { "alwaysAllow": [ { "tool": "delete_file" } ] }
        """, projectKey: projectKey)
        let key = GrantKey(projectKey: projectKey, toolName: "delete_file")
        XCTAssertEqual(fileSnap.grants[key], .allow)

        var config = AuthorizationConfig(
            remembered: [key: .never],
            useInlineRememberedOnly: true
        )
        config = PermissionRules.merge(into: config, snapshot: fileSnap)
        XCTAssertEqual(config.remembered[key], .never,
                       "UI Always/Never must outrank static file alwaysAllow")
    }

    func testDurableRememberStillWorksAlongsideRules() async {
        let root = try! makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = GrantKey(projectKey: root.path, toolName: "write_file")
        await RememberedGrants.shared.remember(.allow, for: key)
        let decision = await RememberedGrants.shared.decision(for: key)
        XCTAssertEqual(decision, .allow)
        await RememberedGrants.shared.clear(projectKey: root.path)
    }
}
