//
//  ParityWave2SmokeTests.swift
//
//  Wave-2 leftovers that are not AgentLoop cadence injection
//  (that wiring lives in ParityReminderCadenceTests).
//  New file only — does not edit product sources.
//

import XCTest
@testable import AgentCore

final class ParityWave2SmokeTests: XCTestCase {

    private var root: URL!
    private var storeDir: URL!
    private var conversationID: UUID!

    override func setUp() async throws {
        conversationID = UUID()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("w2-smoke-\(conversationID.uuidString)", isDirectory: true)
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("w2-store-\(conversationID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        await ToolRegistry.shared.registerBuiltins()
    }

    override func tearDown() async throws {
        if let conversationID {
            await SkillToolGate.shared.clear(conversationID: conversationID)
            await SessionReadTracker.shared.clear(conversationID: conversationID)
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        if let storeDir { try? FileManager.default.removeItem(at: storeDir) }
    }

    private func context(
        conversationID: UUID? = nil,
        disabled: Set<String> = [],
        executionMode: ExecutionMode? = .yolo
    ) -> ToolContext {
        ToolContext(
            projectRoot: root,
            conversationID: conversationID ?? self.conversationID,
            executionMode: executionMode,
            disabledToolNames: disabled
        )
    }

    private func writeSkill(
        name: String,
        extraFrontmatter: String = "",
        body: String = "Skill body."
    ) throws {
        let dir = root
            .appendingPathComponent(".vibecoder/skills/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let extras = extraFrontmatter.isEmpty ? "" : extraFrontmatter + "\n"
        let md = """
        ---
        name: \(name)
        description: \(name) skill
        \(extras)---
        \(body)
        """
        try md.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func loadSkill(_ name: String, conversationID: UUID? = nil) async throws -> ToolResult {
        try await ToolRegistry.shared.execute(
            name: "load_skill",
            arguments: ToolArguments(dictionary: ["skill": name]),
            context: context(conversationID: conversationID))
    }

    @discardableResult
    private func exec(
        _ name: String,
        args: [String: Any] = [:],
        conversationID: UUID? = nil
    ) async throws -> ToolResult {
        try await ToolRegistry.shared.execute(
            name: name,
            arguments: ToolArguments(dictionary: args),
            context: context(conversationID: conversationID))
    }

    private func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: text)
    }

    private func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: text)
    }

    private func transcript(humanTurns n: Int) -> [ChatMessage] {
        guard n > 0 else { return [] }
        var messages: [ChatMessage] = []
        for i in 1...n {
            messages.append(user("turn \(i)"))
            messages.append(assistant("ok \(i)"))
        }
        return messages
    }

    // MARK: - Cadence helper leftovers (injection already covered)

    func testZeroIntervalAndThresholdNeverFire() {
        let five = transcript(humanTurns: 5)
        let eight = transcript(humanTurns: 8)
        XCTAssertFalse(
            ChatLoop.shouldRemindPlanMode(messages: five, executionMode: .plan, interval: 0))
        XCTAssertFalse(
            ChatLoop.shouldRemindPlanMode(messages: five, executionMode: .plan, interval: -1))
        XCTAssertFalse(ChatLoop.shouldNudgeTodoPlan(messages: eight, threshold: 0))
        XCTAssertFalse(ChatLoop.shouldNudgeTodoPlan(messages: eight, threshold: -3))
    }

    func testCadenceRemindersCanEmitTurnAndPostCompactTogether() {
        let skillBlock = SkillDiscovery.indexBlock(skills: [
            DiscoveredSkill(name: "verify", description: "Re-read after edits", body: "")
        ])
        let nudges = ChatLoop.cadenceReminders(
            messages: transcript(humanTurns: 5),
            executionMode: .plan,
            didPersistCompact: true,
            emitTurnCadence: true,
            skillIndex: skillBlock,
            projectInstructions: "# Project instructions\n\nUse tabs.")
        XCTAssertEqual(nudges.count, 2, "\(nudges)")
        XCTAssertEqual(nudges[0], SystemReminder.planModeCadence)
        XCTAssertTrue(nudges[1].hasPrefix("# System reminder — post-compaction"), nudges[1])
        XCTAssertTrue(nudges[1].contains("`verify`"), nudges[1])
        XCTAssertTrue(nudges[1].contains("Use tabs."), nudges[1])
    }

