//
//  HookDispatcherV2Tests.swift
//  Phase B PB1 — lifecycle events (SessionStart / UserPromptSubmit / Stop / Notification).
//

import XCTest
@testable import AgentCore

final class HookDispatcherV2Tests: XCTestCase {

    private var root: URL!
    private var hooks: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-v2-\(UUID().uuidString)", isDirectory: true)
        hooks = root.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        hooks = nil
    }

    // MARK: - Parse

    func testParseNestedLifecycleKeys() throws {
        let json: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "setup.sh", "name": "setup"]]]
                ],
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": "guard.sh"]]]
                ],
                "Stop": [
                    ["hooks": [["type": "command", "command": "done.sh"]]]
                ],
                "Notification": [
                    [
                        "matcher": "idle_prompt",
                        "hooks": [["type": "command", "command": "n.sh"]]
                    ]
                ],
                "PreToolUse": [
                    [
                        "matcher": "run_shell",
                        "hooks": [["type": "command", "command": "block.sh"]]
                    ]
                ]
            ]
        ]
        let cfg = HookDispatcher.parseConfigJSON(json)
        XCTAssertEqual(cfg.sessionStart.count, 1)
        XCTAssertEqual(cfg.sessionStart[0].handlers[0].name, "setup")
        XCTAssertEqual(cfg.userPromptSubmit.count, 1)
        XCTAssertEqual(cfg.userPromptSubmit[0].handlers[0].command, "guard.sh")
        XCTAssertEqual(cfg.stop.count, 1)
        XCTAssertEqual(cfg.notification.count, 1)
        XCTAssertEqual(cfg.notification[0].matcher, "idle_prompt")
        XCTAssertEqual(cfg.pre.count, 1, "tool PreToolUse must still parse alongside lifecycle")
    }

    func testParseFlatLifecycleAliases() {
        let json: [String: Any] = [
            "session_start": [
                ["type": "command", "command": "a.sh"]
            ],
            "user_prompt_submit": [
                ["type": "command", "command": "b.sh"]
            ],
            "stop": [
                ["type": "command", "command": "c.sh"]
            ]
        ]
        let cfg = HookDispatcher.parseConfigJSON(json)
        XCTAssertEqual(cfg.sessionStart.count, 1)
        XCTAssertEqual(cfg.userPromptSubmit.count, 1)
        XCTAssertEqual(cfg.stop.count, 1)
    }

    // MARK: - Deny UserPromptSubmit

    func testUserPromptSubmitExit2Denies() throws {
        let script = hooks.appendingPathComponent("deny-prompt.sh")
        try """
        #!/bin/sh
        exit 2
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": "deny-prompt.sh"]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let denied = HookDispatcher.userPromptSubmit(
            prompt: "rm -rf /",
            projectRoot: root)
        XCTAssertFalse(denied.allow, denied.message ?? "")
    }

    func testUserPromptSubmitJSONDeny() throws {
        let script = hooks.appendingPathComponent("json-deny-prompt.sh")
        try """
        #!/bin/sh
        echo '{"decision":"deny","reason":"blocked by policy"}'
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": "json-deny-prompt.sh"]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let denied = HookDispatcher.userPromptSubmit(
            prompt: "hello",
            projectRoot: root)
        XCTAssertFalse(denied.allow)
        XCTAssertTrue(
            denied.message?.contains("blocked by policy") == true,
            denied.message ?? "nil")
    }

    // MARK: - SessionStart / Stop smoke

    func testSessionStartRunsCommand() throws {
        let marker = hooks.appendingPathComponent("session-started.txt")
        let script = hooks.appendingPathComponent("session-start.sh")
        try """
        #!/bin/sh
        echo ok > "\(marker.path)"
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "session-start.sh"]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let d = HookDispatcher.sessionStart(projectRoot: root)
        XCTAssertTrue(d.allow)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "SessionStart command should have written marker")
    }

    func testStopRunsCommandWithReasonInStdin() throws {
        let capture = hooks.appendingPathComponent("stop-stdin.json")
        let script = hooks.appendingPathComponent("stop.sh")
        try """
        #!/bin/sh
        cat > "\(capture.path)"
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "stop.sh"]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let d = HookDispatcher.stop(reason: "finished", projectRoot: root)
        XCTAssertTrue(d.allow)
        let text = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertTrue(text.contains("Stop"), text)
        XCTAssertTrue(text.contains("finished"), text)
    }

    // MARK: - PC5: Stop reasons used by AgentLoop early exits

    /// AgentLoop cancel paths pass reason `"cancelled"` into Stop.
    func testStopHookAcceptsCancelledReason() throws {
        let capture = hooks.appendingPathComponent("stop-cancel.json")
        let script = hooks.appendingPathComponent("stop-cancel.sh")
        try """
        #!/bin/sh
        cat > "\(capture.path)"
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "stop-cancel.sh"]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let d = HookDispatcher.stop(reason: "cancelled", projectRoot: root)
        XCTAssertTrue(d.allow)
        let text = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertTrue(text.contains("cancelled"), text)
        XCTAssertTrue(text.contains("\"reason\""), text)
    }

    /// Cap exit uses reason containing `iteration cap`.
    func testStopHookAcceptsIterationCapReason() throws {
        let capture = hooks.appendingPathComponent("stop-cap.json")
        let script = hooks.appendingPathComponent("stop-cap.sh")
        try """
        #!/bin/sh
        cat > "\(capture.path)"
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "stop-cap.sh"]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let reason = "iteration cap (2)"
        let d = HookDispatcher.stop(reason: reason, projectRoot: root)
        XCTAssertTrue(d.allow)
        let text = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertTrue(text.contains("iteration cap"), text)
    }

    // MARK: - PreToolUse no-regression

    func testPreToolUseStillDeniesWithLifecycleConfigPresent() throws {
        let script = hooks.appendingPathComponent("deny-shell.sh")
        try """
        #!/bin/sh
        exit 2
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "deny-shell.sh"]]]
                ],
                "PreToolUse": [
                    [
                        "matcher": "run_shell",
                        "hooks": [["type": "command", "command": "deny-shell.sh"]]
                    ]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let denied = HookDispatcher.preTool(
            toolName: "run_shell",
            argumentsSummary: "ls",
            projectRoot: root)
        XCTAssertFalse(denied.allow, denied.message ?? "")

        let allowed = HookDispatcher.preTool(
            toolName: "read_file",
            argumentsSummary: "x",
            projectRoot: root)
        XCTAssertTrue(allowed.allow)
    }

    func testNotificationMatcherFiltersType() throws {
        let marker = hooks.appendingPathComponent("notif.txt")
        let script = hooks.appendingPathComponent("notif.sh")
        try """
        #!/bin/sh
        echo fired > "\(marker.path)"
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "hooks": [
                "Notification": [
                    [
                        "matcher": "idle_prompt",
                        "hooks": [["type": "command", "command": "notif.sh"]]
                    ]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        _ = HookDispatcher.notification(
            type: "other", message: "x", projectRoot: root)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "matcher should skip non-matching notification type")

        _ = HookDispatcher.notification(
            type: "idle_prompt", message: "hi", projectRoot: root)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "matcher should run for idle_prompt")
    }
}
