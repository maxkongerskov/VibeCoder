//
//  GrepCodeTool.swift
//
//  Regex search over project files. Uses `/usr/bin/grep -RnE` to avoid
//  reinventing a regex engine and to inherit the perf of native grep.
//  When LSP is available (P3), `find_references` is preferred; this is
//  the universal fallback.
//

import Foundation

public struct GrepCodeTool: Tool {
    public static let name = "grep_code"
    public static let category: ToolCategory = .search
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Search files for an extended regex pattern. Returns matching lines with file:line prefixes.",
        parameters: .init(
            properties: [
                "pattern": .init(type: "string", description: "Extended regex (-E)."),
                "path": .init(type: "string", description: "Directory to search. Default project root."),
                "include": .init(type: "string", description: "Glob filter (passed to --include). E.g. '*.swift'."),
                "maxResults": .init(type: "integer", description: "Cap on lines returned. Default 200.")
            ],
            required: ["pattern"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let pattern = try arguments.string("pattern")
        let path = arguments.stringOptional("path") ?? "."
        let include = arguments.stringOptional("include")
        let maxResults = arguments.intOptional("maxResults") ?? 200
        let target = resolvePath(path, base: context.workingDirectory)

        var args = ["-RnE", pattern, target.path]
        if let inc = include { args.append("--include=\(inc)") }

        let result = ShellRunner.run(executable: "/usr/bin/grep", arguments: args, timeout: 30)
        // grep returns 1 when no matches; treat as success-with-empty.
        if result.exitCode != 0 && result.exitCode != 1 {
            return ToolResult(content: "grep failed: \(result.stderr)", isError: true)
        }
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        let capped = lines.prefix(maxResults).joined(separator: "\n")
        let truncated = lines.count > maxResults
            ? "\n… [\(lines.count - maxResults) more results — narrow your pattern or use 'include']"
            : ""
        return ToolResult(content: capped.isEmpty ? "(no matches)" : capped + truncated)
    }
}
