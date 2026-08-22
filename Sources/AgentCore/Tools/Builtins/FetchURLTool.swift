//
//  FetchURLTool.swift
//
//  Fetches a web page and returns its main text content with HTML
//  stripped. Designed as a verification-layer tool: search snippets are
//  short and frequently stale, but article bodies usually contain the
//  actual quotes, attributions, dates, and facts. The agent should call
//  `fetch_url` after `web_search` whenever it needs to verify a specific
//  claim.
//
//  Foundation-only; uses `URLSession` and async/await. SSRF guard blocks
//  local + private addresses.
//

import Foundation

public struct FetchURLTool: Tool {
    public static let name = "fetch_url"
    public static let category: ToolCategory = .web
    public static let permission: ToolPermission = .network
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Fetch a web page and return the main text content with HTML stripped. \
        Useful as a verification layer after web_search — search snippets are \
        short and stale, but article bodies have the real quotes, attributions, \
        and dates. Output is capped at ~10K characters; raw download capped at 2 MB. \
        If the response looks like a cookie/consent wall, a hint is prepended so \
        you can switch to fetch_rss for the same site.
        """,
        parameters: .init(
            properties: [
                "url": .init(type: "string", description: "Absolute http:// or https:// URL to fetch.")
            ],
            required: ["url"]
        )
    )

    private static let responseByteCap = 2_000_000   // 2 MB hard cap on raw download
    private static let cleanedCharCap  = 10_000      // 10K chars of clean text returned to model
    private static let timeoutSeconds: TimeInterval = 15

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let raw = try arguments.string("url")
        if let denied = GitHubPRStatusPolicy.preferGhDenial(forFetchURL: raw) {
            return ToolResult(content: denied, isError: true)
        }
        let result = await Self.fetch(url: raw)
        return ToolResult(content: result.output, isError: result.isError)
    }

    // MARK: - Core fetch

    public struct FetchResult: Sendable {
        public let output: String
        public let isError: Bool
    }

    public static func fetch(url rawURL: String) async -> FetchResult {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return FetchResult(output: "Error: invalid URL. Must be an absolute http:// or https:// URL.",
                               isError: true)
        }

        if let host = url.host?.lowercased(), isBlocked(host: host) {
            return FetchResult(output: "Error: refusing to fetch '\(host)' — local or private addresses are blocked for safety.",
                               isError: true)
        }

        var req = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                     forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return FetchResult(output: "Error: HTTP \(http.statusCode) from \(url.host ?? "server").",
                                   isError: true)
            }
            let bounded = data.prefix(responseByteCap)
            let html = String(data: bounded, encoding: .utf8)
                ?? String(data: bounded, encoding: .isoLatin1)
                ?? ""
            if html.isEmpty {
                return FetchResult(output: "Error: empty or non-text response from \(url.host ?? "server").",
                                   isError: true)
            }

            let cleaned = cleanHTML(html)
            let body = cleaned.count > cleanedCharCap
                ? String(cleaned.prefix(cleanedCharCap)) + "\n\n[…truncated, \(cleaned.count - cleanedCharCap) more characters in original.]"
                : cleaned

            var header = "URL: \(url.absoluteString)"
            if looksLikeConsentWall(body) {
                header += "\n\n[Note: This page returned a cookie/consent wall instead of article content. If you need headlines or syndicated items from this site, try `fetch_rss` with the same URL — it auto-discovers feed paths and bypasses consent overlays.]"
            }

            return FetchResult(output: "\(header)\n\n\(body)", isError: false)
        } catch {
            return FetchResult(output: "Error fetching URL: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - HTML cleaning

    /// Strips scripts/styles, drops remaining tags, decodes entities, and
    /// normalises whitespace. Not perfect, but good enough to surface the
    /// readable body of typical news / docs / Wikipedia pages.
    private static func cleanHTML(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "iframe", "svg", "template"] {
            text = stripBlock(text, tag: tag)
        }
        for tag in ["br", "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "section", "article", "header", "footer"] {
            text = replaceTag(text, tag: tag, with: "\n")
        }
        text = regexReplace(text, pattern: "<[^>]+>", with: "")
        text = decodeEntities(text)
        text = regexReplace(text, pattern: "[ \\t\\u{00A0}]+", with: " ")
        text = regexReplace(text, pattern: "\\n\\s*\\n\\s*\\n+", with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripBlock(_ s: String, tag: String) -> String {
        regexReplace(s, pattern: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", caseInsensitive: true)
    }

    private static func replaceTag(_ s: String, tag: String, with replacement: String) -> String {
        regexReplace(s, pattern: "</?\(tag)\\b[^>]*>", with: replacement, caseInsensitive: true)
    }

    private static func regexReplace(_ s: String, pattern: String, with replacement: String, caseInsensitive: Bool = false) -> String {
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else { return s }
        let ns = s as NSString
        return regex.stringByReplacingMatches(
            in: s, options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: replacement
        )
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;",   with: "&")
         .replacingOccurrences(of: "&quot;",  with: "\"")
         .replacingOccurrences(of: "&apos;",  with: "'")
         .replacingOccurrences(of: "&#x27;",  with: "'")
         .replacingOccurrences(of: "&#39;",   with: "'")
         .replacingOccurrences(of: "&lt;",    with: "<")
         .replacingOccurrences(of: "&gt;",    with: ">")
         .replacingOccurrences(of: "&nbsp;",  with: " ")
         .replacingOccurrences(of: "&mdash;", with: "—")
         .replacingOccurrences(of: "&ndash;", with: "–")
         .replacingOccurrences(of: "&hellip;", with: "…")
         .replacingOccurrences(of: "&ldquo;", with: "\"")
         .replacingOccurrences(of: "&rdquo;", with: "\"")
         .replacingOccurrences(of: "&lsquo;", with: "'")
         .replacingOccurrences(of: "&rsquo;", with: "'")
    }

    // MARK: - Consent-wall heuristic

    private static func looksLikeConsentWall(_ text: String) -> Bool {
        let head = String(text.prefix(2000)).lowercased()
        let contextHits: [String] = [
            "consent", "samtykke", "einwilligung", "consentement", "consentimiento",
            "guce", "iab", "tcfv", "onetrust", "quantcast",
            "cookie", "cookies", "privacy choices", "privatlivsvalg"
        ]
        let actionHits: [String] = [
            "accept all", "acceptér alle", "accepter alle", "akzeptieren",
            "tout accepter", "aceptar todo",
            "reject all", "afvis alle", "ablehnen", "tout refuser", "rechazar todo",
            "manage privacy", "administrer privatliv", "datenschutz verwalten",
            "manage preferences", "manage settings"
        ]
        let hasContext = contextHits.contains { head.contains($0) }
        let hasAction = actionHits.contains { head.contains($0) }
        return hasContext && hasAction
    }

    static func isBlocked(host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") {
            h = String(h.dropFirst().dropLast())
        }
        while h.hasSuffix(".") { h.removeLast() }
        if h.isEmpty { return true }
        if h == "localhost" || h == "0" { return true }
        if h.hasPrefix("::ffff:") {
            return isBlocked(host: String(h.dropFirst("::ffff:".count)))
        }
        if h.hasPrefix("0:0:0:0:0:ffff:") {
            return isBlocked(host: String(h.dropFirst("0:0:0:0:0:ffff:".count)))
        }
        if h == "::1" { return true }
        if !h.contains("."), !h.contains(":"), let n = UInt32(h) {
            let dotted = "\((n >> 24) & 0xff).\((n >> 16) & 0xff).\((n >> 8) & 0xff).\(n & 0xff)"
            return isBlocked(host: dotted)
        }
        let privatePrefixes = ["127.", "10.", "192.168.", "169.254.", "0."]
        if privatePrefixes.contains(where: { h.hasPrefix($0) }) { return true }
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }
}
