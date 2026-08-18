//
//  ParitySkillAllowlistTests.swift
//
//  Enforce skill `allowed-tools` after a successful load_skill.
//

import XCTest
@testable import AgentCore

final class ParitySkillAllowlistTests: XCTestCase {

    private var tempRoot: URL!
    private var conversationID: UUID!

    override func setUpWithError() throws {
        conversationID = UUID()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-allow-\(conversationID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let conversationID {
            await SkillToolGate.shared.clear(conversationID: conversationID)
        }
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Helper

    private func context(disabled: Set<String> = [], conversationID: UUID? = nil) -> ToolContext {
        ToolContext(
            projectRoot: tempRoot,
            worktreeRoot: nil,
            safeMode: nil,
            conversationID: conversationID ?? self.conversationID,
            disabledToolNames: disabled
        )
    }

    private func load(_ skill: String, conversationID: UUID? = nil) async throws -> ToolResult {
        await ToolRegistry.shared.registerBuiltins()
        return try await ToolRegistry.shared.execute(
            name: "load_skill",
            arguments: ToolArguments(dictionary: ["skill": skill]),
            context: context(conversationID: conversationID)
        )
    }

    private func exec(
        _ name: String,
        args: [String: Any] = [:],
        disabled: Set<String> = [],
        conversationID: UUID? = nil
    ) async throws -> ToolResult {
        await ToolRegistry.shared.registerBuiltins()
        return try await ToolRegistry.shared.execute(
            name: name,
            arguments: ToolArguments(dictionary: args),
            context: context(disabled: disabled, conversationID: conversationID)
        )
    }

    private func writeSkill(
        name: String,
        body: String = "Skill body.",
        extraFrontmatter: [String] = []
    ) throws {
        let dir = tempRoot
            .appendingPathComponent(".vibecoder", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let extras = extraFrontmatter.map { $0 + "\n" }.joined()
        let md = """
        ---
        name: \(name)
        description: \(name) skill
        \(extras)---
        \(body)
        """
        try md.write(
            to: dir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Empty allowlist = unrestricted

    func testEmptyAllowedToolsDoesNotRestrict() async throws {
        try writeSkill(name: "open")
        let loaded = try await load("open")
        XCTAssertFalse(loaded.isError, loaded.content)
        let unrestricted = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertNil(unrestricted, "empty allowed-tools must not install a session gate")

        let listed = try await exec("list_directory", args: ["path": "."])
        XCTAssertFalse(listed.isError, listed.content)

        let marker = tempRoot.appendingPathComponent("unrestricted-dir")
        let created = try await exec("create_directory", args: ["path": "unrestricted-dir"])
        XCTAssertFalse(created.isError, created.content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - Non-empty allowlist fail-closed

    func testNonEmptyAllowlistBlocksOtherToolsAndDoesNotExecute() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: ["allowed-tools: list_directory"]
        )
        let loaded = try await load("gated")
        XCTAssertFalse(loaded.isError, loaded.content)

        let allowed = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertEqual(allowed, ["list_directory", "load_skill"])

        let listed = try await exec("list_directory", args: ["path": "."])
        XCTAssertFalse(listed.isError, listed.content)

        let marker = tempRoot.appendingPathComponent("must-not-exist")
        let denied = try await exec("create_directory", args: ["path": "must-not-exist"])
        XCTAssertTrue(denied.isError, denied.content)
        XCTAssertTrue(
            denied.content.contains("not permitted") || denied.content.contains("allowlist"),
            denied.content
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "out-of-allowlist tool must not execute"
        )
    }

    func testUnknownToolNameFailsClosedWithoutThrowingRegistryLookup() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: ["allowed-tools: list_directory"]
        )
        _ = try await load("gated")

        let denied = try await exec("web_search")
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(
            denied.content.contains("not permitted") || denied.content.contains("allowlist"),
            denied.content
        )
        XCTAssertTrue(denied.content.contains("web_search"), denied.content)
    }

    func testLoadSkillRemainsAllowedUnderGate() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: ["allowed-tools: list_directory"]
        )
        try writeSkill(name: "other")
        _ = try await load("gated")

        let again = try await load("other")
        XCTAssertFalse(again.isError, again.content)
        XCTAssertTrue(again.content.contains("<skill name=\"other\""), again.content)
    }

    // MARK: - Disabled always wins

    func testDisabledToolWinsOverSkillAllowlist() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: ["allowed-tools: list_directory, create_directory"]
        )
        _ = try await load("gated")

