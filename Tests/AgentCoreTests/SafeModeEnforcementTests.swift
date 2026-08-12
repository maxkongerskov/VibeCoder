//
//  SafeModeEnforcementTests.swift
//
//  Adversarial tests for the Safe Mode allow-list enforcement in
//  ToolRegistry.checkPermission + SafeModeConfig + ApplyPatchTool.
//
//  These encode the three path-bypass classes found in the 2026-06-09
//  review (absolute paths, `~` expansion, `..` traversal), the
//  unchecked move_file source/destination gap, and the shell
//  prefix-matching gaps (no word boundary, command chaining).
//

import XCTest
@testable import AgentCore

final class SafeModeEnforcementTests: XCTestCase {

    private var tempRoot: URL!
    private var registry: ToolRegistry!

    override func setUp() async throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-safemode-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        registry = ToolRegistry.shared
        await registry.registerBuiltins()   // idempotent (duplicate registrations warn + no-op)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func context(shellPrefixes: [String] = []) -> ToolContext {
        ToolContext(
            projectRoot: tempRoot,
            safeMode: SafeModeConfig(
                allowedPathPrefixes: [tempRoot.path],
                allowedShellPrefixes: shellPrefixes
            ),
            conversationID: UUID()
        )
    }

    private func args(_ json: String) throws -> ToolArguments {
        try ToolArguments(json: json)
    }

    private func assertPermissionDenied(_ body: () async throws -> Void,
                                        _ message: String) async {
        do {
            try await body()
            XCTFail("Expected permissionDenied: \(message)")
        } catch let e as ToolError {
            guard case .permissionDenied = e else {
                XCTFail("Expected permissionDenied, got \(e): \(message)")
                return
            }
        } catch {
            XCTFail("Expected ToolError.permissionDenied, got \(error): \(message)")
        }
    }

    // MARK: - Path escapes (write_file)

    func testAbsolutePathOutsideAllowListIsDenied() async throws {
        let escape = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-escape-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: escape) }

        await assertPermissionDenied({
            _ = try await self.registry.execute(
                name: "write_file",
                arguments: try self.args(#"{"path": "\#(escape.path)", "content": "pwned"}"#),
                context: self.context())
        }, "absolute path outside the allow-list")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escape.path),
                       "file must not be created on a denied call")
    }

    func testDotDotTraversalIsDenied() async throws {
        let name = "agentos-escape-\(UUID().uuidString).txt"
        let escaped = tempRoot.deletingLastPathComponent().appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: escaped) }

        await assertPermissionDenied({
            _ = try await self.registry.execute(
                name: "write_file",
                arguments: try self.args(#"{"path": "../\#(name)", "content": "pwned"}"#),
                context: self.context())
        }, "`..` traversal outside the allow-list")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }

    func testTildePathIsDenied() async throws {
        await assertPermissionDenied({
            _ = try await self.registry.execute(
                name: "write_file",
                arguments: try self.args(#"{"path": "~/agentos-escape-test.txt", "content": "pwned"}"#),
                context: self.context())
        }, "~ path outside the allow-list")
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("agentos-escape-test.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func testRelativePathInsideAllowListSucceeds() async throws {
        let result = try await registry.execute(
            name: "write_file",
            arguments: try args(#"{"path": "ok.txt", "content": "fine"}"#),
            context: context())
        XCTAssertFalse(result.isError)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("ok.txt").path))
    }

    func testAbsolutePathInsideAllowListSucceeds() async throws {
        let inside = tempRoot.appendingPathComponent("abs.txt")
        let result = try await registry.execute(
            name: "write_file",
            arguments: try args(#"{"path": "\#(inside.path)", "content": "fine"}"#),
            context: context())
        XCTAssertFalse(result.isError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
    }

    // MARK: - move_file (source/destination were previously unchecked)

    func testMoveFileWithOutsideDestinationIsDenied() async throws {
        let src = tempRoot.appendingPathComponent("src.txt")
        try "data".write(to: src, atomically: true, encoding: .utf8)
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-moved-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }

        await assertPermissionDenied({
            _ = try await self.registry.execute(
                name: "move_file",
                arguments: try self.args(#"{"source": "src.txt", "destination": "\#(outside.path)"}"#),
                context: self.context())
        }, "move destination outside the allow-list")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "source must be untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testMoveFileInsideAllowListSucceeds() async throws {
        let src = tempRoot.appendingPathComponent("a.txt")
        try "data".write(to: src, atomically: true, encoding: .utf8)

        let result = try await registry.execute(
            name: "move_file",
            arguments: try args(#"{"source": "a.txt", "destination": "b.txt"}"#),
            context: context())
        XCTAssertFalse(result.isError)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("b.txt").path))
    }

    // MARK: - Shell allow-list

    func testShellPrefixRequiresWordBoundary() async throws {
        // "git" must not allow "github-foo …" (or any longer first word).
        await assertPermissionDenied({
            _ = try await self.registry.execute(
                name: "run_shell",
                arguments: try self.args(#"{"command": "github-foo --version"}"#),
                context: self.context(shellPrefixes: ["git"]))
        }, "prefix match must be word-bounded")
    }

    func testShellChainingIsDenied() async throws {
        // Wave B S10a / W03: pure SafeBash RO multi-segment chains
        // (`git status && git diff`, `git status; echo ok`) are allowed even
        // under Safe Mode — they skip the metacharacter ban so legitimate
        // inspect pipelines work. See PlanSafeModeReconcileTests.
        //
        // Still deny chains that are **not** pure-RO (redirects, substitution,
        // non-RO segments like `tee` that writes).
        for cmd in ["git status | tee /tmp/x",
                    "git status `echo hi`",
                    "git status $(echo hi)",
                    "git status > /tmp/x",
                    "git status && touch /tmp/agentos-safemode-chain-\(UUID().uuidString)"] {
            await assertPermissionDenied({
                _ = try await self.registry.execute(
                    name: "run_shell",
                    arguments: try self.args(#"{"command": "\#(cmd)"}"#),
                    context: self.context(shellPrefixes: ["git"]))
            }, "non-RO / injection chain must be denied: \(cmd)")
        }
    }

    func testPureROShellChainsAllowedUnderSafeMode() async throws {
        // S10a: inspect-only multi-segment commands must not throw permissionDenied.
        for cmd in ["git status; echo pwned", "git status && echo pwned"] {
            let result = try await registry.execute(
                name: "run_shell",
                arguments: try args(#"{"command": "\#(cmd)"}"#),
                context: context(shellPrefixes: ["git"]))
            XCTAssertFalse(
                result.content.lowercased().contains("permission denied"),
                "pure RO chain must not be permission-denied: \(cmd) → \(result.content.prefix(120))"
            )
        }
    }

    func testPlainAllowedCommandRuns() async throws {
        // `git status` in a non-repo exits non-zero — that's an ordinary
        // tool error, NOT a permission denial. The call must not throw.
        let result = try await registry.execute(
            name: "run_shell",
            arguments: try args(#"{"command": "git status"}"#),
            context: context(shellPrefixes: ["git"]))
        XCTAssertTrue(result.content.contains("$ git status"))
    }

    // MARK: - apply_patch (paths live inside the diff body)

    func testApplyPatchTargetingOutsidePathIsDenied() async throws {
        let name = "agentos-patch-escape-\(UUID().uuidString).txt"
        let escaped = tempRoot.deletingLastPathComponent().appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: escaped) }

        let patch = """
        --- a/../\(name)
        +++ b/../\(name)
        @@ -0,0 +1 @@
        +pwned
        """
        let json = try JSONSerialization.data(withJSONObject: ["patch": patch])
        await assertPermissionDenied({
            _ = try await self.registry.execute(
                name: "apply_patch",
                arguments: ToolArguments(dictionary:
                    try JSONSerialization.jsonObject(with: json) as! [String: Any]),
                context: self.context())
        }, "apply_patch target outside the allow-list")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }

    // MARK: - edit_file path enforcement

    func testEditFilePathOutsideAllowListIsDenied() async throws {
        // The path argument to edit_file routes through the same
        // `checkPermission` → `isPathAllowed` path as write_file.
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-edit-escape-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: outside) }

        let edits = """
        <<<<<<< SEARCH
        =======
        let x = 1
        >>>>>>> REPLACE
        """
        let argsJSON = try JSONSerialization.data(withJSONObject: [
            "path": outside.path,
            "edits": edits
        ])
        await assertPermissionDenied({
            _ = try await self.registry.execute(
                name: "edit_file",
                arguments: ToolArguments(dictionary:
                    try JSONSerialization.jsonObject(with: argsJSON) as! [String: Any]),
                context: self.context())
        }, "edit_file: absolute path outside allow-list")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testEditFileDotDotTraversalIsDenied() async throws {
        // `..` in the path argument must be canonicalized and rejected.
        let name = "agentos-edit-dotdot-\(UUID().uuidString).swift"
        let escaped = tempRoot.deletingLastPathComponent().appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: escaped) }

        let edits = """
        <<<<<<< SEARCH
        =======
        let y = 2
        >>>>>>> REPLACE
        """
        let argsJSON = try JSONSerialization.data(withJSONObject: [
            "path": "../\(name)",
            "edits": edits
        ])
        await assertPermissionDenied({
            _ = try await self.registry.execute(
                name: "edit_file",
                arguments: ToolArguments(dictionary:
                    try JSONSerialization.jsonObject(with: argsJSON) as! [String: Any]),
                context: self.context())
        }, "edit_file: `..` traversal must be denied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }

    // MARK: - Shell injection edge cases

    func testShellNewlineInjectionIsDenied() async throws {
        // A literal newline embedded in the command string is a classic
        // injection vector — the shell treats it as a command separator.
        // `shellMetacharacters` includes "\n"; this test ensures a real
        // newline (not just `\n` in the allow-list prefix check) is caught.
        let cmd = "git status\nrm -rf /"
        await assertPermissionDenied({
            _ = try await self.registry.execute(
                name: "run_shell",
                arguments: try self.args("{\"command\": \"git status\\nrm -rf /\"}"),
                context: self.context(shellPrefixes: ["git"]))
        }, "newline in command must be denied")
    }

    func testShellCommandNotInAllowListIsDenied() async throws {
        // A completely unlisted command with no metacharacters should still
        // be denied because the prefix list doesn't include it.
        await assertPermissionDenied({
            _ = try await self.registry.execute(
                name: "run_shell",
                arguments: try self.args(#"{"command": "curl https://evil.example"}"#),
                context: self.context(shellPrefixes: ["git", "swift"]))
        }, "command not in allow-list must be denied")
    }

    func testSymlinkEscapeOutsideAllowListIsDenied() async throws {
        // A symlink INSIDE the allow-list can point OUTSIDE it.
        // `normalizePath` calls `resolvingSymlinksInPath`, so the policy
        // check must see the real destination — not the symlink path.
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-symlink-target-\(UUID().uuidString).txt")
        try "original".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let symlink = tempRoot.appendingPathComponent("inside-link.txt")
        try FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: symlink) }

        await assertPermissionDenied({
            _ = try await self.registry.execute(
                name: "write_file",
                arguments: try self.args(#"{"path": "inside-link.txt", "content": "pwned"}"#),
                context: self.context())
        }, "symlink target outside allow-list must be denied")
        // The original file must not have been overwritten.
        let content = try String(contentsOf: outside, encoding: .utf8)
        XCTAssertEqual(content, "original", "symlink target must not be modified")
    }

    // MARK: - SafeModeConfig unit checks

    func testPrefixBoundaryOnSiblingDirectory() {
        let config = SafeModeConfig(allowedPathPrefixes: ["/tmp/work"], allowedShellPrefixes: [])
        XCTAssertFalse(config.isPathAllowed(URL(fileURLWithPath: "/tmp/work-evil/x.txt")),
                       "/tmp/work must not allow /tmp/work-evil")
        XCTAssertTrue(config.isPathAllowed(URL(fileURLWithPath: "/tmp/work/x.txt")))
    }

    func testNormalizationCollapsesTraversal() {
        let config = SafeModeConfig(allowedPathPrefixes: ["/tmp/work"], allowedShellPrefixes: [])
        XCTAssertFalse(config.isPathAllowed(URL(fileURLWithPath: "/tmp/work/../escape.txt")))
        XCTAssertTrue(config.isPathAllowed(URL(fileURLWithPath: "/tmp/work/sub/../inside.txt")))
    }
}
