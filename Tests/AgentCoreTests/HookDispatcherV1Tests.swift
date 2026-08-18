//
//  HookDispatcherV1Tests.swift
//  Wave B S3 — config-driven Pre/Post command runners.
//

import XCTest
@testable import AgentCore

final class HookDispatcherV1Tests: XCTestCase {

    private var root: URL!
    private var hooks: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-v1-\(UUID().uuidString)", isDirectory: true)
        hooks = root.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        HookDispatcher.setHooksHomeDirectoryOverride(root)
        HookDispatcher.allowProjectFileHooks = false
    }

    override func tearDownWithError() throws {
        HookDispatcher.allowProjectFileHooks = false
        HookDispatcher.setHooksHomeDirectoryOverride(nil)
        try? FileManager.default.removeItem(at: root)
        root = nil
        hooks = nil
    }

    // MARK: - deny-tools (regression)

    func testDenyToolsTxtStillBlocks() throws {
        try "run_shell\n".write(
            to: hooks.appendingPathComponent("deny-tools.txt"),
            atomically: true, encoding: .utf8)
        let denied = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls", projectRoot: root)
        XCTAssertFalse(denied.allow)
        XCTAssertTrue(denied.message?.contains("deny-tools") == true)
        let allowed = HookDispatcher.preTool(
            toolName: "read_file", argumentsSummary: "x", projectRoot: root)
        XCTAssertTrue(allowed.allow)
    }

    /// Wave C: Windows CRLF deny lists must still match tool names.
    func testDenyToolsTxtCRLF() throws {
        let data = "run_shell\r\n# comment\r\nedit_file\r\n".data(using: .utf8)!
        try data.write(to: hooks.appendingPathComponent("deny-tools.txt"))
        let shell = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls", projectRoot: root)
        XCTAssertFalse(shell.allow, shell.message ?? "")
        let edit = HookDispatcher.preTool(
            toolName: "edit_file", argumentsSummary: "x", projectRoot: root)
        XCTAssertFalse(edit.allow, edit.message ?? "")
        let ok = HookDispatcher.preTool(
            toolName: "read_file", argumentsSummary: "x", projectRoot: root)
        XCTAssertTrue(ok.allow)
    }

    /// Wave C: no hooks dir → allow, and do not create .vibecoder/hooks.
    func testNoHooksDirDoesNotCreatePollution() throws {
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }

        HookDispatcher.setHooksHomeDirectoryOverride(bare)
        XCTAssertNil(HookDispatcher.hooksDir(projectRoot: bare))
        let d = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls", projectRoot: bare)
        XCTAssertTrue(d.allow)
        let vibecoderHooks = bare.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: vibecoderHooks.path),
            "preTool must not create hooks dir when none configured")
    }

    func testParseDecisionJSONWithLeadingNoise() {
        let noisy = """
        hook starting
        {"decision":"deny","reason":"from-embedded"}
        done
        """
        let d = HookDispatcher.parseDecisionJSON(noisy)
        XCTAssertEqual(d?.allow, false)
        XCTAssertEqual(d?.message, "from-embedded")
    }

    // MARK: - Matchers

    func testMatcherExactAndPipeList() {
        XCTAssertTrue(HookDispatcher.matcherMatches(nil, toolName: "anything"))
        XCTAssertTrue(HookDispatcher.matcherMatches("*", toolName: "run_shell"))
        XCTAssertTrue(HookDispatcher.matcherMatches("run_shell", toolName: "run_shell"))
        XCTAssertFalse(HookDispatcher.matcherMatches("run_shell", toolName: "read_file"))
        XCTAssertTrue(HookDispatcher.matcherMatches("run_shell|edit_file", toolName: "edit_file"))
        XCTAssertFalse(HookDispatcher.matcherMatches("run_shell|edit_file", toolName: "write_file"))
        XCTAssertTrue(HookDispatcher.matcherMatches("^mcp__.*", toolName: "mcp__gh__create"))
    }

    // MARK: - Config parse

    func testParseFlatConfig() throws {
        let json: [String: Any] = [
            "pre": [
                ["matcher": "run_shell", "type": "command", "command": "block.sh", "timeout": 3]
            ],
            "post": [
                ["matcher": "edit_file", "type": "command", "command": "lint.sh"]
            ]
        ]
        let cfg = HookDispatcher.parseConfigJSON(json)
        XCTAssertEqual(cfg.pre.count, 1)
        XCTAssertEqual(cfg.pre[0].handlers[0].command, "block.sh")
        XCTAssertEqual(cfg.pre[0].handlers[0].timeoutSeconds, 3)
        XCTAssertEqual(cfg.post.count, 1)
        XCTAssertEqual(cfg.post[0].matcher, "edit_file")
    }

    func testParseNestedClaudeStyleConfig() throws {
        let json: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "run_shell",
                        "hooks": [
                            ["type": "command", "command": "block.sh", "name": "block-rm"]
                        ]
                    ]
                ],
                "PostToolUse": [
                    [
                        "matcher": "edit_file|write_file",
                        "hooks": [
                            ["type": "command", "command": "lint.sh"]
                        ]
                    ]
                ]
            ]
        ]
        let cfg = HookDispatcher.parseConfigJSON(json)
        XCTAssertEqual(cfg.pre.count, 1)
        XCTAssertEqual(cfg.pre[0].handlers[0].name, "block-rm")
        XCTAssertEqual(cfg.post.count, 1)
        XCTAssertEqual(cfg.post[0].matcher, "edit_file|write_file")
    }

    // MARK: - Decision JSON

    func testParseDecisionJSONGrokAndClaude() {
        let grokDeny = """
        {"decision":"deny","reason":"no rm -rf"}
        """
        let d1 = HookDispatcher.parseDecisionJSON(grokDeny)
        XCTAssertEqual(d1?.allow, false)
        XCTAssertEqual(d1?.message, "no rm -rf")

        let claudeDeny = """
        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"blocked"}}
        """
        let d2 = HookDispatcher.parseDecisionJSON(claudeDeny)
        XCTAssertEqual(d2?.allow, false)
        XCTAssertEqual(d2?.message, "blocked")

        let allow = """
        {"decision":"allow"}
        """
        XCTAssertEqual(HookDispatcher.parseDecisionJSON(allow)?.allow, true)
    }

    func testInterpretExitCode2Denies() {
        let d = HookDispatcher.interpretCommandOutput(
            exitCode: 2,
            stdout: "bad command",
            stderr: "",
            hookName: "block",
            toolName: "run_shell"
        )
        XCTAssertFalse(d.allow)
        XCTAssertTrue(d.message?.contains("bad command") == true)
    }

    func testInterpretNonZeroOtherFailOpen() {
        let d = HookDispatcher.interpretCommandOutput(
            exitCode: 1,
            stdout: "",
            stderr: "oops",
            hookName: "x",
            toolName: "run_shell"
        )
        XCTAssertTrue(d.allow)
    }

    // MARK: - Live command runners

    func testPreToolCommandExit2Denies() throws {
        let script = hooks.appendingPathComponent("deny-all.sh")
        try """
        #!/bin/sh
        exit 2
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "pre": [
                ["matcher": "run_shell", "type": "command", "command": "deny-all.sh", "timeout": 5]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: config)
        try data.write(to: hooks.appendingPathComponent("hooks.json"))

        let denied = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "rm -rf /", projectRoot: root)
        XCTAssertFalse(denied.allow, denied.message ?? "")

        let other = HookDispatcher.preTool(
            toolName: "read_file", argumentsSummary: "x", projectRoot: root)
        XCTAssertTrue(other.allow)
    }

    func testPreToolCommandJSONDenyWithReason() throws {
        let script = hooks.appendingPathComponent("json-deny.sh")
        try """
        #!/bin/sh
        echo '{"decision":"deny","reason":"policy: no shell"}'
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": "json-deny.sh"]
                        ]
                    ]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let denied = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "echo hi", projectRoot: root)
        XCTAssertFalse(denied.allow)
        XCTAssertTrue(
            denied.message?.contains("policy: no shell") == true,
            denied.message ?? "nil")
    }

    func testPreToolMissingCommandFailOpen() throws {
        let config: [String: Any] = [
            "pre": [
                ["matcher": "run_shell", "type": "command", "command": "does-not-exist-xyz.sh"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let d = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls", projectRoot: root)
        XCTAssertTrue(d.allow, "missing command must fail-open")
    }

    func testPostToolCommandDenyFlagsResult() throws {
        let script = hooks.appendingPathComponent("post-deny.sh")
        try """
        #!/bin/sh
        echo '{"decision":"deny","reason":"lint failed"}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "post": [
                ["matcher": "edit_file", "type": "command", "command": "post-deny.sh"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let d = HookDispatcher.postTool(
            toolName: "edit_file",
            resultSummary: "ok",
            projectRoot: root)
        XCTAssertFalse(d.allow)
        XCTAssertTrue(d.message?.contains("lint failed") == true)
    }

    func testPostToolAllowWhenNoHooks() {
        let d = HookDispatcher.postTool(
            toolName: "read_file", resultSummary: "ok", projectRoot: root)
        XCTAssertTrue(d.allow)
    }

    func testShellFormCommandReceivesStdinEnvelope() throws {
        // Write marker with tool name from stdin JSON using python for reliability.
        let marker = hooks.appendingPathComponent("seen-tool.txt")
        let script = hooks.appendingPathComponent("echo-tool.sh")
        // Use sh + sed-friendly: python3 if available, else pure sh with cat
        try """
        #!/bin/sh
        cat > "\(hooks.path)/stdin-capture.json"
        # always allow
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "pre": [
                ["matcher": "web_search", "type": "command", "command": "echo-tool.sh"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let d = HookDispatcher.preTool(
            toolName: "web_search",
            argumentsSummary: "query=test",
            projectRoot: root)
        XCTAssertTrue(d.allow)

        let capture = hooks.appendingPathComponent("stdin-capture.json")
        let text = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertTrue(text.contains("web_search"), text)
        XCTAssertTrue(text.contains("PreToolUse"), text)
        _ = marker // silence if unused
    }

    func testRegistryExecuteHonorsPreCommandDeny() async throws {
        let script = hooks.appendingPathComponent("deny-grep.sh")
        try """
        #!/bin/sh
        exit 2
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        let config: [String: Any] = [
            "pre": [
                ["matcher": "grep_code", "type": "command", "command": "deny-grep.sh"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        await ToolRegistry.shared.registerBuiltins()
        let ctx = ToolContext(
            projectRoot: root,
            worktreeRoot: nil,
            safeMode: nil,
            conversationID: UUID()
        )
        let results = await ToolRegistry.shared.executeReadOnlyBatch(
            invocations: [
                (name: "grep_code", arguments: ToolArguments(dictionary: [
                    "pattern": "foo", "path": root.path
                ]))
            ],
            context: ctx
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError, results[0].content)
        XCTAssertTrue(
            results[0].content.lowercased().contains("denied")
                || results[0].content.lowercased().contains("hook"),
            results[0].content)
    }

    // MARK: - Wave C2

    func testDenyToolsInlineComment() throws {
        try "run_shell  # never auto\nread_file\n".write(
            to: hooks.appendingPathComponent("deny-tools.txt"),
            atomically: true, encoding: .utf8)
        let denied = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls", projectRoot: root)
        XCTAssertFalse(denied.allow, denied.message ?? "")
        let rf = HookDispatcher.preTool(
            toolName: "read_file", argumentsSummary: "x", projectRoot: root)
        XCTAssertFalse(rf.allow)
        let ok = HookDispatcher.preTool(
            toolName: "edit_file", argumentsSummary: "x", projectRoot: root)
        XCTAssertTrue(ok.allow)
    }

    func testHooksDirPrefersProjectOverWorktree() throws {
        let wt = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-wt-\(UUID().uuidString)", isDirectory: true)
        let wtHooks = wt.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: wtHooks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wt) }
        try "run_shell\n".write(
            to: wtHooks.appendingPathComponent("deny-tools.txt"),
            atomically: true, encoding: .utf8)
        try "edit_file\n".write(
            to: hooks.appendingPathComponent("deny-tools.txt"),
            atomically: true, encoding: .utf8)
        let d = HookDispatcher.preTool(
            toolName: "edit_file", argumentsSummary: "x",
            projectRoot: root, worktreeRoot: wt)
        XCTAssertFalse(d.allow, "project deny-tools must win over worktree")
        let shell = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls",
            projectRoot: root, worktreeRoot: wt)
        XCTAssertTrue(shell.allow)
    }

    func testHooksDirFallsBackToWorktreeWhenProjectHasNone() throws {
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-bare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        let wt = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-wt2-\(UUID().uuidString)", isDirectory: true)
        let wtHooks = wt.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: wtHooks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wt) }
        try "run_shell\n".write(
            to: wtHooks.appendingPathComponent("deny-tools.txt"),
            atomically: true, encoding: .utf8)
        let ignored = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls",
            projectRoot: bare, worktreeRoot: wt)
        XCTAssertTrue(ignored.allow, "worktree project hooks ignored by default")
        HookDispatcher.allowProjectFileHooks = true
        let d = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls",
            projectRoot: bare, worktreeRoot: wt)
        XCTAssertFalse(d.allow, "opt-in still uses worktree when project has none")
    }

    func testTimeoutStringInConfig() throws {
        let json: [String: Any] = [
            "pre": [
                ["matcher": "run_shell", "type": "command", "command": "x.sh", "timeout": "3.5"]
            ]
        ]
        let cfg = HookDispatcher.parseConfigJSON(json)
        XCTAssertEqual(cfg.pre[0].handlers[0].timeoutSeconds, 3.5, accuracy: 0.01)
    }
}
