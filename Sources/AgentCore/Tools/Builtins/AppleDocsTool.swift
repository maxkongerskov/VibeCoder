//
//  AppleDocsTool.swift
//
//  Apple Developer documentation search.
//
//  developer.apple.com is JavaScript-rendered, so a direct scrape
//  returns no results. Instead we delegate to web_search with a
//  `site:developer.apple.com/documentation` filter (optionally narrowed
//  to a specific framework path). The model can then call `fetch_url`
//  on any result to read the actual symbol page.
//
//  This inherits whatever search provider WebSearchTool resolves to —
//  no separate DocC cache, no reverse-engineering of Apple's
//  undocumented search endpoint.
//

import Foundation

public struct AppleDocsTool: Tool {
    public static let name = "apple_docs"
    public static let category: ToolCategory = .search
    public static let permission: ToolPermission = .network
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Search Apple Developer documentation (developer.apple.com/documentation). \
        Delegates to web_search with a site: filter. Pass `framework` to narrow \
        results to one framework (e.g. \"swiftui\", \"foundation\"). Follow up \
        with fetch_url on any returned symbol URL to read the full page.
        """,
        parameters: .init(
            properties: [
                "query": .init(type: "string", description: "What to look for in Apple's docs."),
                "framework": .init(type: "string", description: "Optional framework path under /documentation/ (e.g. 'swiftui')."),
                "provider": .init(
                    type: "string",
                    description: "Optional pass-through to web_search provider.",
                    enum: ["brave", "serpapi", "duckduckgo"]
                ),
                "apiKey": .init(type: "string", description: "Optional pass-through API key for the search provider.")
            ],
            required: ["query"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let raw = try arguments.string("query")
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return ToolResult(content: "Error: query is empty.", isError: true)
        }

        var sitePath = "site:developer.apple.com/documentation"
        if let fw = arguments.stringOptional("framework")?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased(), !fw.isEmpty {
            let sanitized = fw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
            if !sanitized.isEmpty { sitePath += "/\(sanitized)" }
        }

        let combined = "\(sitePath) \(q)"

        // Build a synthetic ToolArguments dict carrying the combined query
        // (plus passthrough provider/apiKey) and call WebSearchTool.
        var passthrough: [String: Any] = ["query": combined]
        if let provider = arguments.stringOptional("provider") {
            passthrough["provider"] = provider
        }
        if let key = arguments.stringOptional("apiKey") {
            passthrough["apiKey"] = key
        }
        let inner = ToolArguments(dictionary: passthrough)
        return try await WebSearchTool().execute(arguments: inner, context: context)
    }
}
