// DocumentRenderingService.swift
// AgentOS — Claude Edition
//
// Markdown → styled HTML → PDF via WKWebView. Headless: spins up an
// off-screen WKWebView, loads the rendered HTML, and uses `createPDF` to
// produce a paginated PDF document.
//
// App-target service: WebKit is macOS-only and not appropriate for
// AgentCore.

import Foundation
@preconcurrency import WebKit
import AppKit

public enum DocumentRenderingService {

    public enum Theme: String, Sendable {
        case `default`, academic, report, resume

        var css: String {
            switch self {
            case .default:
                return """
                body { font-family: -apple-system, "Helvetica Neue", Arial, sans-serif; font-size: 12pt; line-height: 1.55; color: #222; margin: 48px 56px; }
                h1 { font-size: 24pt; margin: 28px 0 12px; border-bottom: 1px solid #ddd; padding-bottom: 6px; }
                h2 { font-size: 18pt; margin: 22px 0 10px; }
                h3 { font-size: 14pt; margin: 18px 0 8px; }
                h4, h5, h6 { font-size: 12pt; margin: 14px 0 6px; }
                p  { margin: 0 0 10px; }
                code { background: #f5f5f7; padding: 1px 4px; border-radius: 3px; font-family: "SF Mono", Menlo, monospace; font-size: 11pt; }
                pre { background: #f5f5f7; padding: 12px 14px; border-radius: 6px; overflow-x: auto; font-family: "SF Mono", Menlo, monospace; font-size: 10.5pt; line-height: 1.45; }
                pre code { background: transparent; padding: 0; }
                blockquote { border-left: 3px solid #ccc; padding: 4px 12px; color: #555; margin: 10px 0; }
                ul, ol { padding-left: 22px; margin: 8px 0; }
                li { margin: 3px 0; }
                a { color: #0a66c2; text-decoration: none; }
                table { border-collapse: collapse; margin: 12px 0; }
                th, td { border: 1px solid #ddd; padding: 6px 10px; }
                th { background: #f5f5f7; }
                hr { border: 0; border-top: 1px solid #ddd; margin: 24px 0; }
                """
            case .academic:
                return """
                body { font-family: Georgia, "Times New Roman", serif; font-size: 12pt; line-height: 1.7; color: #111; margin: 64px 72px; text-align: justify; }
                h1 { font-size: 22pt; text-align: center; margin: 0 0 24px; font-variant: small-caps; letter-spacing: 0.06em; }
                h2 { font-size: 14pt; margin: 28px 0 10px; font-weight: bold; }
                h3 { font-size: 12pt; margin: 20px 0 6px; font-style: italic; }
                p  { margin: 0; text-indent: 1.6em; }
                p:first-of-type, h1 + p, h2 + p, h3 + p, blockquote + p { text-indent: 0; }
                code, pre { font-family: "SF Mono", Menlo, monospace; }
                pre { background: #f8f8f4; padding: 10px 12px; border: 1px solid #e4e4dc; }
                blockquote { border-left: 2px solid #888; padding: 0 16px; color: #333; font-style: italic; }
                """
            case .report:
                return """
                body { font-family: "Helvetica Neue", Arial, sans-serif; font-size: 11pt; line-height: 1.55; color: #1a1a1a; margin: 56px 64px; }
                h1 { font-size: 28pt; color: #003a70; margin: 0 0 6px; }
                h1 + p { color: #666; font-size: 14pt; margin: 0 0 32px; }
                h2 { font-size: 16pt; color: #003a70; margin: 28px 0 8px; border-bottom: 2px solid #003a70; padding-bottom: 4px; }
                h3 { font-size: 13pt; color: #003a70; margin: 18px 0 6px; }
                table { border-collapse: collapse; margin: 14px 0; width: 100%; }
                th { background: #003a70; color: #fff; padding: 8px 10px; text-align: left; }
                td { border-bottom: 1px solid #ddd; padding: 6px 10px; }
                """
            case .resume:
                return """
                body { font-family: "Helvetica Neue", Arial, sans-serif; font-size: 11pt; line-height: 1.4; color: #222; margin: 48px 56px; }
                h1 { font-size: 26pt; margin: 0 0 2px; letter-spacing: 0.02em; }
                h1 + p { color: #555; font-size: 11pt; margin: 0 0 18px; }
                h2 { font-size: 12pt; text-transform: uppercase; letter-spacing: 0.12em; color: #555; margin: 18px 0 6px; border-bottom: 1px solid #ccc; padding-bottom: 4px; }
                h3 { font-size: 12pt; margin: 8px 0 0; }
                h3 + p em { color: #666; }
                ul { padding-left: 18px; }
                li { margin: 1px 0; }
                """
            }
        }
    }

