//
//  ParityRegistryTests.swift
//
//  Wave-2 registry: registerBuiltins includes ZCode-parity tools.
//

import XCTest
@testable import AgentCore

final class ParityRegistryTests: XCTestCase {

    func testRegisterBuiltinsIncludesParityTools() async {
        let registry = ToolRegistry.shared
        await registry.registerBuiltins()
        let names = await registry.registeredNames()
        for required in [
            "read_session_context",
            "cron_create", "cron_list", "cron_update", "cron_delete",
            "send_message",
            "enter_plan_mode", "exit_plan_mode",
        ] {
            XCTAssertTrue(names.contains(required), "Missing built-in tool: \(required)")
        }
    }

    func testRegisterBuiltinsIncludesPreviouslyUncataloguedTools() async {
        let registry = ToolRegistry.shared
        await registry.registerBuiltins()
        let names = await registry.registeredNames()
        for required in [
            "git_commit", "create_pull_request",
            "list_background_jobs", "monitor_jobs",
        ] {
            XCTAssertTrue(names.contains(required), "Missing built-in tool: \(required)")
        }
    }

    func testParallelSafeExecuteToolsIncludesTask() {
        XCTAssertEqual(ToolRegistry.parallelSafeExecuteTools, ["task"])
    }
}
