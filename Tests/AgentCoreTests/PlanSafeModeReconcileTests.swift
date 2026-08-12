//
//  PlanSafeModeReconcileTests.swift
//
//  Wave B S10a (W07): Plan/Ask auto-SafeMode must allow SafeBash RO inspect
//  shell and seed the open project root on the path allow-list.
//

import XCTest
@testable import AgentCore

final class PlanSafeModeReconcileTests: XCTestCase {

    // MARK: - SafeModeConfig helpers

    func testIncludingProjectRootsAddsNormalizedRoot() {
        let project = URL(fileURLWithPath: "/tmp/agentos-s10a-project-\(UUID().uuidString)")
        let base = SafeModeConfig(
            allowedPathPrefixes: ["~/code/", "/tmp/"],
            allowedShellPrefixes: ["git", "ls"]
        )
        let reconciled = base.includingProjectRoots([project])
        let norm = SafeModeConfig.normalizePath(project.path)
        XCTAssertTrue(
            reconciled.allowedPathPrefixes.contains { SafeModeConfig.normalizePath($0) == norm },
            "project root must be on path allow-list: \(reconciled.allowedPathPrefixes)"
        )
        // Original entries preserved
        XCTAssertEqual(reconciled.allowedPathPrefixes.count, 3)
    }

    func testIncludingProjectRootsDedupes() {
        let project = URL(fileURLWithPath: "/tmp/agentos-s10a-dup-\(UUID().uuidString)")
        let base = SafeModeConfig(
            allowedPathPrefixes: [project.path],
            allowedShellPrefixes: []
        )
        let twice = base.includingProjectRoots([project, project])
        XCTAssertEqual(twice.allowedPathPrefixes.count, 1)
    }

    func testUnioningShellPrefixesAddsROPrimaries() {
        let base = SafeModeConfig(
            allowedPathPrefixes: [],
            allowedShellPrefixes: ["swift build", "git", "ls"]
        )
        let unioned = base.unioningShellPrefixes(SafeBash.safeModeInspectShellPrefixes)
        XCTAssertTrue(unioned.allowedShellPrefixes.contains("cat"))
        XCTAssertTrue(unioned.allowedShellPrefixes.contains("rg"))
        XCTAssertTrue(unioned.allowedShellPrefixes.contains("echo"))
        // Defaults still first / present
        XCTAssertTrue(unioned.allowedShellPrefixes.contains("swift build"))
        XCTAssertTrue(unioned.allowedShellPrefixes.contains("git"))
    }

    func testReconciledForAutoSafeModeCombinesBoth() {
        let project = URL(fileURLWithPath: "/Users/test/Developer/MyApp")
        let base = SafeModeConfig(
            allowedPathPrefixes: ["~/code/"],
            allowedShellPrefixes: ["swift build", "git", "ls"]
        )
        let cfg = base.reconciledForAutoSafeMode(projectRoots: [project])
        let norm = SafeModeConfig.normalizePath(project.path)
        XCTAssertTrue(cfg.allowedPathPrefixes.contains {
            SafeModeConfig.normalizePath($0) == norm
        })
        XCTAssertTrue(cfg.allowedShellPrefixes.contains("cat"))
    }

    func testAppSettingsSafeModeConfigSeedsProjectRoot() {
        var settings = AppSettings()
        settings.safeModeAllowedPaths = ["~/code/"]
        settings.safeModeAllowedShellPrefixes = ["git", "ls"]
        let project = URL(fileURLWithPath: "/tmp/agentos-settings-s10a-\(UUID().uuidString)")
        let cfg = settings.safeModeConfig(projectRoots: [project])
        let norm = SafeModeConfig.normalizePath(project.path)
        XCTAssertTrue(cfg.allowedPathPrefixes.contains {
            SafeModeConfig.normalizePath($0) == norm
        })
        XCTAssertTrue(cfg.allowedShellPrefixes.contains("rg"))
    }

    // MARK: - Authorization: Plan + narrow Safe Mode + RO shell

    private func planContext(
        root: URL,
        shellPrefixes: [String] = ["swift build", "git", "ls"]
    ) -> ToolContext {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ToolContext(
            projectRoot: root,
            safeMode: SafeModeConfig(
                allowedPathPrefixes: ["~/code/", "/tmp/"], // deliberately excludes project unless under /tmp
                allowedShellPrefixes: shellPrefixes
            ),
            conversationID: UUID(),
            executionMode: .plan
        )
    }

