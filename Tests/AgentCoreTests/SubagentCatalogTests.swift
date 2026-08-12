//
//  SubagentCatalogTests.swift
//

import XCTest
@testable import AgentCore

final class SubagentCatalogTests: XCTestCase {

    func testParseSubagentTypes() {
        XCTAssertEqual(SubagentType.parse("explore"), .explore)
        XCTAssertEqual(SubagentType.parse("plan"), .plan)
        XCTAssertEqual(SubagentType.parse("general-purpose"), .generalPurpose)
        XCTAssertEqual(SubagentType.parse(nil), .generalPurpose)
        XCTAssertEqual(SubagentType.parse("unknown"), .generalPurpose)
    }

    func testExploreIsReadOnly() {
        let tools = SubagentType.explore.allowedTools(capability: nil)
        XCTAssertFalse(tools.contains("write_file"))
        XCTAssertFalse(tools.contains("edit_file"))
        XCTAssertFalse(tools.contains("run_shell"))
        XCTAssertFalse(tools.contains("task"))
        XCTAssertTrue(tools.contains("read_file"))
        XCTAssertTrue(tools.contains("grep_code"))
    }

    func testPlanIsReadOnlyAndHasPlanTools() {
        let tools = SubagentType.plan.allowedTools(capability: nil)
        XCTAssertFalse(tools.contains("write_file"))
        XCTAssertFalse(tools.contains("task"))
        XCTAssertTrue(tools.contains("create_plan") || tools.contains("read_file"))
        XCTAssertTrue(tools.contains("read_file"))
    }

    func testGeneralPurposeStripsTask() {
        let tools = SubagentType.generalPurpose.allowedTools(capability: .all)
        XCTAssertFalse(tools.contains("task"))
        XCTAssertTrue(tools.contains("read_file"))
        XCTAssertTrue(tools.contains("write_file") || tools.contains("edit_file"))
    }

    func testCapabilityIntersection() {
        // explore + execute still cannot get write tools outside preferred set
        let tools = SubagentType.explore.allowedTools(capability: .all)
        XCTAssertFalse(tools.contains("write_file"))
        XCTAssertTrue(tools.contains("read_file"))
    }

    func testCapabilityModeParse() {
        XCTAssertEqual(SubagentCapabilityMode.parse("read-only"), .readOnly)
        XCTAssertEqual(SubagentCapabilityMode.parse("read_only"), .readOnly)
        XCTAssertEqual(SubagentCapabilityMode.parse("all"), .all)
        XCTAssertNil(SubagentCapabilityMode.parse("nope"))
    }

    func testTaskToolRegistered() async {
        await ToolRegistry.shared.registerBuiltins()
        let names = Set(await ToolRegistry.shared.schemas().map(\.name))
        XCTAssertTrue(names.contains("task"), "task tool should be a core builtin")
    }

    func testTaskToolDepthGuard() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let args = ToolArguments(dictionary: [
            "prompt": "find auth",
            "description": "search",
            "subagent_type": "explore",
        ])
        // Depth already at 1 → refuse without needing a backend
        let ctx = ToolContext(
            projectRoot: nil,
            conversationID: UUID(),
            subagentDepth: 1
        )
        let result = try await ToolRegistry.shared.execute(
            name: "task",
            arguments: args,
            context: ctx
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("depth"))
    }

    func testTaskToolMissingBackend() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let args = ToolArguments(dictionary: [
            "prompt": "find auth",
            "description": "search",
            "subagent_type": "explore",
        ])
        let ctx = ToolContext(projectRoot: nil, conversationID: UUID(), subagentDepth: 0)
        let result = try await ToolRegistry.shared.execute(
            name: "task",
            arguments: args,
            context: ctx
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("backend")
                      || result.content.lowercased().contains("model"))
    }
}