    /// Render a markdown file (or inline text) to a PDF on disk.
    /// Returns a one-line success/error string. `theme` accepts the raw
    /// enum string ("default", "academic", "report", "resume"); unknown
    /// values fall back to `.default`.
    public static func renderMarkdownToPDF(markdownPath: String?,
                                           markdownText: String?,
                                           outputPath: String,
                                           theme: String = "default") async -> String {
        let md: String
        if let t = markdownText, !t.isEmpty {
            md = t
        } else if let p = markdownPath, !p.isEmpty,
                  let data = try? String(contentsOfFile: (p as NSString).expandingTildeInPath,
                                         encoding: .utf8) {
            md = data
        } else {
            return "Error: provide either `markdown_path` or `markdown_text`."
        }
        guard !outputPath.isEmpty else {
            return "Error: `output_path` is required."
        }
        let outURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
        let themeEnum = Theme(rawValue: theme.lowercased()) ?? .default
        let html = wrapHTML(body: MarkdownToHTML.render(md), css: themeEnum.css)

        // WKWebView must live on the main actor.
        do {
            let data = try await renderHTMLToPDF(html: html)
            try data.write(to: outURL)
            return "Rendered \(data.count) bytes to \(outputPath) (theme: \(themeEnum.rawValue))."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - WKWebView → PDF

    @MainActor
    private static func renderHTMLToPDF(html: String) async throws -> Data {
        // A reasonable US Letter-ish frame at 96 DPI: 816 × 1056. WKWebView
        // paginates the resulting PDF based on its own print configuration.
        let frame = NSRect(x: 0, y: 0, width: 816, height: 1056)
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: frame, configuration: config)
        let helper = PDFLoadHelper()
        webView.navigationDelegate = helper

        webView.loadHTMLString(html, baseURL: nil)
        try await helper.waitForLoad()
        // Give layout a tick to settle before snapshot.
        try? await Task.sleep(nanoseconds: 120_000_000)

        let pdfConfig = WKPDFConfiguration()
        pdfConfig.rect = .null // full document
        let data = try await webView.pdf(configuration: pdfConfig)
        return data
    }

    private static func wrapHTML(body: String, css: String) -> String {
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>\(css)</style></head>
        <body>\(body)</body></html>
        """
    }
}

// MARK: - WKNavigationDelegate helper

@MainActor
private final class PDFLoadHelper: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func waitForLoad() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}

// MARK: - Minimal Markdown → HTML

/// Hand-rolled markdown→HTML for the cases that matter in a printable
/// document: headings, paragraphs, fenced code blocks, inline code,
/// emphasis, lists, blockquotes, links, horizontal rules. Not a full
/// CommonMark implementation — Pandoc is for that. This is the fallback.
public enum MarkdownToHTML {
    public static func render(_ md: String) -> String {
        var out = ""
        let lines = md.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.hasPrefix("```") {
                let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body = ""
                i += 1
                while i < lines.count, !lines[i].hasPrefix("```") {
                    body += lines[i] + "\n"; i += 1
                }
                i += 1
                let langClass = lang.isEmpty ? "" : " class=\"lang-\(lang)\""
                out += "<pre><code\(langClass)>" + escape(body) + "</code></pre>\n"
                continue
            }

            // Headings
            if let h = headingMatch(line) {
                out += "<h\(h.level)>\(inlineFormat(h.text))</h\(h.level)>\n"; i += 1; continue
            }

            // Horizontal rule
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                out += "<hr>\n"; i += 1; continue
            }

            // Blockquote (group consecutive `> ` lines)
            if line.hasPrefix("> ") || line == ">" {
                var quote = ""
                while i < lines.count, lines[i].hasPrefix(">") {
                    let stripped = lines[i].drop(while: { $0 == ">" })
                        .drop(while: { $0 == " " })
                    quote += String(stripped) + " "
                    i += 1
                }
                out += "<blockquote>\(inlineFormat(quote.trimmingCharacters(in: .whitespaces)))</blockquote>\n"
                continue
            }

            // Unordered list — strip only the single leading marker char (+ optional space)
            if isULItem(line) {
                var items: [String] = []
                while i < lines.count, isULItem(lines[i]) {
                    // Drop exactly one marker character (first char) then at most one space.
                    var item = lines[i].dropFirst()
                    if item.first == " " { item = item.dropFirst() }
                    items.append("<li>\(inlineFormat(String(item)))</li>")
                    i += 1
                }
                out += "<ul>\n" + items.joined(separator: "\n") + "\n</ul>\n"
                continue
            }

            // Ordered list
            if isOLItem(line) {
                var items: [String] = []
                while i < lines.count, isOLItem(lines[i]) {
                    let text = lines[i].drop(while: { $0.isNumber || $0 == "." || $0 == " " })
                    items.append("<li>\(inlineFormat(String(text)))</li>")
                    i += 1
                }
                out += "<ol>\n" + items.joined(separator: "\n") + "\n</ol>\n"
                continue
            }

            // Blank line → paragraph break
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1; continue
            }

            // Paragraph: gather until blank line / block boundary
            var para = line
            i += 1
            while i < lines.count {
                let next = lines[i]
                let trimmedNext = next.trimmingCharacters(in: .whitespaces)
                if trimmedNext.isEmpty { break }
                if next.hasPrefix("```") || next.hasPrefix("#") || next.hasPrefix("> ") ||
                   isULItem(next) || isOLItem(next) || trimmedNext == "---" { break }
                para += " " + next.trimmingCharacters(in: .whitespaces)
                i += 1
            }
            out += "<p>\(inlineFormat(para))</p>\n"
        }
        return out
    }

    // MARK: helpers

    private struct Heading { let level: Int; let text: String }
    private static func headingMatch(_ s: String) -> Heading? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6,
              s.dropFirst(hashes).hasPrefix(" ") else { return nil }
        let text = s.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return Heading(level: hashes, text: text)
    }
    private static func isULItem(_ s: String) -> Bool {
        let t = s.drop(while: { $0 == " " })
        return t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ")
    }
    private static func isOLItem(_ s: String) -> Bool {
        // crude: digits then ". " then content
        let t = s.drop(while: { $0 == " " })
        var idx = t.startIndex
        while idx < t.endIndex, t[idx].isNumber { idx = t.index(after: idx) }
        guard idx > t.startIndex, idx < t.endIndex, t[idx] == "." else { return false }
        let after = t.index(after: idx)
        return after < t.endIndex && t[after] == " "
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Inline: `code`, **bold**, *italic*, [text](url).
    private static func inlineFormat(_ s: String) -> String {
        var out = escape(s)
        // inline code first so its contents are escaped already
        out = replace(out, pattern: "`([^`]+)`", with: "<code>$1</code>")
        out = replace(out, pattern: #"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>")
        out = replace(out, pattern: #"\*([^*]+)\*"#, with: "<em>$1</em>")
        out = replace(out, pattern: #"\[([^\]]+)\]\(([^\)]+)\)"#, with: "<a href=\"$2\">$1</a>")
        return out
    }

    private static func replace(_ s: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }
}
