//
//  ReadFileTool.swift
//  Read the contents of a file under the project root.
//

import Foundation

public struct ReadFileTool: Tool {
    public static let name = "read_file"
    public static let category: ToolCategory = .filesystem
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Read the contents of a file. Returns up to maxLines lines starting at offset (1-indexed).",
        parameters: .init(
            properties: [
                "path": .init(type: "string", description: "Path relative to project root, or absolute."),
                "offset": .init(type: "integer", description: "1-indexed starting line. Default 1."),
                "maxLines": .init(type: "integer", description: "Max lines to return. Default 2000.")
            ],
            required: ["path"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let path = try arguments.string("path")
        let offset = arguments.intOptional("offset") ?? 1
        let maxLines = arguments.intOptional("maxLines") ?? 2000

        let url = resolvePath(path, base: context.workingDirectory)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return ToolResult(content: "Error reading \(path): \(error.localizedDescription)", isError: true)
        }
        // Session read tracker — enables read-before-edit on mutate tools.
        await SessionReadTracker.shared.recordRead(
            path: url.path, conversationID: context.conversationID)
        guard let text = String(data: data, encoding: .utf8) else {
            return ToolResult(content: "File at \(path) is not valid UTF-8 (size: \(data.count) bytes)", isError: true)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let startIdx = max(0, offset - 1)
        let safeMax = max(0, maxLines)
        let endIdx: Int
        if safeMax == 0 || startIdx >= lines.count {
            endIdx = startIdx
        } else if startIdx > lines.count - safeMax {
            endIdx = lines.count
        } else {
            endIdx = startIdx + safeMax
        }
        guard startIdx < lines.count else {
            return ToolResult(content: "File has \(lines.count) lines; offset \(offset) is past end.", isError: false)
        }
        let slice = lines[startIdx..<endIdx]
        // Prefix line numbers so the model can construct accurate patches.
        let numbered = slice.enumerated().map { (i, line) in
            "\(String(format: "%5d", startIdx + i + 1)) | \(line)"
        }.joined(separator: "\n")
        let suffix = endIdx < lines.count ? "\n… [\(lines.count - endIdx) more lines]" : ""
        return ToolResult(content: numbered + suffix)
    }
}

/// Resolve a tool-supplied path against the conversation's working
/// directory. Handles three forms:
///   • `~/...`           — expanded via NSString.expandingTildeInPath
///                         (matches `$HOME` in the user's shell).
///   • `/...`            — absolute, used as-is.
///   • anything else     — relative to `base` (the project / worktree
///                         root supplied by ToolContext.workingDirectory).
///
/// Without the tilde branch the path `~/Desktop/foo` becomes
/// `<workingdir>/~/Desktop/foo` — invalid — which manifests as
/// "volume is read only" or similar opaque write errors. Same family
/// of bug as the `~` issue in `ShellRunner` (fixed by inheriting
/// process env); the file tools need their own expansion since they
/// don't go through a shell.
func resolvePath(_ path: String, base: URL) -> URL {
    // Empty path means "the working directory itself" (list/status style).
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return URL(fileURLWithPath: (base.path as NSString).standardizingPath)
    }
    let absolute: String
    if trimmed.hasPrefix("~") {
        absolute = (trimmed as NSString).expandingTildeInPath
    } else if trimmed.hasPrefix("/") {
        absolute = trimmed
    } else {
        // Join under base, then standardize `..` / `.` segments.
        // Do NOT use `URL(fileURLWithPath:relativeTo:).standardizedFileURL` —
        // that can drop the base directory and resolve against `/tmp` (or CWD),
        // causing PathConfinement false denies for in-project relative paths.
        absolute = base.appendingPathComponent(trimmed).path
    }
    let standardized = (absolute as NSString).standardizingPath
    return URL(fileURLWithPath: standardized)
}