    func testPostCompactDiskReloadUsesWorktreeSkillsAndProjectInstructions() throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let skillDir = worktree.appendingPathComponent(
            ".vibecoder/skills/wt-only", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: wt-only
        description: Worktree skill
        ---
        # Worktree
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let agentos = project.appendingPathComponent(".agentos", isDirectory: true)
        try FileManager.default.createDirectory(at: agentos, withIntermediateDirectories: true)
        try "Prefer worktree diffs."
            .write(to: agentos.appendingPathComponent("instructions.md"),
                   atomically: true, encoding: .utf8)

        let nudges = ChatLoop.cadenceReminders(
            messages: transcript(humanTurns: 1),
            executionMode: .edit,
            didPersistCompact: true,
            emitTurnCadence: false,
            projectRoot: project,
            worktreeRoot: worktree)
        XCTAssertEqual(nudges.count, 1, "\(nudges)")
        XCTAssertTrue(nudges[0].contains("`wt-only`"), nudges[0])
        XCTAssertTrue(nudges[0].contains("Prefer worktree diffs."), nudges[0])
    }

    // MARK: - Skill gate leftovers

    func testYAMLBlockAllowedToolsEnforcedThroughLoadSkill() async throws {
        try writeSkill(
            name: "yaml-gated",
            extraFrontmatter: """
            allowed-tools:
              - list_directory
            """)
        let loaded = try await loadSkill("yaml-gated")
        XCTAssertFalse(loaded.isError, loaded.content)
        let allowed = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertEqual(allowed, ["list_directory", "load_skill"])

        let listed = try await exec("list_directory", args: ["path": "."])
        XCTAssertFalse(listed.isError, listed.content)
        let denied = try await exec("create_directory", args: ["path": "blocked-yaml"])
        XCTAssertTrue(denied.isError, denied.content)
        XCTAssertTrue(
            denied.content.contains("not permitted") || denied.content.contains("allowlist"),
            denied.content)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("blocked-yaml").path))
    }

    func testDisableModelInvocationLoadDoesNotRecordGate() async throws {
        try writeSkill(
            name: "slash-only",
            extraFrontmatter: """
            disable-model-invocation: true
            allowed-tools: list_directory
            """)
        let failed = try await loadSkill("slash-only")
        XCTAssertTrue(failed.isError, failed.content)
        XCTAssertTrue(
            failed.content.contains("disable-model-invocation"),
            failed.content)
        let gate = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertNil(gate, "failed control-plane load must not install a session gate")
    }

    func testAllowlistDenyRunsBeforeProjectHook() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: "allowed-tools: list_directory")
        _ = try await loadSkill("gated")

        let hooks = root.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let marker = hooks.appendingPathComponent("hook-ran.txt")
        let script = hooks.appendingPathComponent("mark.sh")
        try """
        #!/bin/sh
        echo ran > "\(marker.path)"
        exit 2
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        try JSONSerialization.data(withJSONObject: [
            "pre": [
                ["matcher": "create_directory", "type": "command", "command": "mark.sh"]
            ]
        ]).write(to: hooks.appendingPathComponent("hooks.json"))

        let denied = try await exec("create_directory", args: ["path": "hook-must-not-see"])
        XCTAssertTrue(denied.isError, denied.content)
        XCTAssertTrue(
            denied.content.contains("not permitted") || denied.content.contains("allowlist"),
            denied.content)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "allowlist deny must happen before PreToolUse")
    }

    func testSkillGateIsInMemoryOnlyAndMissingFromConversationJSON() async throws {
        try writeSkill(
            name: "gated",
            extraFrontmatter: "allowed-tools: list_directory")
        _ = try await loadSkill("gated")
        let before = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertNotNil(before)

        let store = ConversationStore(directory: storeDir)
        try await store.save(Conversation(id: conversationID, title: "gate", projectRoot: root))
        let onDisk = try String(
            contentsOf: storeDir.appendingPathComponent("\(conversationID.uuidString).json"),
            encoding: .utf8)
        XCTAssertFalse(onDisk.contains("SkillToolGate"), onDisk)
        XCTAssertFalse(onDisk.lowercased().contains("allowlist"), onDisk)
        XCTAssertFalse(onDisk.contains("allowed-tools"), onDisk)
        XCTAssertFalse(onDisk.contains("list_directory"), onDisk)

        // Simulated process death: actor is empty. Gate does not hydrate from JSON.
        await SkillToolGate.shared.clear(conversationID: conversationID)
        _ = try await store.load(id: conversationID)
        let afterLoad = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertNil(afterLoad, "SkillToolGate must stay in-memory; load must not restore it")
    }

    // MARK: - Read-tracker leftovers

    func testSeedEmptyPathsDoesNotWipeLiveReads() async throws {
        let file = root.appendingPathComponent("keep.swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        await SessionReadTracker.shared.recordRead(path: file.path, conversationID: conversationID)
        let before = await SessionReadTracker.shared.hasRead(
            path: file.path, conversationID: conversationID)
        XCTAssertTrue(before)

        await SessionReadTracker.shared.seed(paths: [String](), conversationID: conversationID)
        let after = await SessionReadTracker.shared.hasRead(
            path: file.path, conversationID: conversationID)
        XCTAssertTrue(after, "empty seed must be a no-op")
    }

    func testConversationStoreDeleteClearsTrackerAndSkillGate() async throws {
        let file = root.appendingPathComponent("tracked.swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let read = try await exec("read_file", args: ["path": "tracked.swift"])
        XCTAssertFalse(read.isError, read.content)
        try writeSkill(
            name: "gated",
            extraFrontmatter: "allowed-tools: list_directory")
        _ = try await loadSkill("gated")

        let store = ConversationStore(directory: storeDir)
        try await store.save(Conversation(id: conversationID, title: "del", projectRoot: root))
        let pathsBefore = await SessionReadTracker.shared.paths(for: conversationID)
        let gateBefore = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertFalse(pathsBefore.isEmpty)
        XCTAssertNotNil(gateBefore)

        try await store.delete(id: conversationID)
        let pathsAfter = await SessionReadTracker.shared.paths(for: conversationID)
        let gateAfter = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertTrue(pathsAfter.isEmpty)
        XCTAssertNil(gateAfter)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storeDir.appendingPathComponent("\(conversationID.uuidString).json").path))
    }

    func testTwoConversationsPersistAndHydrateInIsolation() async throws {
        let otherID = UUID()
        defer {
            Task {
                await SessionReadTracker.shared.clear(conversationID: otherID)
                await SkillToolGate.shared.clear(conversationID: otherID)
            }
        }

        let a = root.appendingPathComponent("a.swift")
        let b = root.appendingPathComponent("b.swift")
        try "aaa\n".write(to: a, atomically: true, encoding: .utf8)
        try "bbb\n".write(to: b, atomically: true, encoding: .utf8)

        let readA = try await exec("read_file", args: ["path": "a.swift"])
        let readB = try await exec(
            "read_file", args: ["path": "b.swift"], conversationID: otherID)
        XCTAssertFalse(readA.isError, readA.content)
        XCTAssertFalse(readB.isError, readB.content)

        let store = ConversationStore(directory: storeDir)
        try await store.save(Conversation(id: conversationID, title: "A", projectRoot: root))
        try await store.save(Conversation(id: otherID, title: "B", projectRoot: root))

        await SessionReadTracker.shared.clear(conversationID: conversationID)
        await SessionReadTracker.shared.clear(conversationID: otherID)

        _ = try await store.load(id: conversationID)
        let aOnA = await SessionReadTracker.shared.hasRead(
            path: a.path, conversationID: conversationID)
        let bOnA = await SessionReadTracker.shared.hasRead(
            path: b.path, conversationID: conversationID)
        let bOnBBefore = await SessionReadTracker.shared.hasRead(
            path: b.path, conversationID: otherID)
        XCTAssertTrue(aOnA)
        XCTAssertFalse(bOnA)
        XCTAssertFalse(bOnBBefore, "loading A must not hydrate B")

        _ = try await store.load(id: otherID)
        let bOnB = await SessionReadTracker.shared.hasRead(
            path: b.path, conversationID: otherID)
        let aOnB = await SessionReadTracker.shared.hasRead(
            path: a.path, conversationID: otherID)
        XCTAssertTrue(bOnB)
        XCTAssertFalse(aOnB)
    }

    func testWriteFileCreateNewSucceedsAfterTrackerReset() async throws {
        await SessionReadTracker.shared.clear(conversationID: conversationID)
        let created = try await exec(
            "write_file",
            args: ["path": "brand-new.txt", "content": "hello\n"])
        XCTAssertFalse(created.isError, created.content)
        let body = try String(
            contentsOf: root.appendingPathComponent("brand-new.txt"), encoding: .utf8)
        XCTAssertEqual(body, "hello\n")
    }
}
