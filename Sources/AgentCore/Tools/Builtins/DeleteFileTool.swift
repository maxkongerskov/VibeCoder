//
//  DeleteFileTool.swift
//
//  Remove a file or directory. Closes one of the obvious gaps in the
//  built-in toolset: without `delete_file`, agentic models that have
//  been trained on a delete primitive will hallucinate the tool name
//  ("I'll remove the old file…") and bounce off ToolRegistry's
//  "unknown tool" error. Adding it lets the agent loop self-recover
//  instead of stumbling.
//
//  Recursive by default for directories — matches `rm -rf` semantics
//  the model is most likely to expect. Single files are removed
//  whether the `recursive` flag is set or not (no harm). Refuses to
//  delete the working-directory root itself as a guardrail against
//  the worst kind of model slip ("delete .").
//
//  Safe Mode (when active) gates this through ToolRegistry's
//  permission check via the `.mutates` permission and the path
//  allow-list; nothing tool-specific needed here.
//

import Foundation

public struct DeleteFileTool: Tool {
    public static let name = "delete_file"
    public static let category: ToolCategory = .filesystem
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Delete a file or directory. Directory deletion is recursive (like `rm -rf`). Returns an error if the path doesn't exist.",
        parameters: .init(
            properties: [
                "path": .init(type: "string",
                              description: "Absolute or ~/relative path, or relative to the working directory.")
            ],
            required: ["path"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let path = try arguments.string("path")
        let url = resolvePath(path, base: context.workingDirectory)
        try await PathConfinement.requireInsideWorkspaceAsync(
            path: path, resolved: url, context: context)

        // Guardrail: refuse to delete the working-directory root. If the
        // model emits `delete_file path="."` (rare but happens), nuking
        // the whole project would be catastrophic and unrecoverable.
        //
        // Comparison strategy — fully resolve BOTH sides to canonical
        // paths (no symlinks, no "." segments, no trailing slashes) and
        // compare the strings. `URL.standardizedFileURL` alone leaves
        // some "." components intact and `==` on URL objects sometimes
        // diverges on cosmetic differences. `resolvingSymlinksInPath`
        // normalises everything to the form `realpath(3)` would return.
        let resolvedPath = url.resolvingSymlinksInPath().path
        let workingPath  = context.workingDirectory.resolvingSymlinksInPath().path
        if resolvedPath == workingPath {
            throw ToolError.invalidArguments(
                "Refusing to delete the working directory itself (\(url.path))."
            )
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ToolError.invalidArguments("Path does not exist: \(path)")
        }

        let original = isDir.boolValue
            ? "[directory] \(path)"
            : ((try? String(contentsOf: url, encoding: .utf8)) ?? "[binary or unreadable file]")
        try await MutationReview.requireApproval(
            path: path,
            original: original,
            updated: "",
            context: context)

        try fm.removeItem(at: url)
        let kind = isDir.boolValue ? "directory" : "file"
        return ToolResult(
            content: "Deleted \(kind) at \(path).",
            mutatedPaths: [path]
        )
    }
}
