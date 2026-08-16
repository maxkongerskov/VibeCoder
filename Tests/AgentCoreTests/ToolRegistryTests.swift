//
//  ToolRegistryTests.swift
//

import XCTest
@testable import AgentCore

final class ToolRegistryTests: XCTestCase {

    func testBuiltinsRegister() async {
        let registry = ToolRegistry.shared
        await registry.registerBuiltins()
        let all = await registry.all()
        // Verifying we have at least the P0 built-ins.
        let names = Set(all.map { $0.name })
        for required in [
            "read_file", "write_file", "edit_file", "apply_patch",
            "run_shell", "grep_code", "glob_files", "tool_search",
            // File-ops primitives — added to close gaps that agentic
            // models hallucinate (delete_file, move_file, create_directory).
            "delete_file", "move_file", "create_directory",
            // Xcode tooling registered in v1 (build/test + add-file-to-project).
            "xcode_build", "xcode_project_editor",
            "create_plan", "update_todo", "ask_user",
            // Wave B/C surfaces Settings must expose toggles for:
            "task", "get_task_output", "wait_tasks", "kill_task",
            "list_background_jobs", "monitor_jobs",
            "memory", "memory_search", "memory_get", "find_symbol",
            "load_skill", "revise_plan",
            "git_status", "git_diff", "git_commit", "create_pull_request",
            // ZCode-parity wave-2 registrations:
            "read_session_context",
            "cron_create", "cron_list", "cron_update", "cron_delete",
            "send_message",
            "enter_plan_mode", "exit_plan_mode",
        ] {
            XCTAssertTrue(names.contains(required), "Missing built-in tool: \(required)")
        }
    }

    func testDuplicateRegistrationIsIgnored() async {
        let registry = ToolRegistry.shared
        await registry.register(ReadFileTool.self)
        await registry.register(ReadFileTool.self)   // second is a no-op (warn-only)
        let metadata = await registry.metadata(for: "read_file")
        XCTAssertNotNil(metadata)
    }

    func testExecuteReadOnlyBatchRunsAllInvocations() async throws {
        let registry = ToolRegistry.shared
        await registry.registerBuiltins()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "hello".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let context = ToolContext(projectRoot: tmp, conversationID: UUID())
        let invocations: [(name: String, arguments: ToolArguments)] = [
            ("list_directory", try ToolArguments(json: #"{"path":"."}"#)),
            ("glob_files", try ToolArguments(json: #"{"pattern":"*.txt"}"#)),
            ("read_file", try ToolArguments(json: #"{"path":"a.txt"}"#)),
        ]

        let results = await registry.executeReadOnlyBatch(
            invocations: invocations, context: context)

        XCTAssertEqual(results.count, 3)
        XCTAssertFalse(results.contains(where: { $0.isError }))
        XCTAssertTrue(results[2].content.contains("hello"))
    }
}
