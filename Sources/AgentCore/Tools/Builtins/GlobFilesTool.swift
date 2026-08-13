//
//  GlobFilesTool.swift
//

import Foundation

public struct GlobFilesTool: Tool {
    public static let name = "glob_files"
    public static let category: ToolCategory = .search
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Find files by glob pattern. Returns matching paths sorted by modification time (newest first).",
        parameters: .init(
            properties: [
                "pattern": .init(type: "string", description: "Glob pattern. E.g. '**/*.swift' or 'Sources/**/Backend*.swift'."),
                "path": .init(type: "string", description: "Root to search. Default project root.")
            ],
            required: ["pattern"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let pattern = try arguments.string("pattern")
        let basePath = arguments.stringOptional("path") ?? "."
        let base = resolvePath(basePath, base: context.workingDirectory)
        let matches = try expandGlob(pattern: pattern, baseDirectory: base)
        let sorted = matches.sorted { (a, b) in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
        let result = sorted.map { $0.path.replacingOccurrences(of: base.path + "/", with: "") }
            .joined(separator: "\n")
        return ToolResult(content: result.isEmpty ? "(no matches)" : result)
    }

    /// Minimal glob implementation. Supports ** (any depth) and * (one
    /// segment). Sufficient for the common cases the agent generates;
    /// when we need full fnmatch semantics we'll wrap glibc's `glob(3)`.
    private func expandGlob(pattern: String, baseDirectory: URL) throws -> [URL] {
        let regexPattern = "^" + globToRegex(pattern) + "$"
        let regex = try NSRegularExpression(pattern: regexPattern)
        var results: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let basePath = baseDirectory.standardizedFileURL.path
            let urlPath = url.standardizedFileURL.path
            let rel: String
            if urlPath == basePath {
                rel = url.lastPathComponent
            } else if urlPath.hasPrefix(basePath + "/") {
                rel = String(urlPath.dropFirst(basePath.count + 1))
            } else {
                rel = url.path.replacingOccurrences(of: baseDirectory.path + "/", with: "")
            }
            let range = NSRange(rel.startIndex..., in: rel)
            if regex.firstMatch(in: rel, options: [], range: range) != nil {
                results.append(url)
            }
        }
        return results
    }

    private func globToRegex(_ glob: String) -> String {
        var out = ""
        var i = glob.startIndex
        while i < glob.endIndex {
            let c = glob[i]
            if c == "*" {
                let next = glob.index(after: i)
                if next < glob.endIndex && glob[next] == "*" {
                    i = glob.index(after: next)
                    // **/*.swift → any directory prefix + rest of pattern
                    if i < glob.endIndex && glob[i] == "/" {
                        out += "(?:.*/)?"
                        i = glob.index(after: i)
                    } else {
                        // trailing ** or ** alone must match files at any depth
                        out += ".*"
                    }
                    continue
                }
                out += "[^/]*"
            } else if c == "?" {
                out += "[^/]"
            } else if ".+()[]{}|^$\\".contains(c) {
                out += "\\\(c)"
            } else {
                out += String(c)
            }
            i = glob.index(after: i)
        }
        return out
    }
}