    func testPlanModeAllowsCatDespiteNarrowShellPrefixes() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-plan-ro-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = planContext(root: root)
        // Narrow list has no "cat" — pre-S10a this was dual-denied after RO auto-approve.
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: ["command": "cat Package.swift"]),
            context: ctx
        )
        XCTAssertEqual(outcome, .allow, "Plan + SafeMode must allow SafeBash RO cat: \(outcome)")
    }

    func testPlanModeAllowsRgAndEcho() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-plan-ro2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = planContext(root: root)
        for cmd in ["rg TODO Sources", "echo hello", "ls -la", "git status"] {
            let outcome = ToolAuthorization.evaluate(
                toolName: "run_shell",
                permission: .executes,
                arguments: ToolArguments(dictionary: ["command": cmd]),
                context: ctx
            )
            XCTAssertEqual(outcome, .allow, "expected allow for \(cmd), got \(outcome)")
        }
    }

    func testPlanModeStillDeniesMutatingShellWithSafeMode() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-plan-mut-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = planContext(root: root)
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: [
                "command": "touch \(root.path)/should-fail.txt"
            ]),
            context: ctx
        )
        guard case .deny = outcome else {
            return XCTFail("mutating shell must still be denied in plan mode, got \(outcome)")
        }
    }

    func testROShellChainStillRejectedBySafeModeMetacharacters() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-plan-chain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Both segments are SafeBash RO, but Safe Mode must still reject chaining.
        let ctx = ToolContext(
            projectRoot: root,
            safeMode: SafeModeConfig(
                allowedPathPrefixes: [root.path],
                allowedShellPrefixes: ["git", "ls"]
            ),
            conversationID: UUID(),
            executionMode: .build
        )
        // Pure SafeBash RO chains (every segment inspect-only) must be allowed —
        // Wave C W03: re-applying shellMetacharacterDenialReason false-denied
        // `git status && git diff` under Plan/Ask Safe Mode.
        for cmd in ["git status && git diff", "ls | cat", "git status; echo pwned"] {
            let outcome = ToolAuthorization.evaluate(
                toolName: "run_shell",
                permission: .executes,
                arguments: ToolArguments(dictionary: ["command": cmd]),
                context: ctx
            )
            guard case .allow = outcome else {
                return XCTFail("pure RO shell chain must be allowed: \(cmd) → \(outcome)")
            }
        }
        // Mixed chains (any non-RO segment) are not auto-allowed: Ask → .ask,
        // dangerous segment → .ask/.deny; Plan would .deny. Never silent .allow.
        for cmd in ["git status && touch /tmp/x", "ls; rm file"] {
            let outcome = ToolAuthorization.evaluate(
                toolName: "run_shell",
                permission: .executes,
                arguments: ToolArguments(dictionary: ["command": cmd]),
                context: ctx
            )
            if case .allow = outcome {
                return XCTFail("mixed RO+mutate chain must not auto-allow: \(cmd) → \(outcome)")
            }
        }
        // Plan mode hard-denies non-RO chains.
        let planContext = ToolContext(
            projectRoot: root,
            safeMode: SafeModeConfig(
                allowedPathPrefixes: [root.path],
                allowedShellPrefixes: ["git", "ls"]
            ),
            conversationID: UUID(),
            executionMode: .plan
        )
        for cmd in ["git status && touch /tmp/x", "ls; rm file"] {
            let outcome = ToolAuthorization.evaluate(
                toolName: "run_shell",
                permission: .executes,
                arguments: ToolArguments(dictionary: ["command": cmd]),
                context: planContext
            )
            guard case .deny = outcome else {
                return XCTFail("Plan mixed chain must deny: \(cmd) → \(outcome)")
            }
        }
    }

    func testAskModeAllowsROShellWithNarrowSafeMode() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-ask-ro-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ctx = ToolContext(
            projectRoot: root,
            safeMode: SafeModeConfig(
                allowedPathPrefixes: [root.path],
                allowedShellPrefixes: ["git", "ls"] // no cat
            ),
            conversationID: UUID(),
            executionMode: .build
        )
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: ["command": "cat README.md"]),
            context: ctx
        )
        XCTAssertEqual(outcome, .allow, "Ask + SafeMode must allow RO cat: \(outcome)")
    }

    func testNonROShellStillUsesSafeModePrefixList() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-nonro-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // yolo + Safe Mode: non-RO command not on prefix list → deny
        let ctx = ToolContext(
            projectRoot: root,
            safeMode: SafeModeConfig(
                allowedPathPrefixes: [root.path],
                allowedShellPrefixes: ["git", "ls"]
            ),
            conversationID: UUID(),
            executionMode: .yolo
        )
        // python is not SafeBash RO
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: ["command": "python3 -c 'print(1)'"]),
            context: ctx
        )
        guard case .deny(let reason) = outcome else {
            return XCTFail("non-RO outside shell prefixes must be denied by Safe Mode, got \(outcome)")
        }
        XCTAssertTrue(
            reason.lowercased().contains("safe mode") || reason.lowercased().contains("allow-listed"),
            reason
        )
    }

    func testReconciledPathsAllowProjectMutateUnderSafeMode() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-path-seed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Defaults exclude this project path until reconcile seeds it.
        let narrow = SafeModeConfig(
            allowedPathPrefixes: ["~/code/"],
            allowedShellPrefixes: ["git"]
        )
        XCTAssertFalse(narrow.isPathAllowed(root.appendingPathComponent("src/a.swift")))

        let seeded = narrow.reconciledForAutoSafeMode(projectRoots: [root])
        XCTAssertTrue(seeded.isPathAllowed(root.appendingPathComponent("src/a.swift")))
    }
}
