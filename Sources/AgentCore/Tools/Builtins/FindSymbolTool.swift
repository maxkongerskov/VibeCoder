//
//  FindSymbolTool.swift
//
//  Code navigation: optional SourceKit-LSP (definition / references /
//  workspace_symbol), otherwise SymbolIndex text scan.
//  Every result labels backend as lsp | text-index — not a full IDE.
//

import Foundation

public struct FindSymbolTool: Tool {
    public static let name = "find_symbol"
    public static let category: ToolCategory = .search
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Find symbols under the project root. When SourceKit-LSP is installed, \
        may use textDocument/definition, textDocument/references, or \
        workspace/symbol for the requested action. Otherwise (or on empty/error) \
        falls back to a SymbolIndex substring scan. Every result includes \
        `backend: lsp` or `backend: text-index` and an honesty line — this is \
        not full IDE navigation (no multi-language host, no diagnostics UI, \
        no permanent language-server pool).
        """,
        parameters: .init(
            properties: [
                "symbol": .init(
                    type: "string",
                    description: "Symbol name or text to find (required for workspace_symbol / text fallback)."
                ),
                "action": .init(
                    type: "string",
                    description: "definition | references | workspace_symbol (default workspace_symbol)."
                ),
                "path": .init(
                    type: "string",
                    description: "File path for definition/references (absolute or project-relative)."
                ),
                "line": .init(
                    type: "integer",
                    description: "1-based line for definition/references. If omitted, inferred from first text hit when possible."
                ),
                "character": .init(
                    type: "integer",
                    description: "0-based column for definition/references. Default 0 or symbol offset on the line."
                ),
                "max_results": .init(type: "integer", description: "Max hits. Default 20, cap 50."),
            ],
            required: ["symbol"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let symbol = try arguments.string("symbol")
        let action = CodeNavAction.parse(arguments.stringOptional("action"))
        let path = arguments.stringOptional("path")
        let line = arguments.intOptional("line")
        let character = arguments.intOptional("character")
        let max = min(50, max(1, arguments.intOptional("max_results") ?? 20))

        let result = await CodeNavService.navigate(
            action: action,
            symbol: symbol,
            projectRoot: context.workingDirectory,
            filePath: path,
            line: line,
            character: character,
            maxResults: max
        )

        // Single formatter guarantees backend: lsp|text-index on every path
        // (hits and empty), including honesty line — P5 string contract.
        return ToolResult(content: result.formatToolOutput(symbol: symbol), isError: false)
    }
}
