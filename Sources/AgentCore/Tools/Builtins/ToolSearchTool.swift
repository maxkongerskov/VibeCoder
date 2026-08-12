//
//  ToolSearchTool.swift
//
//  Lazy-reveal of deferred tools. The agent calls `tool_search(query)`
//  when it suspects a tool exists; the registry returns up to N
//  matching schemas, and the agent loop unlocks them on the conversation
//  so subsequent turns include them in the tools array.
//
//  Same idea as the original AgentOS, but here the deferred-vs-core
//  distinction is on the Tool protocol itself, not a parallel side-table.
//

import Foundation

public struct ToolSearchTool: Tool {
    public static let name = "tool_search"
    public static let category: ToolCategory = .agent
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Search for tools by keyword. Returns matching tool names and descriptions; subsequent turns will include those tools in the schema.",
        parameters: .init(
            properties: [
                "query": .init(type: "string", description: "Keyword to match in tool names and descriptions."),
                "limit": .init(type: "integer", description: "Max matches to return. Default 8.")
            ],
            required: ["query"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let query = (try arguments.string("query")).lowercased()
        let limit = arguments.intOptional("limit") ?? 8
        let all = await ToolRegistry.shared.all()
        let matches = Array(all.filter { meta in
            meta.name.lowercased().contains(query) || meta.schema.description.lowercased().contains(query)
        }.prefix(limit))
        if matches.isEmpty {
            return ToolResult(content: "No tools match '\(query)'.")
        }
        // Deferred names the agent loop should unlock on the conversation.
        // Core/platform tools are already in schemas — still list them for discovery.
        let deferredNames = matches.compactMap { meta -> String? in
            if case .deferred = meta.availability { return meta.name }
            return nil
        }
        let formatted = matches.map { meta in
            let avail: String = {
                switch meta.availability {
                case .core: return "core"
                case .deferred: return "deferred"
                case .platformGated: return "platform-gated"
                }
            }()
            return "\(meta.name) [\(meta.category.rawValue) · \(avail)]: \(meta.schema.description)"
        }.joined(separator: "\n")
        var content = "Matches (unlocked for this conversation):\n\(formatted)"
        if !deferredNames.isEmpty {
            content += "\n\nDeferred tools unlocked: \(deferredNames.joined(separator: ", "))"
        }
        // Side-channel for AgentLoop.recordToolResult — unlock set is applied
        // onto Conversation.unlockedDeferredTools so next schema assembly includes them.
        return ToolResult(
            content: content,
            extras: deferredNames.isEmpty
                ? [:]
                : ["unlocked_deferred": deferredNames.joined(separator: ",")]
        )
    }
}
