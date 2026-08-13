//
//  BugHuntSafetyToolsCoreTests.swift
//
//  Verification-first hunt: Tools-core + Safety invariants.
//  Each test asserts the *safe* contract; a failure is a confirmed bug.
//

import XCTest
@testable import AgentCore

final class BugHuntSafetyToolsCoreTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await RememberedGrants.shared.clear()
        await HunkTracker.shared.clear()
    }

    override func tearDown() async throws {
        await RememberedGrants.shared.clear()
        await HunkTracker.shared.clear()
    }

    // MARK: - Helpers

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-stc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func ctx(
        root: URL,
        mode: ExecutionMode? = .yolo,
        reviewer: PatchReviewer? = nil,
        remembered: [GrantKey: GrantDecision] = [:],
        conversationID: UUID = UUID()
    ) -> ToolContext {
        ToolContext(
            projectRoot: root,
            patchReviewer: reviewer,
            conversationID: conversationID,
            executionMode: mode,
            authorization: AuthorizationConfig(
                remembered: remembered,
                useInlineRememberedOnly: true
            )
        )
    }

    // MARK: - PathConfinement / RememberedGrants

    /// ToolAuthorization: remembered allow "still subject to confinement".
    /// Tool-level Always for write_file must not authorize arbitrary FS writes.
    func testToolLevelAlwaysAllowDoesNotBypassWorkspaceConfinement() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-escape-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }

        let grant = GrantKey(projectKey: root.path, toolName: "write_file")
        let remembered: [GrantKey: GrantDecision] = [grant: .allow]
        let context = ctx(root: root, mode: .yolo, remembered: remembered)

        let outcome = ToolAuthorization.evaluate(
            toolName: "write_file",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "path": outside.path,
                "content": "pwned",
            ]),
            context: context,
            config: context.authorization,
            remembered: remembered
        )
        if case .allow = outcome {
            XCTFail("tool-level Always must not skip path confinement, got \(outcome)")
        } else if case .ask = outcome {
            XCTFail("tool-level Always must not skip path confinement, got \(outcome)")
        }

        do {
            let result = try await ToolRegistry.shared.execute(
                name: "write_file",
                arguments: ToolArguments(dictionary: [
                    "path": outside.path,
                    "content": "pwned",
                ]),
                context: context)
            if !result.isError {
                XCTFail("execute must not write outside the project via tool-level grant: \(result.content)")
            }
        } catch is ToolError {
            // expected deny
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.path),
            "write_file body still confines via __path__ grants")

        // memory is .mutates, honors a `path` override, and does not call
        // requireInsideWorkspace — evaluate() is the only gate.
        let memGrant = GrantKey(projectKey: root.path, toolName: "memory")
        let memRemembered: [GrantKey: GrantDecision] = [memGrant: .allow]
        let memCtx = ctx(root: root, mode: .yolo, remembered: memRemembered)
        let memOutside = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-memory-escape-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: memOutside) }
        let memOutcome = ToolAuthorization.evaluate(
            toolName: "memory",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "action": "write_handoff",
                "path": memOutside.path,
                "summary": "escaped",
            ]),
            context: memCtx,
            config: memCtx.authorization,
            remembered: memRemembered
        )
        if case .allow = memOutcome {
            XCTFail("tool-level Always for memory must not skip confinement, got \(memOutcome)")
        }
        do {
            let result = try await ToolRegistry.shared.execute(
                name: "memory",
                arguments: ToolArguments(dictionary: [
                    "action": "write_handoff",
                    "path": memOutside.path,
                    "summary": "escaped",
                ]),
                context: memCtx)
            if !result.isError {
                XCTFail("memory must not write outside the project: \(result.content)")
            }
        } catch is ToolError {
            // expected
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: memOutside.path),
            "tool-level Always must not let memory write outside the workspace")
    }

    /// Path-specific Never is supposed to win over broader allows.
    func testPathNeverOverridesToolLevelAllow() {
        let projectKey = "/tmp/bughunt-proj"
        let target = URL(fileURLWithPath: "/tmp/bughunt-never-file.txt")
        let toolAllow = GrantKey(projectKey: projectKey, toolName: "write_file")
        let pathNever = GrantKey(
            projectKey: projectKey,
            toolName: RememberedGrants.pathGrantToolName,
            commandFingerprint: PathConfinement.pathGrantFingerprint(target)
        )
        let grants: [GrantKey: GrantDecision] = [
            toolAllow: .allow,
            pathNever: .never,
        ]
        XCTAssertFalse(
            RememberedGrants.allowsPath(
                target, toolName: "write_file", projectKey: projectKey, grants: grants),
            "path-specific Never must override tool-level Always")
    }

    /// Non-existent directory fingerprints must not widen to the parent tree.
    func testDirectoryFingerprintOfMissingDirDoesNotGrantParent() {
        let missing = URL(
            fileURLWithPath: "/tmp/bughunt-missing-dir-\(UUID().uuidString)",
            isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let fp = PathConfinement.directoryGrantFingerprint(missing)
        let expected = "dir:" + SafeModeConfig.normalizePath(missing.path)
        XCTAssertEqual(
            fp, expected,
            "missing directory grant widened to parent: \(fp)")

        let sibling = URL(fileURLWithPath: "/tmp/bughunt-unrelated-\(UUID().uuidString).txt")
        let grants: [GrantKey: GrantDecision] = [
            GrantKey(
                projectKey: "/p",
                toolName: RememberedGrants.pathGrantToolName,
                commandFingerprint: fp
            ): .allow
        ]
        XCTAssertFalse(
            RememberedGrants.allowsPath(
                sibling, toolName: "write_file", projectKey: "/p", grants: grants),
            "parent-widened dir grant must not cover unrelated /tmp files")
    }

    // MARK: - SafeBash allowlist holes

    func testAbsoluteRmIsDangerous() {
        XCTAssertTrue(
            SafeBash.isDangerous("/bin/rm important.file"),
            "/bin/rm must match the rm dangerous prefix")
        XCTAssertTrue(
            SafeBash.isDangerous("/usr/bin/chmod 777 secret"),
            "/usr/bin/chmod must match the chmod dangerous prefix")
        XCTAssertTrue(
            SafeBash.isDangerous("/bin/kill -9 1"),
            "/bin/kill must match the kill dangerous prefix")
    }

    func testAssignmentPrefixDoesNotHideRm() {
        XCTAssertTrue(
            SafeBash.isDangerous("FOO=1 rm important.file"),
            "VAR=value rm must still be dangerous")
        XCTAssertTrue(
            SafeBash.isDangerous("GIT_DIR=/tmp/x git push origin main"),
            "GIT_DIR=… git push must still be dangerous")
    }

    func testGitGlobalFlagsDoNotHidePush() {
        XCTAssertTrue(
            SafeBash.isDangerous("git -C /tmp/other push origin main"),
            "git -C <dir> push must be dangerous")
        XCTAssertTrue(
            SafeBash.isDangerous("git --git-dir=/tmp/other.git push origin main"),
            "git --git-dir=… push must be dangerous")
    }

    func testNiceNumericArgDoesNotHideRm() {
        XCTAssertTrue(
            SafeBash.isDangerous("nice -n 19 rm important.file"),
            "nice -n N rm must still be dangerous")
    }

    func testDotSourceIsDangerousLikeSource() {
        XCTAssertTrue(
            SafeBash.isDangerous("source ./evil.sh"),
            "control: source is dangerous")
        XCTAssertTrue(
            SafeBash.isDangerous(". ./evil.sh"),
            ". ./script is the source builtin and must be dangerous")
        XCTAssertTrue(
            SafeBash.isDangerous(". evil.sh"),
            ". script must be dangerous")
    }

    func testCommandSubstitutionRmIsDangerous() {
        XCTAssertTrue(
            SafeBash.isDangerous("echo $(rm important.file)"),
            "rm hidden in $() must be dangerous (same class as bash -c)")
        XCTAssertTrue(
            SafeBash.isDangerous("echo `rm important.file`"),
            "rm hidden in backticks must be dangerous")
    }

    func testYoloDoesNotAutoAllowDisguisedDangerousShell() {
        let root = FileManager.default.temporaryDirectory
        let context = ctx(root: root, mode: .yolo)
        let disguised = [
            "/bin/rm /tmp/bughunt-should-not-delete",
            "FOO=1 rm /tmp/bughunt-should-not-delete",
            "git -C /tmp push origin main",
            "echo $(rm /tmp/bughunt-should-not-delete)",
        ]
        for cmd in disguised {
            let outcome = ToolAuthorization.evaluate(
                toolName: "run_shell",
                permission: .executes,
                arguments: ToolArguments(dictionary: ["command": cmd]),
                context: context
            )
            if case .allow = outcome {
                XCTFail("yolo must not auto-allow disguised dangerous shell: \(cmd)")
            }
        }
    }

    // MARK: - ToolAuthorization / PermissionRules

    /// Comment: "deny wins, then ask". First-match ask before deny must not win.
    func testDenyRuleWinsOverEarlierAskRule() {
        let root = FileManager.default.temporaryDirectory
        let auth = AuthorizationConfig(rules: [
            .init(kind: .ask, toolName: "run_shell"),
            .init(kind: .deny, toolName: "run_shell", commandContains: "rm -rf"),
        ], useInlineRememberedOnly: true)
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: [
                "command": "rm -rf /tmp/bughunt-rule-order"
            ]),
            context: ctx(root: root, mode: .yolo, remembered: [:]),
            config: auth
        )
        guard case .deny = outcome else {
            XCTFail("deny must win over earlier ask, got \(outcome)")
            return
        }
    }

    func testPermissionsFileAskDoesNotMaskAlwaysDeny() {
        let json = """
        {
          "rules": [ { "kind": "ask", "tool": "run_shell" } ],
          "alwaysDeny": [ { "tool": "run_shell", "commandPrefix": "curl" } ]
        }
        """
        let snap = PermissionRules.parsePermissionsJSON(string: json, projectKey: "/p")
        let auth = PermissionRules.merge(into: .empty, snapshot: snap)
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: ["command": "curl http://evil.example"]),
            context: ctx(root: URL(fileURLWithPath: "/p"), mode: .yolo),
            config: auth,
            remembered: snap.grants
        )
        guard case .deny = outcome else {
            XCTFail("alwaysDeny/curl must deny even when an ask rule is listed first, got \(outcome)")
            return
        }
    }

    /// Plan mode: only the session plan file may be mutated. move_file
    /// must not treat source=plan as a license to rewrite any other path.
    func testPlanModeMoveFileCannotMutateNonPlanDestination() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let convo = UUID()
        let planURL = ToolAuthorization.sessionPlanURL(
            workingDirectory: root, conversationID: convo)
        try FileManager.default.createDirectory(
            at: planURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# plan\n".write(to: planURL, atomically: true, encoding: .utf8)
        let dest = root.appendingPathComponent("not-the-plan.swift")
        try "keep-me".write(to: dest, atomically: true, encoding: .utf8)

        let context = ctx(root: root, mode: .plan, conversationID: convo)
        let args = ToolArguments(dictionary: [
            "source": planURL.path,
            "destination": dest.path,
            "overwrite": true,
        ])

        let outcome = ToolAuthorization.evaluate(
            toolName: "move_file",
            permission: .mutates,
            arguments: args,
            context: context
        )
        if case .allow = outcome {
            XCTFail("plan mode must deny move_file off the session plan, got \(outcome)")
        }

        do {
            let result = try await ToolRegistry.shared.execute(
                name: "move_file", arguments: args, context: context)
            if !result.isError {
                XCTFail("plan mode execute must not move the plan onto another project file: \(result.content)")
            }
        } catch is ToolError {
            // expected
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: planURL.path),
            "session plan must remain in place")
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "keep-me")
    }

    /// Ask mode + reviewer: only MutationReview-aware mutators may pass through.
    /// create_directory is .mutates and does not call MutationReview.
    func testAskModeCreateDirectoryDoesNotSilentAllowWithReviewer() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let reviewer = PatchReviewer { _ in .rejectAll }
        let context = ctx(root: root, mode: .build, reviewer: reviewer)
        let dir = root.appendingPathComponent("should-not-mkdir-\(UUID().uuidString)")

        let outcome = ToolAuthorization.evaluate(
            toolName: "create_directory",
            permission: .mutates,
            arguments: ToolArguments(dictionary: ["path": dir.path]),
            context: context
        )
        if case .allow = outcome {
            XCTFail("Ask mode must not silent-allow create_directory just because a reviewer exists")
        }

        do {
            let result = try await ToolRegistry.shared.execute(
                name: "create_directory",
                arguments: ToolArguments(dictionary: ["path": dir.path]),
                context: context)
            if !result.isError {
                XCTFail("create_directory must not succeed without Ask confirmation, got \(result.content)")
            }
        } catch is ToolError {
            // expected deny
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.path),
            "Ask+reject-all must not create the directory")
    }

    // MARK: - RememberedGrants fingerprint

    func testShellFingerprintDoesNotDropTokensBeyondEight() {
        let allowed = "npm install a b c d e f g extra-ok"
        let smuggled = "npm install a b c d e f g EVILPKG"
        let fpA = RememberedGrants.fingerprint(command: allowed)
        let fpB = RememberedGrants.fingerprint(command: smuggled)
        XCTAssertNotEqual(
            fpA, fpB,
            "8-token cap lets Always on a long command also match extra args: \(fpA)")

        let root = FileManager.default.temporaryDirectory
        let key = GrantKey(
            projectKey: root.path,
            toolName: "run_shell",
            commandFingerprint: fpA
        )
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: ["command": smuggled]),
            context: ctx(root: root, mode: .edit),
            config: AuthorizationConfig(
                remembered: [key: .allow],
                useInlineRememberedOnly: true),
            remembered: [key: .allow]
        )
        if case .allow = outcome {
            XCTFail("Always on \(allowed) must not authorize \(smuggled)")
        }
    }

    // MARK: - HunkTracker

    func testRejectOfCreatedFileRemovesTheFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-hunk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("created.txt")
        try "brand-new".write(to: file, atomically: true, encoding: .utf8)

        let hunk = TrackedHunk(
            conversationID: UUID(),
            path: file.path,
            originalContent: "",
            updatedContent: "brand-new")
        await HunkTracker.shared.record(hunk)
        let ok = try await HunkTracker.shared.reject(id: hunk.id)
        XCTAssertTrue(ok, "reject of a create hunk should succeed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "undoing a create must delete the file, not leave an empty stub")
    }

    // MARK: - SessionReadTracker

    func testSessionReadPathsAreNormalizedBeforeContains() async {
        let convo = UUID()
        let weird = "/tmp/bughunt-rbe/../bughunt-rbe-target-\(UUID().uuidString)"
        let canon = SafeModeConfig.normalizePath(weird)
        XCTAssertNotEqual(weird, canon, "precondition: seed must differ from normalized form")

        let hit = await SessionReadTracker.shared.hasSessionRead(
            path: canon,
            conversationID: convo,
            sessionReadPaths: [weird])
        XCTAssertTrue(
            hit,
            "sessionReadPaths entries must be normalized; raw \(weird) vs query \(canon)")
    }

    // MARK: - BackgroundJobManager

    func testTakePendingCompletionsDoesNotStealOtherConversationNilsAsScoped() async throws {
        await BackgroundJobManager.shared.cleanup()

        let convoA = UUID()
        let idNil = try await BackgroundJobManager.shared.registerSubagent(
            description: "unscoped", conversationID: nil)
        await BackgroundJobManager.shared.completeSubagent(
            id: idNil, output: "nil-job", failed: false)

        let stolen = await BackgroundJobManager.shared.takePendingCompletions(
            conversationID: convoA)
        XCTAssertFalse(
            stolen.contains { $0.taskId == idNil },
            "draining conversation A must not take nil-conversation completions")
        let leftover = await BackgroundJobManager.shared.takePendingCompletions()
        XCTAssertTrue(
            leftover.contains { $0.taskId == idNil },
            "unscoped completion should remain until an unscoped/all drain")
        await BackgroundJobManager.shared.cleanup()
    }
}
