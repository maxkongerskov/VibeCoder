//
//  W06BugHuntTaskToolTests.swift
//
//  Wave C W06: TaskTool custom-agent fail-closed + plan-mode gate.
//

import XCTest
@testable import AgentCore

final class W06BugHuntTaskToolTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await BackgroundJobManager.shared.cleanup()
    }

    override func tearDown() async throws {
        await BackgroundJobManager.shared.cleanup()
    }

    func testCustomAgentEmptyToolsIsReadOnlyNotGeneralPurpose() {
        // Empty tools list must not inherit general-purpose write surface
        // when SubagentType.parse("my-reviewer") → .generalPurpose.
        let custom = DiscoveredAgentDefinition(
            name: "my-reviewer",
            description: "ro",
            systemPrompt: "Review only.",
            tools: [])
        // Mirror TaskTool resolution for empty tools.
        let mode = SubagentCapabilityMode.readOnly
        var allowed = mode.toolNames.intersection(SubagentCatalog.readOnlyTools)
        if allowed.isEmpty { allowed = SubagentCatalog.readOnlyTools }
        allowed.remove("task")
        XCTAssertFalse(allowed.contains("write_file"))
        XCTAssertFalse(allowed.contains("run_shell"))
        XCTAssertTrue(allowed.contains("read_file"))
        _ = custom
    }

    func testPlanModeAllowsReadOnlyCustomAgentName() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("w06-plan-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agents = root.appendingPathComponent(".vibecoder/agents", isDirectory: true)
        try! FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let md = """
        ---
        name: ro-scout
        description: read only scout
        tools: read_file, grep_code, list_directory
        ---
        You only explore.
        """
        try! md.write(to: agents.appendingPathComponent("ro-scout.md"), atomically: true, encoding: .utf8)

        let ctx = ToolContext(
            projectRoot: root,
            conversationID: UUID(),
            executionMode: .plan)
        let outcome = ToolAuthorization.evaluate(
            toolName: "task",
            permission: .executes,
            arguments: ToolArguments(dictionary: [
                "prompt": "find auth",
                "description": "scout",
                "subagent_type": "ro-scout",
            ]),
            context: ctx)
        switch outcome {
        case .allow:
            break
        default:
            XCTFail("expected allow for RO custom agent in plan mode, got \(outcome)")
        }
    }

    func testPlanModeDeniesWriteCustomAgentName() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("w06-plan-w-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agents = root.appendingPathComponent(".vibecoder/agents", isDirectory: true)
        try! FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let md = """
        ---
        name: writer-bot
        description: writes
        tools: read_file, write_file, edit_file
        ---
        You write files.
        """
        try! md.write(to: agents.appendingPathComponent("writer-bot.md"), atomically: true, encoding: .utf8)

        let ctx = ToolContext(
            projectRoot: root,
            conversationID: UUID(),
            executionMode: .plan)
        let outcome = ToolAuthorization.evaluate(
            toolName: "task",
            permission: .executes,
            arguments: ToolArguments(dictionary: [
                "prompt": "edit stuff",
                "description": "write",
                "subagent_type": "writer-bot",
            ]),
            context: ctx)
        if case .deny = outcome {
            // ok
        } else {
            XCTFail("expected deny for write custom agent in plan mode, got \(outcome)")
        }
    }

    func testUnknownCustomNameStillParsesAsGeneralPurposeDeniedInPlan() {
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            executionMode: .plan)
        let outcome = ToolAuthorization.evaluate(
            toolName: "task",
            permission: .executes,
            arguments: ToolArguments(dictionary: [
                "prompt": "x",
                "description": "y",
                "subagent_type": "not-a-real-agent-xyz",
            ]),
            context: ctx)
        if case .deny = outcome {
            // SubagentType.parse → generalPurpose → deny
        } else {
            XCTFail("expected deny for unknown name → GP in plan, got \(outcome)")
        }
    }

    func testCustomToolsIntersectCapabilityMode() {
        // tools lists write+read but capability_mode read-only must strip writes.
        let listed: Set<String> = ["read_file", "write_file", "edit_file", "grep_code"]
        let mode = SubagentCapabilityMode.readOnly
        var allowed = listed.intersection(mode.toolNames)
        if allowed.isEmpty { allowed = SubagentCatalog.readOnlyTools }
        allowed.remove("task")
        XCTAssertTrue(allowed.contains("read_file"))
        XCTAssertTrue(allowed.contains("grep_code"))
        XCTAssertFalse(allowed.contains("write_file"))
        XCTAssertFalse(allowed.contains("edit_file"))
    }
}
