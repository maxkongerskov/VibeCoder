//
//  MemorySearchTool.swift
//

import Foundation

public struct MemorySearchTool: Tool {
    public static let name = "memory_search"
    public static let category: ToolCategory = .memory
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Search cross-session project memory (hybrid keyword recall). Returns relevant snippets with source tags.",
        parameters: .init(
            properties: [
                "query": .init(type: "string", description: "Natural language or keyword query."),
                "max_results": .init(type: "integer", description: "Max hits (1-20). Default 8.")
            ],
            required: ["query"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let query = try arguments.string("query")
        let max = min(20, max(1, arguments.intOptional("max_results") ?? 8))
        let root = context.workingDirectory
        let backend = MemoryBackend(workspacePath: root)
        let hits = backend.search(query: query, maxResults: max)
        if hits.isEmpty {
            return ToolResult(content: "No memory hits for query: \(query)")
        }
        var lines: [String] = ["# Memory search results for: \(query)"]
        for (i, h) in hits.enumerated() {
            lines.append("\(i+1). [\(h.chunk.source)] score=\(String(format: "%.2f", h.score)) id=\(h.chunk.id)")
            lines.append("   \(h.snippet.replacingOccurrences(of: "\n", with: " "))")
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }
}
