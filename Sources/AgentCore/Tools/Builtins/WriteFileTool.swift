//
//  WriteFileTool.swift
//
//  Whole-file write. P0 keeps this as the universal fallback; the agent
//  system prompt teaches "use edit_file first, write_file only for new
//  files or full rewrites." This ordering matches Claude Code's defaults.
//
//  Wave B (S5): overwriting an existing file requires read-before-edit
//  (same SessionReadTracker as edit_file). Creating a new file does not.
//

import Foundation

public struct WriteFileTool: Tool {
    public static let name = "write_file"
    public static let category: ToolCategory = .filesystem
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Write the entire contents of a file. Creates parent directories if needed. Prefer edit_file for edits to existing files. Overwriting an existing file requires a prior read_file in this conversation (read-before-edit).",
        parameters: .init(
            properties: [
                "path": .init(type: "string", description: "Path relative to project root, or absolute."),
                "content": .init(type: "string", description: "Full file content to write.")
            ],
            required: ["path", "content"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let path = try arguments.string("path")
        let content = try arguments.string("content")
        let url = resolvePath(path, base: context.workingDirectory)
        try await PathConfinement.requireInsideWorkspaceAsync(
            path: path, resolved: url, context: context)

        let fileExisted = FileManager.default.fileExists(atPath: url.path)
        let original: String
        if fileExisted {
            let sessionOk = await SessionReadTracker.shared.hasSessionRead(
                path: url.path,
                conversationID: context.conversationID,
                sessionReadPaths: context.sessionReadPaths)
            if !sessionOk {
                return ToolResult(
                    content: "write_file: read-before-edit required to overwrite an existing file. "
                        + "Call `read_file` on \(path) first, or use a new path to create a file.",
                    isError: true
                )
            }
            // Fail closed on unreadable existing file (do not treat as empty create).
            do {
                original = try String(contentsOf: url, encoding: .utf8)
            } catch {
                return ToolResult(
                    content: "write_file: failed to read existing file \(path) — \(error.localizedDescription). No files modified.",
                    isError: true
                )
            }
            if original == content {
                return ToolResult(
                    content: "write_file: content unchanged for \(path). No files modified.",
                    isError: true
                )
            }
        } else {
            original = ""
        }
        // Ask mode: surface the write in the patch-review sheet first.
        try await MutationReview.requireApproval(
            path: path, original: original, updated: content, context: context)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let hunk = TrackedHunk(
            conversationID: context.conversationID,
            path: url.path,
            originalContent: original,
            updatedContent: content)
        await HunkTracker.shared.record(hunk)
        return ToolResult(
            content: "Wrote \(content.utf8.count) bytes to \(path). hunk_id=\(hunk.id.uuidString)",
            mutatedPaths: [path])
    }
}
