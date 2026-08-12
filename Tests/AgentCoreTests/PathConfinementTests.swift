//
//  PathConfinementTests.swift
//
//  Wave A #5: project/worktree path confinement even when Safe Mode is off.
//

import XCTest
@testable import AgentCore

final class PathConfinementTests: XCTestCase {

    private var projectRoot: URL!
    private var outsideFile: URL!

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        projectRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vc-path-confine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        outsideFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vc-path-escape-\(UUID().uuidString).txt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectRoot)
        try? FileManager.default.removeItem(at: outsideFile)
    }

    private func context(
        safeMode: SafeModeConfig? = nil,
        mode: ExecutionMode? = .yolo,
        root: URL? = nil,
        worktree: URL? = nil,
        reviewer: PatchReviewer? = nil,
        remembered: [GrantKey: GrantDecision] = [:]
    ) -> ToolContext {
        ToolContext(
            projectRoot: root ?? projectRoot,
            worktreeRoot: worktree,
            safeMode: safeMode,
            patchReviewer: reviewer,
            conversationID: UUID(),
            executionMode: mode,
            authorization: AuthorizationConfig(
                remembered: remembered,
                useInlineRememberedOnly: true
            )
        )
    }

    // MARK: - Helpers

    private func assertDenied(
        _ name: String,
        args: [String: Any],
        context: ToolContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await ToolRegistry.shared.execute(
                name: name,
                arguments: ToolArguments(dictionary: args),
                context: context)
            XCTFail("expected permissionDenied for \(name)", file: file, line: line)
        } catch let e as ToolError {
            guard case .permissionDenied = e else {
                XCTFail("expected permissionDenied, got \(e)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - Safe Mode off (nil)

    func testAbsolutePathOutsideProjectDeniedWhenSafeModeOff() async {
        let ctx = context(safeMode: nil, mode: .yolo)
        await assertDenied(
            "write_file",
            args: ["path": outsideFile.path, "content": "pwned"],
            context: ctx)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testTildePathOutsideProjectDeniedWhenSafeModeOff() async {
        let homeEscape = (NSHomeDirectory() as NSString)
            .appendingPathComponent("vc-path-confine-escape-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(atPath: homeEscape) }
        let tildePath = "~/" + (homeEscape as NSString).lastPathComponent
        // Only deny when the expanded path is outside project (home != projectRoot).
        let ctx = context(safeMode: nil, mode: .yolo)
        // Use full absolute under home via ~
        let fullTilde = homeEscape.replacingOccurrences(
            of: NSHomeDirectory(), with: "~")
        await assertDenied(
            "write_file",
            args: ["path": fullTilde, "content": "nope"],
            context: ctx)
        XCTAssertFalse(FileManager.default.fileExists(atPath: homeEscape),
                       "tilde path must not write outside project; tilde=\(fullTilde)")
        _ = tildePath
    }

    func testDotDotTraversalOutsideProjectDeniedWhenSafeModeOff() async {
        let ctx = context(safeMode: nil, mode: .yolo)
        // projectRoot/../../.../outside — resolve against base
        let escapeName = outsideFile.lastPathComponent
        let relativeEscape = "../../\(escapeName)"
        // From projectRoot, ../../ may not hit outsideFile; use a path that
        // standardizes outside the project via absolute after resolve.
        // Safer: absolute via many .. from a nested relative base.
        let nested = "subdir/../../../\(outsideFile.lastPathComponent)"
        // Actually resolvePath for relative joins base — use absolute for clarity
        // and a relative that walks out:
        let outViaDotDot = projectRoot
            .appendingPathComponent("..")
            .appendingPathComponent(outsideFile.lastPathComponent)
        await assertDenied(
            "write_file",
            args: ["path": outViaDotDot.path, "content": "x"],
            context: ctx)
        _ = relativeEscape
        _ = nested
    }

    func testRelativePathInsideProjectAllowedWhenSafeModeOff() async throws {
        let ctx = context(safeMode: nil, mode: .yolo)
        let result = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": "hello.txt",
                "content": "ok",
            ]),
            context: ctx)
        XCTAssertFalse(result.isError, result.content)
        let written = projectRoot.appendingPathComponent("hello.txt")
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "ok")
    }

    func testAbsolutePathInsideProjectAllowedWhenSafeModeOff() async throws {
        let target = projectRoot.appendingPathComponent("abs-inside.txt")
        let ctx = context(safeMode: nil, mode: .yolo)
        let result = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": target.path,
                "content": "inside",
            ]),
            context: ctx)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "inside")
    }

    // MARK: - Safe Mode on still works (stricter)

    func testSafeModeOnStillDeniesOutsideAllowList() async {
        let safe = SafeModeConfig(
            allowedPathPrefixes: [projectRoot.path],
            allowedShellPrefixes: []
        )
        let ctx = context(safeMode: safe, mode: .yolo)
        await assertDenied(
            "write_file",
            args: ["path": outsideFile.path, "content": "x"],
            context: ctx)
    }

    func testSafeModeOnAllowsInsideBothConfinementAndAllowList() async throws {
        let safe = SafeModeConfig(
            allowedPathPrefixes: [projectRoot.path],
            allowedShellPrefixes: []
        )
        let ctx = context(safeMode: safe, mode: .yolo)
        let result = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": "safe-ok.txt",
                "content": "yes",
            ]),
            context: ctx)
        XCTAssertFalse(result.isError, result.content)
    }

    // MARK: - Other mutating tools

    func testDeleteOutsideDenied() async {
        // Create outside file first
        try? "x".write(to: outsideFile, atomically: true, encoding: .utf8)
        let ctx = context(safeMode: nil, mode: .yolo)
        await assertDenied(
            "delete_file",
            args: ["path": outsideFile.path],
            context: ctx)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path),
                      "outside file must survive denied delete")
    }

    func testCreateDirectoryOutsideDenied() async {
        let outsideDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vc-mkdir-escape-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let ctx = context(safeMode: nil, mode: .yolo)
        await assertDenied(
            "create_directory",
            args: ["path": outsideDir.path],
            context: ctx)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideDir.path))
    }

    func testMoveDestinationOutsideDenied() async throws {
        let src = projectRoot.appendingPathComponent("move-src.txt")
        try "src".write(to: src, atomically: true, encoding: .utf8)
        let ctx = context(safeMode: nil, mode: .yolo)
        await assertDenied(
            "move_file",
            args: [
                "source": "move-src.txt",
                "destination": outsideFile.path,
            ],
            context: ctx)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testApplyPatchOutsideDenied() async {
        let patch = """
        --- a\(outsideFile.path)
        +++ b\(outsideFile.path)
        @@ -0,0 +1 @@
        +pwned
        """
        // UnifiedDiff may expect relative paths; also try with absolute in header
        let patch2 = """
        --- a/\(outsideFile.path)
        +++ b/\(outsideFile.path)
        @@ -0,0 +1 @@
        +pwned
        """
        let ctx = context(safeMode: nil, mode: .yolo)
        await assertDenied(
            "apply_patch",
            args: ["patch": patch2],
            context: ctx)
        _ = patch
    }

    // MARK: - Pure evaluate / PathConfinement unit

    func testEvaluateDeniesOutsideInYoloWithoutReviewer() {
        let ctx = context(safeMode: nil, mode: .yolo)
        let outcome = ToolAuthorization.evaluate(
            toolName: "write_file",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "path": outsideFile.path,
                "content": "x",
            ]),
            context: ctx
        )
        guard case .deny(let msg) = outcome else {
            return XCTFail("expected deny, got \(outcome)")
        }
        XCTAssertTrue(msg.lowercased().contains("outside"), msg)
    }

    func testEvaluateAsksOutsideInAskModeWithReviewer() {
        // PatchReviewer is a Sendable struct wrapping a closure, not a protocol.
        let reviewer = PatchReviewer { _ in .acceptAll }
        let ctx = context(safeMode: nil, mode: .build, reviewer: reviewer)
        let outcome = ToolAuthorization.evaluate(
            toolName: "write_file",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "path": outsideFile.path,
                "content": "x",
            ]),
            context: ctx
        )
        // build mode with reviewer may return ask from path confinement
        // before or after mode — either ask or allow-through-ask is OK;
        // must NOT silent-allow without confinement signal.
        switch outcome {
        case .deny(let msg):
            // Without reaching path ask first, build mode might ask for tool;
            // path confinement with reviewer returns ask
            XCTFail("unexpected hard deny with reviewer: \(msg)")
        case .ask(let msg):
            XCTAssertTrue(msg.lowercased().contains("outside") || msg.contains("approval"), msg)
        case .allow:
            // applyPlanAndSafeMode with reviewer returns ask for outside;
            // if allow, confinement failed
            XCTFail("must not silent-allow outside project write")
        }
    }

    func testRememberedPathGrantAllowsOutside() {
        // Build context first so projectKey matches evaluate's grant lookup.
        var pathKey = GrantKey(
            projectKey: "",
            toolName: "write_file",
            commandFingerprint: PathConfinement.pathGrantFingerprint(outsideFile)
        )
        let draft = context(safeMode: nil, mode: .yolo)
        pathKey = GrantKey(
            projectKey: RememberedGrants.projectKey(from: draft),
            toolName: "write_file",
            commandFingerprint: PathConfinement.pathGrantFingerprint(outsideFile)
        )
        let ctx = context(
            safeMode: nil,
            mode: .yolo,
            remembered: [pathKey: .allow]
        )
        // Recompute key against final ctx (same projectRoot → same key).
        pathKey = GrantKey(
            projectKey: RememberedGrants.projectKey(from: ctx),
            toolName: "write_file",
            commandFingerprint: PathConfinement.pathGrantFingerprint(outsideFile)
        )
        let outcome = ToolAuthorization.evaluate(
            toolName: "write_file",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "path": outsideFile.path,
                "content": "granted",
            ]),
            context: ctx,
            config: AuthorizationConfig(remembered: [pathKey: .allow], useInlineRememberedOnly: true),
            remembered: [pathKey: .allow]
        )
        guard case .allow = outcome else {
            return XCTFail("expected allow with path grant, got \(outcome)")
        }
    }

    func testWorktreeRootIsAlsoAllowedRoot() async throws {
        let worktree = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vc-wt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }

        let ctx = context(safeMode: nil, mode: .yolo, root: projectRoot, worktree: worktree)
        let result = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": worktree.appendingPathComponent("in-wt.txt").path,
                "content": "wt",
            ]),
            context: ctx)
        XCTAssertFalse(result.isError, result.content)
    }

    func testIsInsideWorkspaceHelpers() {
        let ctx = context(safeMode: nil)
        let inside = projectRoot.appendingPathComponent("a/b.swift")
        XCTAssertTrue(PathConfinement.isInsideWorkspace(inside, context: ctx))
        XCTAssertFalse(PathConfinement.isInsideWorkspace(outsideFile, context: ctx))
    }
}
