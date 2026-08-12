//
//  MemoryGetTool.swift
//

import Foundation

public struct MemoryGetTool: Tool {
    public static let name = "memory_get"
    public static let category: ToolCategory = .memory
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Fetch a full memory chunk by id from a prior memory_search result.",
        parameters: .init(
            properties: [
                "chunk_id": .init(type: "string", description: "Chunk id from memory_search.")
            ],
            required: ["chunk_id"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let id = try arguments.string("chunk_id")
        let backend = MemoryBackend(workspacePath: context.workingDirectory)
        guard let chunk = backend.get(chunkId: id) else {
            return ToolResult(content: "Unknown chunk_id: \(id)", isError: true)
        }
        return ToolResult(content: """
        # Memory chunk \(chunk.id)
        source: \(chunk.source)
        path: \(chunk.path)
        lines: \(chunk.startLine)-\(chunk.endLine)

        \(chunk.text)
        """)
    }
}
