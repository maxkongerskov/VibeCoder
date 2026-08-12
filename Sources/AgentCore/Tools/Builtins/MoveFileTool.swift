//
//  MoveFileTool.swift
//
//  Move or rename a file or directory. Closes the second of the three
//  obvious file-ops gaps in the built-in toolset. Agentic models often
//  emit `move_file` (or `rename_file`) when restructuring a project;
//  without the tool they fall back to `run_shell mv ...` which works
//  but bypasses the permission system's path allow-list and reads
//  less cleanly in the chat transcript.
//
//  Creates intermediate destination directories if needed (matches
//  what `mv` would do given a path with new directories). Refuses to
//  overwrite an existing destination unless `overwrite=true`, so the
//  agent has to opt in to clobbering — the same kind of guardrail
//  Finder uses when you drag a file onto a duplicate name.
//

import Foundation

public struct MoveFileTool: Tool {
    public static let name = "move_file"
    public static let category: ToolCategory = .filesystem
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Move or rename a file or directory. Creates parent directories at the destination if missing. Refuses to overwrite by default — pass overwrite=true to replace an existing destination.",
        parameters: .init(
            properties: [
                "source":      .init(type: "string", description: "Path of the file or directory to move."),
                "destination": .init(type: "string", description: "New path. Parent directories are created automatically."),
                "overwrite":   .init(type: "boolean", description: "Optional. Pass true to replace an existing destination. Default false.")
            ],
            required: ["source", "destination"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let source      = try arguments.string("source")
        let destination = try arguments.string("destination")
        // Accept boolean or string "true"/"false" (models mix both).
        let overwrite   = arguments.bool("overwrite", default: false)

        let srcURL = resolvePath(source, base: context.workingDirectory)
        let dstURL = resolvePath(destination, base: context.workingDirectory)
        try await PathConfinement.requireInsideWorkspaceAsync(
            path: source, resolved: srcURL, context: context)
        try await PathConfinement.requireInsideWorkspaceAsync(
            path: destination, resolved: dstURL, context: context)
        let fm = FileManager.default

        guard fm.fileExists(atPath: srcURL.path) else {
            throw ToolError.invalidArguments("Source does not exist: \(source)")
        }

        try await MutationReview.requireApproval(
            path: "\(source) → \(destination)",
            original: "Source: \(source)",
            updated: "Destination: \(destination)\(overwrite ? " (overwrite)" : "")",
            context: context)

        // Make sure the destination's parent exists before the move,
        // otherwise FileManager errors with a confusing NSCocoaErrorDomain
        // code instead of telling the model "the parent dir is missing".
        try fm.createDirectory(
            at: dstURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fm.fileExists(atPath: dstURL.path) {
            guard overwrite else {
                throw ToolError.invalidArguments(
                    "Destination exists: \(destination). Pass overwrite=true to replace it."
                )
            }
            try fm.removeItem(at: dstURL)
        }

        try fm.moveItem(at: srcURL, to: dstURL)
        return ToolResult(
            content: "Moved \(source) → \(destination).",
            mutatedPaths: [source, destination]
        )
    }
}
