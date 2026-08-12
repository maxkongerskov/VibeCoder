//
//  FetchRSSTool.swift
//
//  Fetches and parses an RSS 2.0 or Atom 1.0 feed. Designed as a clean
//  alternative to fetch_url when the user wants headlines / blog updates /
//  syndicated content: RSS bypasses cookie consent walls, returns
//  structured items, and is 10-100× smaller than rendered HTML.
//
//  Auto-discovery: if `url` doesn't already look like a feed, tries
//  common feed paths on the same host, then HTML <link rel="alternate">
//  autodiscovery, before giving up.
//

import Foundation

public struct FetchRSSTool: Tool {
    public static let name = "fetch_rss"
    public static let category: ToolCategory = .web
    public static let permission: ToolPermission = .network
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Fetch and parse an RSS 2.0 or Atom 1.0 feed. Returns up to 25 items \
        (title, link, published date, summary). If the URL isn't a feed, tries \
        common feed paths on the same host and falls back to HTML \
        <link rel=\"alternate\"> autodiscovery. Prefer this over fetch_url when \
        you want headlines or syndicated content — it bypasses cookie walls and \
        is 10-100× smaller than rendered HTML.
        """,
        parameters: .init(
            properties: [
                "url": .init(type: "string", description: "Absolute http:// or https:// URL — feed URL OR homepage URL.")
            ],
            required: ["url"]
        )
    )

    public struct FeedItem: Sendable {
        public var title: String
        public var link: String
        public var published: String
        public var summary: String
    }

    public struct FetchResult: Sendable {
        public let output: String
        public let isError: Bool
    }

    private static let responseByteCap = 2_000_000   // 2 MB raw download cap
    private static let maxItemsReturned = 25
    private static let summaryCharCap = 400
    private static let timeoutSeconds: TimeInterval = 15

    /// Common RSS / Atom path suffixes we'll probe when the user gives
    /// us a homepage URL instead of a feed URL.
    private static let candidateSuffixes: [String] = [
        "/rss", "/rss/",
        "/feed", "/feed/",
        "/rss.xml", "/feed.xml",
        "/atom.xml", "/index.xml",
        "/feed/rss.xml",
        "/rss/index.xml",
        "/?feed=rss2",            // WordPress
        "/feeds/posts/default"    // Blogger
    ]

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let raw = try arguments.string("url")
        let result = await Self.fetch(url: raw)
        return ToolResult(content: result.output, isError: result.isError)
    }

    public static func fetch(url rawURL: String) async -> FetchResult {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return FetchResult(output: "Error: invalid URL. Must be an absolute http:// or https:// URL.",
                               isError: true)
        }

        if let host = url.host?.lowercased(), isBlocked(host: host) {
            return FetchResult(output: "Error: refusing to fetch '\(host)' — local or private addresses are blocked for safety.",
                               isError: true)
        }

        var attempted: [String] = []

        // Strategy 1 — try verbatim.
        attempted.append(url.absoluteString)
        if let result = await tryFeed(at: url) { return result }

        if looksLikeFeedPath(url.path) {
            return FetchResult(
                output: "Error: \(url.absoluteString) does not return a valid RSS or Atom feed (got HTTP error, empty body, or unrecognised XML root). The path looks like a feed but didn't parse as one.",
                isError: true
            )
        }

        // Strategy 2 — probe candidate paths.
        let probeURLs = buildProbeURLs(from: url)
        for probe in probeURLs {
            attempted.append(probe.absoluteString)
            if let result = await tryFeed(at: probe) { return result }
        }

        // Strategy 3 — HTML autodiscovery via <link rel="alternate">.
        if let discovered = await discoverFeedViaHTMLLink(at: url) {
            attempted.append(discovered.absoluteString)
            if let result = await tryFeed(at: discovered) { return result }
        }

        return FetchResult(
            output: "Error: no RSS or Atom feed found for \(url.absoluteString). Tried \(attempted.count) candidate URL(s) including common feed paths and HTML <link rel=\"alternate\"> autodiscovery. The site may not publish a feed.",
            isError: true
        )
    }

    private static func buildProbeURLs(from url: URL) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func append(_ candidate: URL?) {
            guard let c = candidate else { return }
            let key = c.absoluteString
            if seen.insert(key).inserted { result.append(c) }
        }

        var hostBase = URLComponents()
        hostBase.scheme = url.scheme
        hostBase.host = url.host
        hostBase.port = url.port
        for suffix in candidateSuffixes {
            hostBase.path = suffixToPath(suffix)
            hostBase.query = suffixToQuery(suffix)
            append(hostBase.url)
        }

        let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !trimmedPath.isEmpty {
            var pathBase = URLComponents()
            pathBase.scheme = url.scheme
            pathBase.host = url.host
            pathBase.port = url.port
            for suffix in candidateSuffixes {
                let raw = suffixToPath(suffix)
                let joined = "/\(trimmedPath)\(raw)"
                pathBase.path = joined
                pathBase.query = suffixToQuery(suffix)
                append(pathBase.url)
            }
        }

        return result
    }

    private static func suffixToPath(_ suffix: String) -> String {
        if let q = suffix.firstIndex(of: "?") {
            return String(suffix[..<q])
        }
        return suffix
    }

    private static func suffixToQuery(_ suffix: String) -> String? {
        if let q = suffix.firstIndex(of: "?") {
            return String(suffix[suffix.index(after: q)...])
        }
        return nil
    }

    // MARK: - HTML autodiscovery

    private static func discoverFeedViaHTMLLink(at url: URL) async -> URL? {
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
                return nil
            }
            let bounded = data.prefix(responseByteCap)
            guard let html = String(data: bounded, encoding: .utf8)
                ?? String(data: bounded, encoding: .isoLatin1) else {
                return nil
            }

            let scanRegion: String
            if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
                scanRegion = String(html[..<headEnd.upperBound])
            } else {
                scanRegion = String(html.prefix(50_000))
            }

            return firstFeedLink(in: scanRegion, baseURL: url)
        } catch {
            return nil
        }
    }

    private static func firstFeedLink(in html: String, baseURL: URL) -> URL? {
        guard let regex = try? NSRegularExpression(
            pattern: "<link\\b[^>]*>",
            options: [.caseInsensitive]
        ) else { return nil }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        for match in matches {
            let tag = ns.substring(with: match.range)
            let rel = attributeValue(of: "rel", in: tag)?.lowercased() ?? ""
            let type = attributeValue(of: "type", in: tag)?.lowercased() ?? ""
            guard rel.contains("alternate") else { continue }
            guard type == "application/rss+xml" || type == "application/atom+xml" else { continue }
            guard let href = attributeValue(of: "href", in: tag), !href.isEmpty else { continue }

            if let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                if let h = resolved.host?.lowercased(), isBlocked(host: h) { continue }
                return resolved
            }
        }
        return nil
    }

    private static func attributeValue(of name: String, in tag: String) -> String? {
        let patterns = [
            "\(name)\\s*=\\s*\"([^\"]*)\"",
            "\(name)\\s*=\\s*'([^']*)'",
            "\(name)\\s*=\\s*([^\\s>]+)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = tag as NSString
            if let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges >= 2 {
                return ns.substring(with: match.range(at: 1))
            }
        }
        return nil
    }

    // MARK: - Single-URL attempt

    private static func tryFeed(at url: URL) async -> FetchResult? {
        var req = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8",
                     forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            let bounded = data.prefix(responseByteCap)

            let head = String(data: bounded.prefix(2048), encoding: .utf8) ?? ""
            guard head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:RDF") else {
                return nil
            }

            let parser = FeedXMLParser()
            guard let items = parser.parse(data: Data(bounded)) else {
                return nil
            }

            let limited = Array(items.prefix(maxItemsReturned))
            let body = render(items: limited, fromURL: url, totalCount: items.count)
            return FetchResult(output: body, isError: false)
        } catch {
            return nil
        }
    }

    private static func render(items: [FeedItem], fromURL: URL, totalCount: Int) -> String {
        var out = "Feed: \(fromURL.absoluteString)\nItems: \(totalCount) (showing \(items.count))\n\n"
        for (i, item) in items.enumerated() {
            out += "[\(i + 1)] \(item.title)\n"
            if !item.link.isEmpty { out += "    \(item.link)\n" }
            if !item.published.isEmpty { out += "    \(item.published)\n" }
            if !item.summary.isEmpty {
                let trimmed = item.summary.count > summaryCharCap
                    ? String(item.summary.prefix(summaryCharCap)) + "…"
                    : item.summary
                out += "    \(trimmed)\n"
            }
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeFeedPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasSuffix(".xml") || lower.hasSuffix(".rss") || lower.hasSuffix(".atom") { return true }
        if lower.contains("/rss") || lower.contains("/feed") || lower.contains("/atom") { return true }
        return false
    }

    private static func isBlocked(host: String) -> Bool {
        if host == "localhost" { return true }
        let privatePrefixes = ["127.", "10.", "192.168.", "169.254.", "0."]
        if privatePrefixes.contains(where: { host.hasPrefix($0) }) { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        if host == "::1" || host == "[::1]" { return true }
        return false
    }
}

// MARK: - Parser

/// XMLParser delegate handling both RSS 2.0 (`<item>` children of
/// `<channel>`) and Atom 1.0 (`<entry>` children of `<feed>`). Returns
/// nil on hard parse failure; empty array if the document parses but
/// has no items.
private final class FeedXMLParser: NSObject, XMLParserDelegate {
    private var items: [FetchRSSTool.FeedItem] = []
    private var current: FetchRSSTool.FeedItem?
    private var buffer = ""
    private var insideItem = false
    private var elementStack: [String] = []
    private var pendingAtomLink: String?

    func parse(data: Data) -> [FetchRSSTool.FeedItem]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? items : nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        elementStack.append(name)
        buffer = ""

        if name == "item" || name == "entry" {
            insideItem = true
            current = FetchRSSTool.FeedItem(title: "", link: "", published: "", summary: "")
            pendingAtomLink = nil
        }

        if insideItem, name == "link" {
            let rel = (attributeDict["rel"] ?? "alternate").lowercased()
            if rel == "alternate", let href = attributeDict["href"], !href.isEmpty {
                pendingAtomLink = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) {
            buffer += s
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        defer {
            if !elementStack.isEmpty { elementStack.removeLast() }
            buffer = ""
        }

        if name == "item" || name == "entry" {
            if let item = current, !item.title.isEmpty || !item.link.isEmpty {
                items.append(item)
            }
            current = nil
            insideItem = false
            pendingAtomLink = nil
            return
        }

        guard insideItem, var item = current else { return }
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "title":
            if item.title.isEmpty { item.title = stripTags(text) }
        case "link":
            if item.link.isEmpty {
                if !text.isEmpty {
                    item.link = text
                } else if let href = pendingAtomLink {
                    item.link = href
                }
            }
        case "id":
            if item.link.isEmpty, text.lowercased().hasPrefix("http") {
                item.link = text
            }
        case "pubdate", "published", "updated", "dc:date":
            if item.published.isEmpty { item.published = text }
        case "description", "summary", "content", "content:encoded":
            if item.summary.isEmpty { item.summary = stripTags(text) }
        default:
            break
        }

        current = item
    }

    private func stripTags(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return s }
        let ns = s as NSString
        let stripped = regex.stringByReplacingMatches(
            in: s, options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
        return stripped
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
