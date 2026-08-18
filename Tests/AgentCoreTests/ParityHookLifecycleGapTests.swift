//
//  ParityHookLifecycleGapTests.swift
//
//  Wave 4: PermissionRequest + PostToolUseFailure + PreToolUse `ask`
//  fail-closed via shared helpers. Hooks here are user-scope
//  (~/.vibecoder/hooks via home override); project files stay ignored.
//

import XCTest
@testable import AgentCore

final class ParityHookLifecycleGapTests: XCTestCase {

    private var home: URL!
    private var root: URL!
    private var hooks: URL!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-life-home-\(UUID().uuidString)", isDirectory: true)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-lifecycle-\(UUID().uuidString)", isDirectory: true)
        hooks = home.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        HookDispatcher.setHooksHomeDirectoryOverride(home)
        HookDispatcher.allowProjectFileHooks = false
        await ToolRegistry.shared.registerBuiltins()
    }

    override func tearDown() {
        HookDispatcher.allowProjectFileHooks = false
        HookDispatcher.setHooksHomeDirectoryOverride(nil)
        if let root { try? FileManager.default.removeItem(at: root) }
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func context(reviewer: ShellApprovalReviewer? = nil) -> ToolContext {
        ToolContext(
            projectRoot: root,
            shellApprovalCoordinator: reviewer,
            conversationID: UUID(),
            executionMode: .yolo
        )
    }

    private func writeHooksJSON(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object)
            .write(to: hooks.appendingPathComponent("hooks.json"))
    }

    private func writeExecutable(_ name: String, body: String) throws -> URL {
        let url = hooks.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - PermissionRequest

    func testPermissionRequestDenyBlocksResolveAskBeforeReviewer() async throws {
        let marker = hooks.appendingPathComponent("perm.txt")
        try writeExecutable("deny-perm.sh", body: """
        #!/bin/sh
        echo fired > "\(marker.path)"
        exit 2
        """)
        try writeHooksJSON([
            "hooks": [
                "PermissionRequest": [
                    ["matcher": "run_shell", "hooks": [
                        ["type": "command", "command": "deny-perm.sh"]
                    ]]
                ]
            ]
        ])

        var reviewerCalled = false
        let reviewer = ShellApprovalReviewer { _ in
            reviewerCalled = true
            return .once
        }
        do {
            try await ShellApproval.resolveAsk(
                toolName: "run_shell",
                arguments: ToolArguments(dictionary: ["command": "git status"]),
                reason: "approval required",
                context: context(reviewer: reviewer))
            XCTFail("expected PermissionRequest deny")
        } catch let error as ToolError {
            if case .permissionDenied(let msg) = error {
                XCTAssertFalse(msg.isEmpty, msg)
            } else {
                XCTFail("wrong ToolError \(error)")
            }
        }
        XCTAssertFalse(reviewerCalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testPermissionRequestAllowReachesReviewer() async throws {
        try writeExecutable("allow-perm.sh", body: """
        #!/bin/sh
        exit 0
        """)
        try writeHooksJSON([
            "hooks": [
                "PermissionRequest": [
                    ["matcher": "run_shell", "hooks": [
                        ["type": "command", "command": "allow-perm.sh"]
                    ]]
                ]
            ]
        ])

        var reviewerCalled = false
        let reviewer = ShellApprovalReviewer { _ in
            reviewerCalled = true
            return .once
        }
        try await ShellApproval.resolveAsk(
            toolName: "run_shell",
            arguments: ToolArguments(dictionary: ["command": "git status"]),
            reason: "approval required",
            context: context(reviewer: reviewer))
        XCTAssertTrue(reviewerCalled)
    }

    func testSessionGrantStyleOnceStillRunsPermissionRequest() async throws {
        let marker = hooks.appendingPathComponent("session-perm.txt")
        try writeExecutable("deny-session.sh", body: """
        #!/bin/sh
        echo session > "\(marker.path)"
        exit 2
        """)
        try writeHooksJSON([
            "hooks": [
                "PermissionRequest": [
                    ["matcher": "*", "hooks": [
                        ["type": "command", "command": "deny-session.sh"]
                    ]]
                ]
            ]
        ])

        // Coordinator would skip the sheet (.once) — hook must still deny first.
        let reviewer = ShellApprovalReviewer { _ in .once }
        do {
            try await ShellApproval.resolveAsk(
                toolName: "run_shell",
                arguments: ToolArguments(dictionary: ["command": "ls"]),
                reason: "session grant would skip sheet",
                context: context(reviewer: reviewer))
            XCTFail("hook must deny even when reviewer would allow once")
        } catch is ToolError {
            // expected
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testPermissionRequestDenialHelperNoHooksAllows() {
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-perm-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        XCTAssertNil(
            HookDispatcher.permissionRequestDenial(
                toolName: "run_shell",
                payload: "ls",
                projectRoot: bare))
    }

    // MARK: - PostToolUseFailure

    func testDecorateFiresPostToolUseFailureOnIsErrorOnly() throws {
        let failMarker = hooks.appendingPathComponent("fail.txt")
        let postMarker = hooks.appendingPathComponent("post.txt")
        try writeExecutable("on-fail.sh", body: """
        #!/bin/sh
        echo fail > "\(failMarker.path)"
        exit 0
        """)
        try writeExecutable("on-post.sh", body: """
        #!/bin/sh
        echo post > "\(postMarker.path)"
        exit 0
        """)
        try writeHooksJSON([
            "hooks": [
                "PostToolUseFailure": [
                    ["hooks": [["type": "command", "command": "on-fail.sh"]]]
                ],
                "PostToolUse": [
                    ["hooks": [["type": "command", "command": "on-post.sh"]]]
                ]
            ]
        ])

        let ok = HookDispatcher.decorateWithPostToolHooks(
            toolName: "read_file",
            result: ToolResult(content: "ok"),
            projectRoot: root)
        XCTAssertFalse(ok.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failMarker.path),
                       "success must not fire PostToolUseFailure")
        XCTAssertTrue(FileManager.default.fileExists(atPath: postMarker.path),
                      "success still runs PostToolUse")

        try? FileManager.default.removeItem(at: failMarker)
        try? FileManager.default.removeItem(at: postMarker)

        let err = HookDispatcher.decorateWithPostToolHooks(
            toolName: "read_file",
            result: ToolResult(content: "boom", isError: true),
            projectRoot: root)
        XCTAssertTrue(err.isError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failMarker.path),
                      "isError must fire PostToolUseFailure")
        XCTAssertTrue(FileManager.default.fileExists(atPath: postMarker.path),
                      "isError still runs PostToolUse")
    }

    func testNotifyPostToolUseFailureOnThrowSummary() throws {
        let marker = hooks.appendingPathComponent("throw-fail.txt")
        try writeExecutable("on-throw.sh", body: """
        #!/bin/sh
        echo throw > "\(marker.path)"
        exit 0
        """)
        try writeHooksJSON([
            "hooks": [
                "PostToolUseFailure": [
                    ["matcher": "write_file", "hooks": [
                        ["type": "command", "command": "on-throw.sh"]
                    ]]
                ]
            ]
        ])
        _ = HookDispatcher.notifyPostToolUseFailure(
            toolName: "write_file",
            errorSummary: "Execution failed",
            projectRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRegistryExecuteIsErrorFiresPostToolUseFailure() async throws {
        let marker = hooks.appendingPathComponent("registry-fail.txt")
        try writeExecutable("reg-fail.sh", body: """
        #!/bin/sh
        echo registry > "\(marker.path)"
        exit 0
        """)
        try writeHooksJSON([
            "hooks": [
                "PostToolUseFailure": [
                    ["matcher": "read_file", "hooks": [
                        ["type": "command", "command": "reg-fail.sh"]
                    ]]
                ]
            ]
        ])
        let result = try await ToolRegistry.shared.execute(
            name: "read_file",
            arguments: ToolArguments(dictionary: ["path": "missing-no-such.txt"]),
            context: context())
        XCTAssertTrue(result.isError, result.content)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "ToolRegistry.execute isError must fire PostToolUseFailure")
    }

    func testRegistryExecuteSuccessDoesNotFirePostToolUseFailure() async throws {
        let marker = hooks.appendingPathComponent("registry-ok-fail.txt")
        let file = root.appendingPathComponent("ok.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        try writeExecutable("should-not.sh", body: """
        #!/bin/sh
        echo no > "\(marker.path)"
        exit 0
        """)
        try writeHooksJSON([
            "hooks": [
                "PostToolUseFailure": [
                    ["hooks": [["type": "command", "command": "should-not.sh"]]]
                ]
            ]
        ])
        let result = try await ToolRegistry.shared.execute(
            name: "read_file",
            arguments: ToolArguments(dictionary: ["path": "ok.txt"]),
            context: context())
        XCTAssertFalse(result.isError, result.content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - MCP / PreToolDetailed ask

    func testAppliedPreToolDecisionAskFailsClosed() {
        let ask = PreToolHookResult(
            allow: true,
            permissionDecision: "ask",
            message: "please confirm")
        let applied = HookDispatcher.appliedPreToolDecision(ask)
        XCTAssertEqual(applied.denyMessage, "please confirm")
        XCTAssertNil(applied.updatedInputJSON)
    }

    func testAppliedPreToolDecisionDenyAndRewrite() {
        let denied = HookDispatcher.appliedPreToolDecision(
            PreToolHookResult(allow: false, permissionDecision: "deny", message: "no"))
        XCTAssertEqual(denied.denyMessage, "no")

        let rewritten = HookDispatcher.appliedPreToolDecision(
            PreToolHookResult(
                allow: true,
                permissionDecision: "allow",
                updatedInputJSON: #"{"path":"x"}"#))
        XCTAssertNil(rewritten.denyMessage)
        XCTAssertEqual(rewritten.updatedInputJSON, #"{"path":"x"}"#)
    }

    func testMCPApplyPreToolDetailedAskDoesNotSilentAllow() throws {
        try writeExecutable("ask-pre.sh", body: """
        #!/bin/sh
        printf '%s' '{"permissionDecision":"ask"}'
        exit 0
        """)
        try writeHooksJSON([
            "hooks": [
                "PreToolUse": [
                    ["matcher": "server__tool", "hooks": [
                        ["type": "command", "command": "ask-pre.sh"]
                    ]]
                ]
            ]
        ])
        let applied = HookDispatcher.applyPreToolDetailedJSONArgs(
            toolName: "server__tool",
            arguments: ["q": "1"],
            projectRoot: root)
        XCTAssertNotNil(applied.denyMessage, "ask must fail closed (not silent-allow)")
        XCTAssertTrue(
            applied.denyMessage?.lowercased().contains("approval") == true
                || applied.denyMessage != nil,
            applied.denyMessage ?? "")
    }

    func testLegacyPreToolMapsAskToAllowButDetailedDoesNot() throws {
        try writeExecutable("ask-only.sh", body: """
        #!/bin/sh
        printf '%s' '{"permissionDecision":"ask"}'
        exit 0
        """)
        try writeHooksJSON([
            "pre": [
                ["matcher": "*", "type": "command", "command": "ask-only.sh"]
            ]
        ])
        let legacy = HookDispatcher.preTool(
            toolName: "run_shell",
            argumentsSummary: "ls",
            projectRoot: root)
        XCTAssertTrue(legacy.allow, "legacy preTool still maps ask → allow")
        let detailed = HookDispatcher.applyPreToolDetailed(
            toolName: "run_shell",
            argumentsSummary: "ls",
            projectRoot: root)
        XCTAssertNotNil(detailed.denyMessage, "Wave 4 detailed path must not silent-allow ask")
    }
}
