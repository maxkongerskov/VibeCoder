//
//  ProjectHookExecutionTests.swift
//
//  Default policy: project-file hooks under
//  <project>/.vibecoder/hooks/ and .grok/hooks/ are ignored.
//  User-scope ~/.vibecoder and ~/.grok hooks still execute.
//

import XCTest
@testable import AgentCore

final class ProjectHookExecutionTests: XCTestCase {

    private var home: URL!
    private var root: URL!
    private var projectHooks: URL!
    private var userHooks: URL!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-home-\(UUID().uuidString)", isDirectory: true)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proj-hooks-\(UUID().uuidString)", isDirectory: true)
        projectHooks = root.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        userHooks = home.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: projectHooks, withIntermediateDirectories: true)
        HookDispatcher.setHooksHomeDirectoryOverride(home)
        HookDispatcher.allowProjectFileHooks = false
        await ToolRegistry.shared.registerBuiltins()
    }

    override func tearDown() {
        HookDispatcher.setAllowProjectFileHooksOverride(nil)
        HookDispatcher.setProcessEnvironmentOverride(nil)
        HookDispatcher.setHooksHomeDirectoryOverride(nil)
        if let root { try? FileManager.default.removeItem(at: root) }
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func context() -> ToolContext {
        ToolContext(
            projectRoot: root,
            conversationID: UUID(),
            executionMode: .yolo
        )
    }

    private func writeJSON(_ object: [String: Any], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent("hooks.json"))
    }

    private func writeExecutable(_ name: String, in directory: URL, body: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Project hooks ignored

    func testProjectVibecoderPreToolCommandDoesNotRun() throws {
        let marker = projectHooks.appendingPathComponent("ran.txt")
        try writeExecutable("mark-and-deny.sh", in: projectHooks, body: """
        #!/bin/sh
        echo ran > "\(marker.path)"
        exit 2
        """)
        try writeJSON([
            "pre": [
                ["matcher": "run_shell", "type": "command", "command": "mark-and-deny.sh"]
            ]
        ], to: projectHooks)

        XCTAssertNil(
            HookDispatcher.hooksDir(projectRoot: root),
            "runtime must not select the project hooks dir")
        XCTAssertEqual(
            HookDispatcher.projectHooksDir(projectRoot: root)?.path,
            projectHooks.path)

        let decision = HookDispatcher.preTool(
            toolName: "run_shell",
            argumentsSummary: "ls",
            projectRoot: root)
        XCTAssertTrue(decision.allow, decision.message ?? "")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "project hook command must not execute")
    }

    func testProjectGrokHooksDirectoryCommandsDoNotRun() throws {
        try FileManager.default.removeItem(at: projectHooks)
        let grok = root.appendingPathComponent(".grok/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        let marker = grok.appendingPathComponent("grok-ran.txt")
        try writeExecutable("mark.sh", in: grok, body: """
        #!/bin/sh
        echo grok > "\(marker.path)"
        exit 2
        """)
        try writeJSON([
            "pre": [
                ["matcher": "*", "type": "command", "command": "mark.sh"]
            ]
        ], to: grok)

        let decision = HookDispatcher.preTool(
            toolName: "read_file",
            argumentsSummary: "x",
            projectRoot: root)
        XCTAssertTrue(decision.allow, decision.message ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testWorktreeProjectHooksAreIgnored() throws {
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-hooks-\(UUID().uuidString)", isDirectory: true)
        let wtHooks = worktree.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        let marker = wtHooks.appendingPathComponent("wt.txt")
        try writeExecutable("wt.sh", in: wtHooks, body: """
        #!/bin/sh
        echo wt > "\(marker.path)"
        exit 2
        """)
        try writeJSON([
            "pre": [["matcher": "*", "type": "command", "command": "wt.sh"]]
        ], to: wtHooks)

        let decision = HookDispatcher.preTool(
            toolName: "run_shell",
            argumentsSummary: "ls",
            projectRoot: root,
            worktreeRoot: worktree)
        XCTAssertTrue(decision.allow, decision.message ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testToolRegistryExecuteDoesNotRunProjectPreHook() async throws {
        let marker = projectHooks.appendingPathComponent("registry-ran.txt")
        try writeExecutable("deny-grep.sh", in: projectHooks, body: """
        #!/bin/sh
        echo registry > "\(marker.path)"
        exit 2
        """)
        try writeJSON([
            "pre": [
                ["matcher": "grep_code", "type": "command", "command": "deny-grep.sh"]
            ]
        ], to: projectHooks)

        let result = try await ToolRegistry.shared.execute(
            name: "grep_code",
            arguments: ToolArguments(dictionary: [
                "pattern": "foo",
                "path": root.path,
            ]),
            context: context())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "ToolRegistry.execute must not run project PreToolUse")
        XCTAssertFalse(
            result.content.lowercased().contains("denied by hook"),
            result.content)
    }

    /// Model can still write project hooks.json; default policy does not run them.
    func testWriteFileInstallDoesNotExecuteProjectHook() async throws {
        let marker = root.appendingPathComponent("pwned-marker.txt")
        let command = "/bin/sh -c 'echo pwned > \"\(marker.path)\"; exit 2'"
        let config: [String: Any] = [
            "pre": [
                ["matcher": "grep_code", "type": "command", "command": command]
            ]
        ]
        let json = String(
            data: try JSONSerialization.data(withJSONObject: config),
            encoding: .utf8)!

        let written = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": ".vibecoder/hooks/hooks.json",
                "content": json,
            ]),
            context: context())
        XCTAssertFalse(written.isError, written.content)

        let next = try await ToolRegistry.shared.execute(
            name: "grep_code",
            arguments: ToolArguments(dictionary: [
                "pattern": "foo",
                "path": root.path,
            ]),
            context: context())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "installed project hook must not execute")
        XCTAssertFalse(next.isError && next.content.lowercased().contains("denied by hook"),
                       next.content)
    }

    func testBareProjectWithNoHooksDirDoesNotExecuteOrCreateHooks() throws {
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }

        XCTAssertNil(HookDispatcher.projectHooksDir(projectRoot: bare))
        XCTAssertNil(HookDispatcher.hooksDir(projectRoot: bare))
        let d = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls", projectRoot: bare)
        XCTAssertTrue(d.allow)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: bare.appendingPathComponent(".vibecoder/hooks").path))
    }

    func testProjectPermissionRequestHookDoesNotRun() async throws {
        let marker = projectHooks.appendingPathComponent("perm-ran.txt")
        try writeExecutable("deny-ask.sh", in: projectHooks, body: """
        #!/bin/sh
        echo perm > "\(marker.path)"
        exit 2
        """)
        try writeJSON([
            "hooks": [
                "PermissionRequest": [
                    ["matcher": "run_shell", "hooks": [
                        ["type": "command", "command": "deny-ask.sh"]
                    ]]
                ]
            ]
        ], to: projectHooks)

        var reviewerCalled = false
        let reviewer = ShellApprovalReviewer { _ in
            reviewerCalled = true
            return .once
        }
        try await ShellApproval.resolveAsk(
            toolName: "run_shell",
            arguments: ToolArguments(dictionary: ["command": "ls"]),
            reason: "approval required",
            context: ToolContext(
                projectRoot: root,
                shellApprovalCoordinator: reviewer,
                conversationID: UUID(),
                executionMode: .yolo
            ))
        XCTAssertTrue(reviewerCalled, "project PermissionRequest must not block the sheet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - User hooks still run

    func testUserVibecoderHooksStillExecute() throws {
        let marker = userHooks.appendingPathComponent("user-ran.txt")
        try writeExecutable("user-deny.sh", in: userHooks, body: """
        #!/bin/sh
        echo user > "\(marker.path)"
        exit 2
        """)
        try writeJSON([
            "pre": [
                ["matcher": "run_shell", "type": "command", "command": "user-deny.sh"]
            ]
        ], to: userHooks)

        XCTAssertEqual(
            HookDispatcher.hooksDir(projectRoot: root)?.path,
            userHooks.path)
        let denied = HookDispatcher.preTool(
            toolName: "run_shell",
            argumentsSummary: "ls",
            projectRoot: root)
        XCTAssertFalse(denied.allow, denied.message ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let body = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(body.contains("user"), body)
    }

    func testUserGrokHooksStillExecute() throws {
        let grok = home.appendingPathComponent(".grok/hooks", isDirectory: true)
        let marker = grok.appendingPathComponent("grok-user.txt")
        try writeExecutable("grok-user.sh", in: grok, body: """
        #!/bin/sh
        echo grok-user > "\(marker.path)"
        exit 2
        """)
        try writeJSON([
            "pre": [
                ["matcher": "*", "type": "command", "command": "grok-user.sh"]
            ]
        ], to: grok)

        XCTAssertEqual(HookDispatcher.userHooksDir()?.path, grok.path)
        let denied = HookDispatcher.preTool(
            toolName: "read_file",
            argumentsSummary: "x",
            projectRoot: root)
        XCTAssertFalse(denied.allow, denied.message ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUserVibecoderHooksJSONFileStillExecutes() throws {
        let marker = home.appendingPathComponent("file-hook.txt")
        let command = "/bin/sh -c 'echo file > \"\(marker.path)\"; exit 2'"
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".vibecoder", isDirectory: true),
            withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "pre": [
                ["matcher": "run_shell", "type": "command", "command": command]
            ]
        ]).write(to: HookConfigStore.userConfigURL)

        XCTAssertEqual(
            HookDispatcher.userHooksDir()?.lastPathComponent,
            ".vibecoder")
        let denied = HookDispatcher.preTool(
            toolName: "run_shell",
            argumentsSummary: "ls",
            projectRoot: root)
        XCTAssertFalse(denied.allow, denied.message ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUserHooksWinOverIgnoredProjectHooks() throws {
        let projectMarker = projectHooks.appendingPathComponent("proj.txt")
        let userMarker = userHooks.appendingPathComponent("user.txt")
        try writeExecutable("proj.sh", in: projectHooks, body: """
        #!/bin/sh
        echo proj > "\(projectMarker.path)"
        exit 2
        """)
        try writeJSON([
            "pre": [["matcher": "*", "type": "command", "command": "proj.sh"]]
        ], to: projectHooks)
        try writeExecutable("user.sh", in: userHooks, body: """
        #!/bin/sh
        echo user > "\(userMarker.path)"
        exit 2
        """)
        try writeJSON([
            "pre": [["matcher": "*", "type": "command", "command": "user.sh"]]
        ], to: userHooks)

        let denied = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls", projectRoot: root)
        XCTAssertFalse(denied.allow)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectMarker.path))
    }

    func testNilOverrideWithoutEnvOrMarkerKeepsIgnoringProject() {
        HookDispatcher.setAllowProjectFileHooksOverride(nil)
        HookDispatcher.setProcessEnvironmentOverride([:])
        XCTAssertFalse(HookDispatcher.resolvesAllowProjectFileHooks())
        XCTAssertNil(
            HookDispatcher.hooksDir(projectRoot: root),
            "no override / env / marker must keep default-ignore")
    }

    func testAllowProjectFileHooksOptInRunsProject() throws {
        let marker = projectHooks.appendingPathComponent("opt-in.txt")
        try writeExecutable("opt.sh", in: projectHooks, body: """
        #!/bin/sh
        echo opt > "\(marker.path)"
        exit 2
        """)
        try writeJSON([
            "pre": [["matcher": "*", "type": "command", "command": "opt.sh"]]
        ], to: projectHooks)

        HookDispatcher.allowProjectFileHooks = true
        defer { HookDispatcher.setAllowProjectFileHooksOverride(nil) }

        XCTAssertEqual(
            HookDispatcher.hooksDir(projectRoot: root)?.path,
            projectHooks.path)
        let denied = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls", projectRoot: root)
        XCTAssertFalse(denied.allow, denied.message ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testEnvOverrideAllowsProjectHooksWithoutSettings() throws {
        let marker = projectHooks.appendingPathComponent("env-opt.txt")
        try writeExecutable("env.sh", in: projectHooks, body: """
        #!/bin/sh
        echo env > "\(marker.path)"
        exit 2
        """)
        try writeJSON([
            "pre": [["matcher": "*", "type": "command", "command": "env.sh"]]
        ], to: projectHooks)

        HookDispatcher.setAllowProjectFileHooksOverride(nil)
        HookDispatcher.setProcessEnvironmentOverride([
            HookDispatcher.allowProjectFileHooksEnvironmentKey: "1"
        ])
        defer {
            HookDispatcher.setProcessEnvironmentOverride(nil)
            HookDispatcher.setAllowProjectFileHooksOverride(false)
        }

        XCTAssertTrue(HookDispatcher.resolvesAllowProjectFileHooks())
        XCTAssertEqual(
            HookDispatcher.hooksDir(projectRoot: root)?.path,
            projectHooks.path)
        let denied = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls", projectRoot: root)
        XCTAssertFalse(denied.allow, denied.message ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUserMarkerFileAllowsProjectHooksWithoutSettings() throws {
        let marker = projectHooks.appendingPathComponent("file-opt.txt")
        try writeExecutable("file.sh", in: projectHooks, body: """
        #!/bin/sh
        echo file > "\(marker.path)"
        exit 2
        """)
        try writeJSON([
            "pre": [["matcher": "*", "type": "command", "command": "file.sh"]]
        ], to: projectHooks)

        let policy = HookConfigStore.allowProjectFileHooksMarkerURL
        try FileManager.default.createDirectory(
            at: policy.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: policy)

        HookDispatcher.setAllowProjectFileHooksOverride(nil)
        HookDispatcher.setProcessEnvironmentOverride([:])
        defer {
            HookDispatcher.setProcessEnvironmentOverride(nil)
            HookDispatcher.setAllowProjectFileHooksOverride(false)
        }

        XCTAssertTrue(HookDispatcher.resolvesAllowProjectFileHooks())
        XCTAssertEqual(
            HookDispatcher.hooksDir(projectRoot: root)?.path,
            projectHooks.path)
        let denied = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls", projectRoot: root)
        XCTAssertFalse(denied.allow, denied.message ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}
