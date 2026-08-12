//
//  ToolSchemaAssembler.swift
//
//  Assembles the base tool schema list offered to the model before
//  per-iteration pruning. Extracted from `AgentLoop.run` for testing.
//

import Foundation

public enum ToolSchemaAssembler {

    /// Tools allowed in **Chat mode** (rawMode): pure conversation plus
    /// web search and document read. No shell, edit, MCP, or agent harness.
    ///
    /// There is no separate RAG subsystem — reading a document is
    /// `read_file` (path the user names, or a project file). Chat
    /// attachments are already inlined into the user message by the UI.
    public static let chatModeAllowedToolNames: Set<String> = [
        "web_search",
        "read_file",
    ]

    /// Core + deferred schemas, minus disabled tools and builtins
    /// superseded by live Xcode MCP tools.
    ///
    /// Chat mode (`config.rawMode`): only `web_search` + `read_file`
    /// (each still respects `disabledToolNames`). No MCP in chat mode.
    ///
    /// - Parameter mcpSchemas: Optional user-MCP tool schemas
    ///   (`server__tool` names from `MCPServerPool.toolSchemas()`).
    ///   Merged after builtins so the model can call them (agent mode only).
    public static func baseSchemas(
        registry: ToolRegistry,
        conversation: Conversation,
        config: AgentLoop.Configuration,
        mcpSchemas: [ToolSchema] = []
    ) async -> [ToolSchema] {
        // Chat mode: web access only — no coding tools, no MCP.
        if config.rawMode {
            let all = await registry.schemas()
            return all.filter {
                chatModeAllowedToolNames.contains($0.name)
                    && !config.disabledToolNames.contains($0.name)
            }
        }

        let allCoreSchemas = await registry.schemas()
        let allDeferredSchemas = await registry.schemas(
            activeNames: Set(conversation.unlockedDeferredTools),
            includeDeferred: true)
        var schemas = (allCoreSchemas + allDeferredSchemas)
            .filter { !config.disabledToolNames.contains($0.name) }
        if config.xcodeMCPEnabled {
            // P0: hide overlapping builtins when Xcode MCP tools are live.
            schemas = schemas.filter {
                !ChatLoop.xcodeMCPSupersededBuiltins.contains($0.name)
            }
        }
        // Append user MCP tools (namespaced). Skip disabled names and
        // any that collide with a builtin (builtin wins).
        if !mcpSchemas.isEmpty {
            let existing = Set(schemas.map(\.name))
            for schema in mcpSchemas {
                if config.disabledToolNames.contains(schema.name) { continue }
                if existing.contains(schema.name) { continue }
                schemas.append(schema)
            }
        }
        return schemas
    }

    /// Merge MCP schemas into an already-built base list (same rules as
    /// `baseSchemas` MCP arm). Pure helper for tests and late inject.
    public static func mergeMCPSchemas(
        into base: [ToolSchema],
        mcpSchemas: [ToolSchema],
        disabledToolNames: Set<String> = []
    ) -> [ToolSchema] {
        guard !mcpSchemas.isEmpty else { return base }
        var schemas = base
        let existing = Set(schemas.map(\.name))
        for schema in mcpSchemas {
            if disabledToolNames.contains(schema.name) { continue }
            if existing.contains(schema.name) { continue }
            schemas.append(schema)
        }
        return schemas
    }
}