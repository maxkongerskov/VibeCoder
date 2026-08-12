//
//  WebSearchTool.swift
//
//  General-purpose web search. Supports three providers, selected via
//  args or environment:
//    • Brave Search — paid free tier (2000 q/mo), reliable JSON.
//    • SerpAPI      — paid, JSON, very reliable.
//    • DuckDuckGo   — no key, scrapes html.duckduckgo.com (fragile).
//
//  API keys are NOT hardcoded. Resolution order:
//    1. `apiKey`        arg (per-call override)
//    2. `provider`-specific env var:
//         BRAVE_SEARCH_API_KEY / SERPAPI_KEY
//    3. fall back to DuckDuckGo (no key required)
//
//  When the chosen provider has no key configured, returns a clear
//  empty-results message rather than throwing.
//

import Foundation

public struct WebSearchTool: Tool {
    public static let name = "web_search"
    public static let category: ToolCategory = .search
    public static let permission: ToolPermission = .network
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Search the public web. Providers: brave (default if key set), serpapi, \
        duckduckgo (no key). The API key is read from the `apiKey` arg, then \
        from BRAVE_SEARCH_API_KEY / SERPAPI_KEY env vars. Returns a JSON array \
        of {title, url, snippet} or a plain-text status when no results / no key.
        """,
        parameters: .init(
            properties: [
                "query": .init(type: "string", description: "Search query."),
                "provider": .init(
                    type: "string",
                    description: "Search provider. Defaults to brave if BRAVE_SEARCH_API_KEY is set, otherwise duckduckgo.",
                    enum: ["brave", "serpapi", "duckduckgo"]
                ),
                "apiKey": .init(type: "string", description: "Optional override of the provider API key.")
            ],
            required: ["query"]
        )
    )

    public struct SearchResult: Codable, Sendable {
        public let title: String
        public let url: String
        public let snippet: String
    }

    public enum Provider: String, Sendable {
        case brave, serpAPI, duckDuckGo
    }

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let query = try arguments.string("query")
        let providerArg = arguments.stringOptional("provider")?.lowercased()
        let env = ProcessInfo.processInfo.environment

        let provider: Provider
        switch providerArg {
        case "brave":      provider = .brave
        case "serpapi":    provider = .serpAPI
        case "duckduckgo": provider = .duckDuckGo
        default:
            // Auto: prefer brave if a key is present, else DDG.
            provider = (env["BRAVE_SEARCH_API_KEY"] ?? "").isEmpty ? .duckDuckGo : .brave
        }

        let apiKeyArg = arguments.stringOptional("apiKey") ?? ""

        let body: String
        switch provider {
        case .brave:
            let key = apiKeyArg.isEmpty ? (env["BRAVE_SEARCH_API_KEY"] ?? "") : apiKeyArg
            body = await Self.brave(query: query, key: key)
        case .serpAPI:
            let key = apiKeyArg.isEmpty ? (env["SERPAPI_KEY"] ?? "") : apiKeyArg
            body = await Self.serpAPI(query: query, key: key)
        case .duckDuckGo:
            body = await Self.duckDuckGo(query: query)
        }
        return ToolResult(content: body)
    }

    // MARK: - Brave Search

    /// Brave Search API — free tier 2000 queries/month, 1 qps.
    private static func brave(query: String, key: String) async -> String {
        guard !key.isEmpty else {
            return "Brave Search API key not configured. Set BRAVE_SEARCH_API_KEY env var, or pass apiKey. Get one free at https://api.search.brave.com."
        }
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(enc)&count=10") else {
            return "Invalid URL"
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 422 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    let hint = body.contains("missing") ? "missing"
                             : body.contains("invalid") ? "invalid"
                             : "rejected"
                    return "Brave Search auth failed (HTTP \(http.statusCode), token \(hint)). Verify the API key."
                }
                if http.statusCode == 429 {
                    return "Brave Search rate limit hit (HTTP 429). Free tier is 1 query/second; wait a moment."
                }
                return "Error: HTTP \(http.statusCode) from Brave Search API."
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let web = json["web"] as? [String: Any],
                  let results = web["results"] as? [[String: Any]] else {
                return "No results"
            }
            let parsed = results.prefix(10).map {
                SearchResult(
                    title: ($0["title"] as? String) ?? "",
                    url: ($0["url"] as? String) ?? "",
                    snippet: ($0["description"] as? String) ?? ""
                )
            }
            return parsed.isEmpty ? "No results for: \(query)" : encode(Array(parsed))
        } catch {
            return "Brave Search error: \(error.localizedDescription)"
        }
    }

    private static func serpAPI(query: String, key: String) async -> String {
        guard !key.isEmpty else {
            return "SerpAPI key not configured. Set SERPAPI_KEY env var, or pass apiKey."
        }
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://serpapi.com/search?q=\(enc)&api_key=\(key)&num=5") else { return "Invalid URL" }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let organic = json["organic_results"] as? [[String: Any]] else { return "No results" }
            let results = organic.prefix(5).map {
                SearchResult(title: $0["title"] as? String ?? "",
                             url: $0["link"] as? String ?? "",
                             snippet: $0["snippet"] as? String ?? "")
            }
            return encode(Array(results))
        } catch { return "Search error: \(error.localizedDescription)" }
    }

    private static func duckDuckGo(query: String) async -> String {
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(enc)") else { return "Invalid URL" }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let html = String(data: data, encoding: .utf8) else { return "Error: bad encoding" }
            let results = parseDDGResults(html: html, limit: 5)
            return results.isEmpty
                ? "No results for: \(query). (DuckDuckGo returned an empty page — possibly rate-limited or layout changed. Try a different provider.)"
                : encode(results)
        } catch { return "Search error: \(error.localizedDescription)" }
    }

    // MARK: - DDG HTML parser

    private static func parseDDGResults(html: String, limit: Int) -> [SearchResult] {
        let titlePattern   = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#
        let snippetPattern = #"<a[^>]*class="result__snippet"[^>]*>([\s\S]*?)</a>"#

        let titles   = matches(in: html, pattern: titlePattern, groups: 2)
        let snippets = matches(in: html, pattern: snippetPattern, groups: 1)

        var results: [SearchResult] = []
        for (i, t) in titles.prefix(limit).enumerated() {
            let rawURL = t[0]
            let rawTitle = t[1]
            let snippetRaw = i < snippets.count ? snippets[i][0] : ""
            let r = SearchResult(
                title: decodeEntities(stripTags(rawTitle)),
                url: cleanURL(rawURL),
                snippet: decodeEntities(stripTags(snippetRaw))
            )
            if !r.title.isEmpty && !r.url.isEmpty {
                results.append(r)
            }
        }
        return results
    }

    private static func matches(in text: String, pattern: String, groups: Int) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        return matches.map { match in
            (1...groups).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static func cleanURL(_ raw: String) -> String {
        var url = raw
        if let range = url.range(of: "uddg=") {
            let after = String(url[range.upperBound...])
            let end = after.firstIndex(of: "&") ?? after.endIndex
            let encoded = String(after[..<end])
            if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                url = decoded
            }
        }
        if url.hasPrefix("//") { url = "https:" + url }
        return url
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;",  with: "&")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#x27;", with: "'")
         .replacingOccurrences(of: "&#39;",  with: "'")
         .replacingOccurrences(of: "&lt;",   with: "<")
         .replacingOccurrences(of: "&gt;",   with: ">")
         .replacingOccurrences(of: "&nbsp;", with: " ")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return s }
        return regex.stringByReplacingMatches(
            in: s, options: [],
            range: NSRange(location: 0, length: (s as NSString).length),
            withTemplate: ""
        )
    }

    private static func encode(_ r: [SearchResult]) -> String {
        (try? String(data: JSONEncoder().encode(r), encoding: .utf8)) ?? "Encoding error"
    }
}
