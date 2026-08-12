//
//  RestoreCheckpointTool.swift
//
//  restore_checkpoint — restore files from a turn filesystem checkpoint
//  (Phase A PA4). Same store as code-aware /rewind and /undo.
//

import Foundation

public struct RestoreCheckpointTool: Tool {
    public static let name = "restore_checkpoint"
    public static let category: ToolCategory = .agent
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Restore project files from the latest (or specified) turn checkpoint \
        taken before agent mutations this session. Prefer when the user asks \
        to undo code changes; chat /rewind also uses this store.
        """,
        parameters: .init(
            properties: [
                "turn_id": .init(
                    type: "string",
                    description: "Optional checkpoint turn UUID. Defaults to the latest unrestored turn."
                ),
            ],
            required: []
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let report: CheckpointRestoreReport
        if let raw = arguments.stringOptional("turn_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            guard let turnID = UUID(uuidString: raw) else {
                return ToolResult(
                    content: "restore_checkpoint: invalid turn_id UUID '\(raw)'.",
                    isError: true
                )
            }
            report = await CheckpointStore.shared.restore(
                turnID: turnID,
                conversationID: context.conversationID
            )
        } else {
            report = await CheckpointStore.shared.restoreLatest(
                conversationID: context.conversationID
            )
        }

        if report.turnID == nil && report.restoredFileCount == 0 {
            return ToolResult(
                content: "restore_checkpoint: \(report.statusSummary).",
                isError: true
            )
        }

        var lines: [String] = [
            "restore_checkpoint: \(report.statusSummary)."
        ]
        if let tid = report.turnID {
            lines.append("turn_id=\(tid.uuidString)")
        }
        if !report.restoredPaths.isEmpty {
            lines.append("restored: \(report.restoredPaths.joined(separator: ", "))")
        }
        if !report.deletedPaths.isEmpty {
            lines.append("removed: \(report.deletedPaths.joined(separator: ", "))")
        }
        if !report.failedPaths.isEmpty {
            let detail = report.failedPaths
                .map { "\($0.path) (\($0.reason))" }
                .joined(separator: "; ")
            lines.append("failed: \(detail)")
            return ToolResult(content: lines.joined(separator: "\n"), isError: true)
        }
        return ToolResult(
            content: lines.joined(separator: "\n"),
            mutatedPaths: report.restoredPaths + report.deletedPaths
        )
    }
}
