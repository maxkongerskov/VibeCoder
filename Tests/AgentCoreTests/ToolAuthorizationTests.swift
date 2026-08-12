//
//  ToolAuthorizationTests.swift
//
//  Authorization pipeline + Plan mode gates (shipped path via ToolRegistry).
//

import XCTest
@testable import AgentCore

final class ToolAuthorizationTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await RememberedGrants.shared.clear()
    }

    private func ctx(
        mode: ExecutionMode? = .yolo,
        safe: SafeModeConfig? = nil,
        root: URL? = nil,
        reviewer: PatchReviewer? = nil,
        auth: AuthorizationConfig = .empty,
        conversationID: UUID = UUID(),
        planExited: Bool = false
    ) -> ToolContext {
        ToolContext(
            projectRoot: root ?? FileManager.default.temporaryDirectory,
            safeMode: safe,
            patchReviewer: reviewer,
            conversationID: conversationID,
            executionMode: mode,
            authorization: auth,
            planModeExited: planExited
        )
    }

    // MARK: - Matrix

    func testDenyRuleBlocksEvenInYolo() async {
        let auth = AuthorizationConfig(rules: [
            .init(kind: .deny, toolName: "write_file")
        ], useInlineRememberedOnly: true)
        let context = ctx(mode: .yolo, auth: auth)
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "write_file",
                arguments: ToolArguments(dictionary: [
                    "path": FileManager.default.temporaryDirectory
                        .appendingPathComponent("deny-\(UUID().uuidString).txt").path,
                    "content": "x",
                ]),
                context: context)
            XCTFail("deny rule must block")
        } catch let e as ToolError {
            guard case .permissionDenied = e else { return XCTFail("\(e)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testDangerousShellDeniedInYolo() async {
        let context = ctx(mode: .yolo)
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "run_shell",
                arguments: ToolArguments(dictionary: ["command": "rm -rf /tmp/agentos-should-not"]),
                context: context)
            XCTFail("dangerous shell must not auto-run")
        } catch let e as ToolError {
            guard case .permissionDenied = e else { return XCTFail("\(e)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testSafeBashAllowedInPlanMode() async throws {
        let context = ctx(mode: .plan)
        let result = try await ToolRegistry.shared.execute(
            name: "run_shell",
            arguments: ToolArguments(dictionary: ["command": "echo plan-ok"]),
            context: context)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("plan-ok") || result.content.contains("exit 0"),
                      result.content)
    }

    func testMutatingShellDeniedInPlanMode() async {
        let context = ctx(mode: .plan)
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "run_shell",
                arguments: ToolArguments(dictionary: ["command": "touch /tmp/plan-mutate-\(UUID().uuidString)"]),
                context: context)
            XCTFail("mutating shell blocked in plan")
        } catch let e as ToolError {
            guard case .permissionDenied = e else { return XCTFail("\(e)") }
            XCTAssertTrue("\(e)".lowercased().contains("plan"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testPlanModeAllowsWriteToSessionPlanFile() async throws {
        let convo = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let planURL = ToolAuthorization.sessionPlanURL(
            workingDirectory: root, conversationID: convo)
        let context = ctx(mode: .plan, root: root, conversationID: convo)

        let result = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": planURL.path,
                "content": "# Plan\n- step 1\n",
            ]),
            context: context)
        XCTAssertFalse(result.isError, result.content)
        let written = try String(contentsOf: planURL, encoding: .utf8)
        XCTAssertTrue(written.contains("step 1"))
    }

    func testPlanModeDeniesWriteOutsidePlanFile() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-plan-out-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("src.swift")
        let context = ctx(mode: .plan, root: root)
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "write_file",
                arguments: ToolArguments(dictionary: [
                    "path": outside.path,
                    "content": "let x = 1",
                ]),
                context: context)
            XCTFail("must deny")
        } catch let e as ToolError {
            guard case .permissionDenied = e else { return XCTFail("\(e)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testPlanModeExitedAllowsEdit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.swift")
        let context = ctx(mode: .plan, root: root, planExited: true)
        let result = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": file.path,
                "content": "ok",
            ]),
            context: context)
        XCTAssertFalse(result.isError, result.content)
    }

    func testRememberedNeverBlocks() async {
        // Isolated project root so we don't poison other tests that write
        // under FileManager.temporaryDirectory.
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-grant-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let key = GrantKey(projectKey: projectRoot.path, toolName: "write_file")
        await RememberedGrants.shared.remember(.never, for: key)
        let context = ctx(mode: .yolo, root: projectRoot)
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "write_file",
                arguments: ToolArguments(dictionary: [
                    "path": projectRoot
                        .appendingPathComponent("n-\(UUID().uuidString).txt").path,
                    "content": "x",
                ]),
                context: context)
            XCTFail("remembered never must block")
        } catch let e as ToolError {
            guard case .permissionDenied = e else { return XCTFail("\(e)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testSafeBashHelpers() {
        XCTAssertTrue(SafeBash.isReadOnlyCommand("ls -la"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("git status && git diff"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("ls && rm -rf /tmp/x"))
        XCTAssertTrue(SafeBash.isDangerous("rm -rf /"))
        XCTAssertTrue(SafeBash.isDangerous("git push --force origin main"))
        XCTAssertFalse(SafeBash.isDangerous("git status"))
    }

    func testAskModeWithoutReviewerDeniesWrite() async {
        let context = ctx(mode: .build, reviewer: nil)
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "write_file",
                arguments: ToolArguments(dictionary: [
                    "path": FileManager.default.temporaryDirectory
                        .appendingPathComponent("ask-\(UUID().uuidString).txt").path,
                    "content": "no",
                ]),
                context: context)
            XCTFail("ask without reviewer should deny")
        } catch let e as ToolError {
            guard case .permissionDenied = e else { return XCTFail("\(e)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    /// Wave C: Safe Mode must not false-deny SafeBash RO chains on `&&`.
    func testPlanSafeModeAllowsReadOnlyShellChains() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-ro-chain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let safe = SafeModeConfig(
            allowedPathPrefixes: [root.path],
            allowedShellPrefixes: ["ls"] // deliberately narrow — RO chain should bypass prefix list
        )
        let context = ctx(mode: .plan, safe: safe, root: root)
        let result = try await ToolRegistry.shared.execute(
            name: "run_shell",
            arguments: ToolArguments(dictionary: ["command": "git status && git diff"]),
            context: context)
        // May fail if not a git repo — must NOT be permission denied for Safe Mode meta.
        if result.isError {
            XCTAssertFalse(
                result.content.lowercased().contains("metacharacter")
                    || result.content.lowercased().contains("safe mode"),
                result.content)
        }
    }

    func testDurableGrantClearDoesNotResurrect() async {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("grant-clear-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let key = GrantKey(projectKey: projectRoot.path, toolName: "write_file")
        await RememberedGrants.shared.remember(.never, for: key)
        let before = await RememberedGrants.shared.decision(for: key)
        XCTAssertEqual(before, .never)
        await RememberedGrants.shared.clear(projectKey: projectRoot.path)
        let afterMem = await RememberedGrants.shared.decision(for: key)
        let afterDisk = await DurableGrantStore.shared.decision(for: key)
        XCTAssertNil(afterMem)
        // Durable must also be gone so ToolRegistry hydrate cannot resurrect.
        XCTAssertNil(afterDisk)
    }

    // MARK: - Wave C2

    func testFingerprintCoversFullChainNotJustFirstSegment() {
        // Always on plain `git status` must NOT match a chained command.
        let plain = RememberedGrants.fingerprint(command: "git status")
        let chained = RememberedGrants.fingerprint(command: "git status && npm install evil")
        XCTAssertEqual(plain, "git status")
        XCTAssertNotEqual(plain, chained, "multi-segment Always must not share fingerprint with head-only")
        XCTAssertTrue(chained.contains("git status") && chained.contains("npm"), chained)

        // Wrappers still peel within each segment.
        let wrapped = RememberedGrants.fingerprint(command: "env FOO=1 git status && git log")
        XCTAssertEqual(wrapped, "git status && git log")

        let d = RememberedGrants.fingerprint(command: "npm run build -- --watch")
        XCTAssertTrue(d.contains("npm") && d.contains("run") && d.contains("build"), d)
    }

    func testDurablePersistErrorFlagClearsOnSuccess() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-c2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("durable-grants.json")
        let store = DurableGrantStore(fileURL: url)
        let key = GrantKey(projectKey: "/tmp/proj-c2", toolName: "run_shell", commandFingerprint: "git status")
        await store.remember(.allow, for: key)
        let ok = await store.lastPersistSucceeded()
        let err = await store.lastPersistError()
        XCTAssertTrue(ok, err ?? "nil")
        let round = await store.decision(for: key)
        XCTAssertEqual(round, .allow)
    }
}
