//
//  CreateDirectoryTool.swift
//
//  Make a directory (including any missing parents). Closes the third
//  obvious file-ops gap. Without it, models that need a fresh folder
//  fall back to `run_shell mkdir -p ...` which works but a) routes
//  around the path allow-list when Safe Mode is on, and b) reads as
//  shell noise in the transcript instead of a clean intent line.
//
//  Idempotent — creating a directory that already exists is a no-op
//  rather than an error. That matches `mkdir -p` semantics and stops
//  the agent loop from tripping on "already exists" errors when it
//  re-runs setup steps.
//

import Foundation

public struct CreateDirectoryTool: Tool {
    public static let name = "create_directory"
    public static let category: ToolCategory = .filesystem
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Create a directory, including any missing parent directories. No-op if the directory already exists. Equivalent to `mkdir -p`.",
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
        let fm = FileManager.default

        // If the path already exists but as a FILE, fail loudly. Silently
        // succeeding would mask a real bug ("I tried to make a folder
        // called Models but there's already a Models file") and the next
        // tool call that assumed a directory would error confusingly.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                return ToolResult(content: "Directory already exists at \(path).", mutatedPaths: [])
            } else {
                throw ToolError.invalidArguments(
                    "Path exists but is a file, not a directory: \(path)"
                )
            }
        }

        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return ToolResult(
            content: "Created directory \(path).",
            mutatedPaths: [path]
        )
    }
}