        let marker = tempRoot.appendingPathComponent("disabled-must-not-exist")
        let denied = try await exec(
            "create_directory",
            args: ["path": "disabled-must-not-exist"],
            disabled: ["create_directory"]
        )
        XCTAssertTrue(denied.isError, denied.content)
        XCTAssertTrue(denied.content.lowercased().contains("disabled"), denied.content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let listed = try await exec(
            "list_directory",
            args: ["path": "."],
            disabled: ["create_directory"]
        )
        XCTAssertFalse(listed.isError, listed.content)
    }

    // MARK: - Later load replaces the gate

    func testLaterLoadSkillReplacesAllowlist() async throws {
        try writeSkill(
            name: "first",
            extraFrontmatter: ["allowed-tools: list_directory"]
        )
        try writeSkill(
            name: "second",
            extraFrontmatter: ["allowed-tools: grep_code"]
        )
        _ = try await load("first")

        let grepBlocked = try await exec(
            "grep_code",
            args: ["pattern": "nope", "path": "."]
        )
        XCTAssertTrue(grepBlocked.isError, grepBlocked.content)

        let replaced = try await load("second")
        XCTAssertFalse(replaced.isError, replaced.content)
        let afterReplace = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertEqual(afterReplace, ["grep_code", "load_skill"])

        let listBlocked = try await exec("list_directory", args: ["path": "."])
        XCTAssertTrue(listBlocked.isError, listBlocked.content)

        let grepOk = try await exec(
            "grep_code",
            args: ["pattern": "Skill", "path": "."]
        )
        XCTAssertFalse(grepOk.isError, grepOk.content)
    }

