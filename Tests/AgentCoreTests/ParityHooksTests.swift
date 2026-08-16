//
//  ParityHooksTests.swift
//  ZCode-parity hook JSON: Stop continue+context, PreToolUse updatedInput,
//  exit 2 / decision:block deny, old HookDecision path unchanged.
//

import XCTest
@testable import AgentCore

final class ParityHooksTests: XCTestCase {

    private var root: URL!
    private var hooks: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-hooks-\(UUID().uuidString)", isDirectory: true)
        hooks = root.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        hooks = nil
    }

    // MARK: - Stop continue + additionalContext

    func testParseStopContinueWithAdditionalContext() {
        let json = """
        {"continue":true,"additionalContext":"run the test suite"}
        """
        let parsed = HookDispatcher.parseStopHookJSON(json)
        XCTAssertEqual(parsed?.allow, true)
        XCTAssertEqual(parsed?.shouldContinue, true)
        XCTAssertEqual(parsed?.additionalContext, "run the test suite")
        // Old allow/deny parser has no continue bit — must not invent a deny.
        XCTAssertNil(HookDispatcher.parseDecisionJSON(json))
    }

    func testParseStopContinueSnakeCaseAdditionalContext() {
        let json = """
        {"continue":true,"additional_context":"snake context"}
        """
        let parsed = HookDispatcher.parseStopHookJSON(json)
        XCTAssertEqual(parsed?.allow, true)
        XCTAssertEqual(parsed?.shouldContinue, true)
        XCTAssertEqual(parsed?.additionalContext, "snake context")
    }

    func testParseStopContinueFalseDoesNotForce() {
        let json = """
        {"continue":false,"additionalContext":"ignored"}
        """
        let parsed = HookDispatcher.parseStopHookJSON(json)
        XCTAssertEqual(parsed?.shouldContinue, false)
        XCTAssertEqual(parsed?.additionalContext, "ignored")
        XCTAssertFalse(
            HookDispatcher.shouldContinueAfterStop(parsed ?? .allow, continuationCount: 0)
        )
    }

    func testShouldContinueAfterStopRequiresContextAndCap() {
        XCTAssertEqual(HookDispatcher.maxStopContinuations, 3)

        let withCtx = StopHookResult(
            allow: true, shouldContinue: true, additionalContext: "go on")
        XCTAssertTrue(HookDispatcher.shouldContinueAfterStop(withCtx, continuationCount: 0))
        XCTAssertTrue(HookDispatcher.shouldContinueAfterStop(withCtx, continuationCount: 2))
        XCTAssertFalse(HookDispatcher.shouldContinueAfterStop(withCtx, continuationCount: 3))

        let noCtx = StopHookResult(
            allow: true, shouldContinue: true, additionalContext: nil)
        XCTAssertFalse(HookDispatcher.shouldContinueAfterStop(noCtx, continuationCount: 0))

        let denied = StopHookResult(
            allow: false, shouldContinue: true, additionalContext: "nope")
        XCTAssertFalse(HookDispatcher.shouldContinueAfterStop(denied, continuationCount: 0))
    }

    func testParseStopDecisionBlockDoesNotContinue() {
        let json = """
        {"decision":"block","reason":"stop here","continue":true,"additionalContext":"x"}
        """
        let parsed = HookDispatcher.parseStopHookJSON(json)
        XCTAssertEqual(parsed?.allow, false)
        XCTAssertEqual(parsed?.shouldContinue, false)
        XCTAssertEqual(parsed?.message, "stop here")
    }

    // MARK: - PreToolUse updatedInput + permissionDecision

    func testParsePreToolUpdatedInputObject() throws {
        let json = """
        {"permissionDecision":"allow","updatedInput":{"path":"/tmp/x","force":true}}
        """
        let parsed = HookDispatcher.parsePreToolHookJSON(json)
        XCTAssertEqual(parsed?.allow, true)
        XCTAssertEqual(parsed?.permissionDecision, "allow")
        let raw = try XCTUnwrap(parsed?.updatedInputJSON)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["path"] as? String, "/tmp/x")
        XCTAssertEqual(obj["force"] as? Bool, true)
    }

    func testParsePreToolUpdatedInputJSONStringAndSnakeCase() throws {
        let json = """
        {"updated_input":"{\\"cmd\\":\\"ls\\"}","permissionDecision":"ask"}
        """
        let parsed = HookDispatcher.parsePreToolHookJSON(json)
        XCTAssertEqual(parsed?.allow, true, "ask is not deny on the structured path")
        XCTAssertEqual(parsed?.permissionDecision, "ask")
        let raw = try XCTUnwrap(parsed?.updatedInputJSON)
        XCTAssertTrue(raw.contains("ls"), raw)
        // Old HookDecision path has no `ask` — must not deny.
        XCTAssertNil(HookDispatcher.parseDecisionJSON(json))
    }

    func testParsePreToolHookSpecificOutputUpdatedInput() throws {
        let json = """
        {"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"x":1},"additionalContext":"rewrote"}}
        """
        let parsed = HookDispatcher.parsePreToolHookJSON(json)
        XCTAssertEqual(parsed?.allow, true)
        XCTAssertEqual(parsed?.permissionDecision, "allow")
        XCTAssertEqual(parsed?.additionalContext, "rewrote")
        let raw = try XCTUnwrap(parsed?.updatedInputJSON)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["x"] as? Int, 1)
    }

    func testParsePreToolPermissionDeny() {
        let json = """
        {"permissionDecision":"deny","permissionDecisionReason":"blocked by policy"}
        """
        let parsed = HookDispatcher.parsePreToolHookJSON(json)
        XCTAssertEqual(parsed?.allow, false)
        XCTAssertEqual(parsed?.permissionDecision, "deny")
        XCTAssertEqual(parsed?.message, "blocked by policy")
    }

    // MARK: - Exit 2 / decision:block still deny

    func testExit2DenyUnchangedOnOldAndDetailedPaths() {
        let old = HookDispatcher.interpretCommandOutput(
            exitCode: 2,
            stdout: "bad command",
            stderr: "",
            hookName: "block",
            toolName: "run_shell"
        )
        XCTAssertFalse(old.allow)
        XCTAssertTrue(old.message?.contains("bad command") == true, old.message ?? "")

        let pre = HookDispatcher.interpretPreToolOutput(
            exitCode: 2,
            stdout: "bad command",
            stderr: "",
            hookName: "block",
            toolName: "run_shell"
        )
        XCTAssertFalse(pre.allow)
        XCTAssertEqual(pre.permissionDecision, "deny")

        let stop = HookDispatcher.interpretStopOutput(
            exitCode: 2,
            stdout: "bad command",
            stderr: "",
            hookName: "block"
        )
        XCTAssertFalse(stop.allow)
        XCTAssertFalse(stop.shouldContinue)
    }

    func testDecisionBlockStillDeniesOnHookDecisionPath() {
        let grok = HookDispatcher.parseDecisionJSON(
            #"{"decision":"block","reason":"nope"}"#)
        XCTAssertEqual(grok?.allow, false)
        XCTAssertEqual(grok?.message, "nope")

        let stop = HookDispatcher.parseStopHookJSON(
            #"{"decision":"block","reason":"nope"}"#)
        XCTAssertEqual(stop?.allow, false)
        XCTAssertEqual(stop?.shouldContinue, false)
    }

    // MARK: - Old HookDecision path unchanged

    func testOldHookDecisionPathUnchanged() {
        let grokDeny = HookDispatcher.parseDecisionJSON(
            #"{"decision":"deny","reason":"no rm -rf"}"#)
        XCTAssertEqual(grokDeny?.allow, false)
        XCTAssertEqual(grokDeny?.message, "no rm -rf")

        let claudeDeny = HookDispatcher.parseDecisionJSON(
            #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"blocked"}}"#
        )
        XCTAssertEqual(claudeDeny?.allow, false)
        XCTAssertEqual(claudeDeny?.message, "blocked")

        let allow = HookDispatcher.parseDecisionJSON(#"{"decision":"allow"}"#)
        XCTAssertEqual(allow?.allow, true)
        XCTAssertNil(allow?.message)

        let noisy = """
        hook starting
        {"decision":"deny","reason":"from-embedded"}
        done
        """
        XCTAssertEqual(HookDispatcher.parseDecisionJSON(noisy)?.allow, false)
        XCTAssertEqual(HookDispatcher.parseDecisionJSON(noisy)?.message, "from-embedded")

        let failOpen = HookDispatcher.interpretCommandOutput(
            exitCode: 1, stdout: "", stderr: "oops", hookName: "x", toolName: "run_shell")
        XCTAssertTrue(failOpen.allow)
    }

    // MARK: - Live command runners (detailed APIs wrap old ones)

    func testStopDetailedContinueFromCommand() throws {
        let script = hooks.appendingPathComponent("stop-continue.sh")
        try """
        #!/bin/sh
        echo '{"continue":true,"additionalContext":"always run tests"}'
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "stop-continue.sh"]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let detailed = HookDispatcher.stopDetailed(reason: "finished", projectRoot: root)
        XCTAssertTrue(detailed.allow)
        XCTAssertTrue(detailed.shouldContinue)
        XCTAssertEqual(detailed.additionalContext, "always run tests")
        XCTAssertTrue(HookDispatcher.shouldContinueAfterStop(detailed, continuationCount: 0))

        // Old wrapper still reports allow (continue is not a deny).
        let old = HookDispatcher.stop(reason: "finished", projectRoot: root)
        XCTAssertTrue(old.allow)
    }

    func testPreToolDetailedUpdatedInputFromCommand() throws {
        let script = hooks.appendingPathComponent("rewrite.sh")
        try """
        #!/bin/sh
        echo '{"permissionDecision":"allow","updatedInput":{"path":"/safe"},"additionalContext":"rewrote path"}'
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "read_file",
                        "hooks": [["type": "command", "command": "rewrite.sh"]]
                    ]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let detailed = HookDispatcher.preToolDetailed(
            toolName: "read_file",
            argumentsSummary: #"{"path":"/etc/passwd"}"#,
            projectRoot: root)
        XCTAssertTrue(detailed.allow)
        XCTAssertEqual(detailed.permissionDecision, "allow")
        XCTAssertEqual(detailed.additionalContext, "rewrote path")
        let raw = try XCTUnwrap(detailed.updatedInputJSON)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["path"] as? String, "/safe")

        let old = HookDispatcher.preTool(
            toolName: "read_file",
            argumentsSummary: #"{"path":"/etc/passwd"}"#,
            projectRoot: root)
        XCTAssertTrue(old.allow)
    }

    func testPreToolExit2StillDeniesViaWrapper() throws {
        let script = hooks.appendingPathComponent("deny.sh")
        try "#!/bin/sh\nexit 2\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config: [String: Any] = [
            "pre": [
                ["matcher": "run_shell", "type": "command", "command": "deny.sh"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        let old = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "rm -rf /", projectRoot: root)
        XCTAssertFalse(old.allow, old.message ?? "")

        let detailed = HookDispatcher.preToolDetailed(
            toolName: "run_shell", argumentsSummary: "rm -rf /", projectRoot: root)
        XCTAssertFalse(detailed.allow)
        XCTAssertEqual(detailed.permissionDecision, "deny")

        let other = HookDispatcher.preTool(
            toolName: "read_file", argumentsSummary: "x", projectRoot: root)
        XCTAssertTrue(other.allow)
    }

    // MARK: - Config: PermissionRequest / PostToolUseFailure

    func testParsePermissionRequestAndPostToolUseFailureConfig() {
        let json: [String: Any] = [
            "hooks": [
                "PermissionRequest": [
                    [
                        "matcher": "run_shell",
                        "hooks": [["type": "command", "command": "ask.sh"]]
                    ]
                ],
                "PostToolUseFailure": [
                    ["hooks": [["type": "command", "command": "fail.sh"]]]
                ]
            ]
        ]
        let cfg = HookDispatcher.parseConfigJSON(json)
        XCTAssertEqual(cfg.permissionRequest.count, 1)
        XCTAssertEqual(cfg.permissionRequest[0].matcher, "run_shell")
        XCTAssertEqual(cfg.permissionRequest[0].handlers[0].command, "ask.sh")
        XCTAssertEqual(cfg.postToolUseFailure.count, 1)
        XCTAssertEqual(cfg.postToolUseFailure[0].handlers[0].command, "fail.sh")
        XCTAssertEqual(HookDispatcher.eventPermissionRequest, "PermissionRequest")
        XCTAssertEqual(HookDispatcher.eventPostToolUseFailure, "PostToolUseFailure")
    }
}
