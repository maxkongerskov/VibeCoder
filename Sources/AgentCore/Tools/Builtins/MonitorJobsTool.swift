//
//  MonitorJobsTool.swift
//
//  Depth D4 — Agent-callable listing of in-app background jobs.
//  Wraps JobMonitor / BackgroundJobManager. Read-only.
//
//  Honesty: not a Grok Build monitor product (no arbitrary process watch,
//  no multi-host streams). Only shell + subagent jobs registered in-app.
//

import Foundation

/// List background shell/subagent jobs (agent-callable).
public struct ListBackgroundJobsTool: Tool {
    public static let name = "list_background_jobs"
    public static let category: ToolCategory = .agent
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core

    public static let schema = ToolSchema(
        name: name,
        description: """
        List in-app background jobs (shell with background=true, or task run_in_background). \
        Read-only. Not a full process monitor — only jobs started by this agent session. \
        Use get_task_output / wait_tasks / kill_task with a task_id for details.
        """,
        parameters: .init(
            properties: [
                "running_only": .init(
                    type: "boolean",
                    description: "If true (default), only running jobs. If false, include completed/failed still retained for this conversation."
                ),
                "conversation_scoped": .init(
                    type: "boolean",
                    description: "If true (default), only jobs for the current conversation. If false, all running jobs in the process."
                ),
            ],
            required: []
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let runningOnly = arguments.bool("running_only", default: true)
        let scoped = arguments.bool("conversation_scoped", default: true)
        let text = await Self.format(
            runningOnly: runningOnly,
            conversationID: scoped ? context.conversationID : nil
        )
        return ToolResult(content: text, isError: false)
    }

    /// Shared formatter for list_background_jobs + monitor_jobs.
    public static func format(
        runningOnly: Bool,
        conversationID: UUID?,
        manager: BackgroundJobManager = .shared,
        now: Date = Date()
    ) async -> String {
        let entries: [JobMonitor.Entry]
        if let conversationID {
            var list = await JobMonitor.list(
                conversationID: conversationID, manager: manager, now: now)
            if runningOnly {
                list = list.filter { $0.snapshot.status == .running }
            }
            entries = list
        } else {
            entries = await JobMonitor.listRunning(manager: manager, now: now)
        }
        return JobMonitor.formatList(entries)
    }
}

/// Alias name for models that expect `monitor_jobs` (same behavior as list_background_jobs).
public struct MonitorJobsTool: Tool {
    public static let name = "monitor_jobs"
    public static let category: ToolCategory = .agent
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core

    public static let schema = ToolSchema(
        name: name,
        description: """
        Alias of list_background_jobs: list in-app background shell/subagent jobs. \
        Read-only. Not a full Grok-style monitor product.
        """,
        parameters: .init(
            properties: [
                "running_only": .init(
                    type: "boolean",
                    description: "If true (default), only running jobs."
                ),
                "conversation_scoped": .init(
                    type: "boolean",
                    description: "If true (default), only current conversation jobs."
                ),
            ],
            required: []
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        try await ListBackgroundJobsTool().execute(arguments: arguments, context: context)
    }
}