    func testLaterUnrestrictedSkillClearsGate() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: ["allowed-tools: list_directory"]
        )
        try writeSkill(name: "open")
        _ = try await load("gated")
        _ = try await load("open")

        let cleared = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertNil(cleared)

        let marker = tempRoot.appendingPathComponent("after-clear")
        let created = try await exec("create_directory", args: ["path": "after-clear"])
        XCTAssertFalse(created.isError, created.content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFailedLoadDoesNotReplaceGate() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: ["allowed-tools: list_directory"]
        )
        _ = try await load("gated")

        let failed = try await load("does-not-exist")
        XCTAssertTrue(failed.isError)
        let stillGated = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertEqual(stillGated, ["list_directory", "load_skill"])

        let stillDenied = try await exec("create_directory", args: ["path": "still-blocked"])
        XCTAssertTrue(stillDenied.isError, stillDenied.content)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempRoot.appendingPathComponent("still-blocked").path)
        )
    }

    // MARK: - Session key matches SessionReadTracker (conversationID)

    func testGateIsKeyedByConversationID() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: ["allowed-tools: list_directory"]
        )
        let other = UUID()
        _ = try await load("gated")

        let otherListed = try await exec(
            "create_directory",
            args: ["path": "other-convo-ok"],
            conversationID: other
        )
        XCTAssertFalse(otherListed.isError, otherListed.content)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempRoot.appendingPathComponent("other-convo-ok").path)
        )

        let sameDenied = try await exec("create_directory", args: ["path": "same-convo-blocked"])
        XCTAssertTrue(sameDenied.isError, sameDenied.content)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempRoot.appendingPathComponent("same-convo-blocked").path)
        )
        await SkillToolGate.shared.clear(conversationID: other)
    }

    // MARK: - Read-only batch path

    func testExecuteReadOnlyBatchHonorsAllowlist() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: ["allowed-tools: list_directory"]
        )
        _ = try await load("gated")

        await ToolRegistry.shared.registerBuiltins()
        let results = await ToolRegistry.shared.executeReadOnlyBatch(
            invocations: [
                ("list_directory", ToolArguments(dictionary: ["path": "."])),
                ("glob_files", ToolArguments(dictionary: ["pattern": "*"])),
            ],
            context: context()
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertFalse(results[0].isError, results[0].content)
        XCTAssertTrue(results[1].isError, results[1].content)
        XCTAssertTrue(
            results[1].content.contains("not permitted") || results[1].content.contains("allowlist"),
            results[1].content
        )
    }

    func testExecuteReadOnlyBatchDisabledWins() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: ["allowed-tools: list_directory, glob_files"]
        )
        _ = try await load("gated")

        await ToolRegistry.shared.registerBuiltins()
        let results = await ToolRegistry.shared.executeReadOnlyBatch(
            invocations: [
                ("list_directory", ToolArguments(dictionary: ["path": "."])),
            ],
            context: context(disabled: ["list_directory"])
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError, results[0].content)
        XCTAssertTrue(results[0].content.lowercased().contains("disabled"), results[0].content)
    }

    // MARK: - Helper

    func testSessionToolAllowlistHelper() {
        XCTAssertNil(SkillDiscovery.sessionToolAllowlist(from: []))
        XCTAssertNil(SkillDiscovery.sessionToolAllowlist(from: ["  ", ""]))
        XCTAssertEqual(
            SkillDiscovery.sessionToolAllowlist(from: [" read_file ", "grep_code", "read_file"]),
            ["read_file", "grep_code"]
        )
    }

    func testRecordAlwaysUnionsLoadSkill() async {
        await SkillToolGate.shared.record(
            allowedTools: ["list_directory"],
            conversationID: conversationID
        )
        let allowed = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertEqual(allowed, ["list_directory", "load_skill"])

        await SkillToolGate.shared.record(
            allowedTools: ["list_directory", "load_skill"],
            conversationID: conversationID
        )
        let still = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertEqual(still, ["list_directory", "load_skill"])
    }

    // MARK: - Delete / clear (SkillToolGate.clear is the hook)

    /// ConversationStore.delete is not owned here. Persistence must call
    /// `SkillToolGate.clear(conversationID:)` from that path. This test
    /// locks the clear contract those callers invoke.
    func testClearConversationIDLiftsGateAndDoesNotExecuteRestriction() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: ["allowed-tools: list_directory"]
        )
        _ = try await load("gated")

        let blocked = try await exec("create_directory", args: ["path": "before-clear"])
        XCTAssertTrue(blocked.isError, blocked.content)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempRoot.appendingPathComponent("before-clear").path)
        )

        await SkillToolGate.shared.clear(conversationID: conversationID)
        let afterClear = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertNil(afterClear, "clear is the conversation-delete / /clear hook")

        let marker = tempRoot.appendingPathComponent("after-clear")
        let created = try await exec("create_directory", args: ["path": "after-clear"])
        XCTAssertFalse(created.isError, created.content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testClearOneConversationDoesNotClearSibling() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: ["allowed-tools: list_directory"]
        )
        let sibling = UUID()
        _ = try await load("gated")
        _ = try await load("gated", conversationID: sibling)

        await SkillToolGate.shared.clear(conversationID: conversationID)
        let clearedSelf = await SkillToolGate.shared.allowlist(for: conversationID)
        let siblingStill = await SkillToolGate.shared.allowlist(for: sibling)
        XCTAssertNil(clearedSelf)
        XCTAssertEqual(siblingStill, ["list_directory", "load_skill"])

        let siblingStillDenied = try await exec(
            "create_directory",
            args: ["path": "sibling-still-blocked"],
            conversationID: sibling
        )
        XCTAssertTrue(siblingStillDenied.isError, siblingStillDenied.content)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempRoot.appendingPathComponent("sibling-still-blocked").path)
        )
        await SkillToolGate.shared.clear(conversationID: sibling)
    }

    // MARK: - In-memory only (no Conversation JSON field)

    func testProcessRelaunchWithoutHydrateLeavesUnrestricted() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: ["allowed-tools: list_directory"]
        )
        _ = try await load("gated")
        let live = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertEqual(live, ["list_directory", "load_skill"])

        // Process death: the in-memory actor is empty. There is no seed/hydrate
        // API and no Conversation JSON field — tools become unrestricted.
        await SkillToolGate.shared.clear(conversationID: conversationID)
        let afterRelaunch = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertNil(afterRelaunch)

        let marker = tempRoot.appendingPathComponent("after-relaunch")
        let created = try await exec("create_directory", args: ["path": "after-relaunch"])
        XCTAssertFalse(created.isError, created.content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}
