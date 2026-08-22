// MarkdownTextView.swift
// AgentOS — Claude Edition
//
// Block-level markdown renderer for assistant messages. Splits text into
// typed blocks (headings, lists, tables, blockquotes, horizontal rules,
// fenced code, paragraphs) and renders each with its own SwiftUI view.
// Inline formatting (bold, italic, links, code spans) is delegated to
// AttributedString with .inlineOnlyPreservingWhitespace syntax per block.
//
// Block parser is intentionally lightweight (line scanning, no full
// CommonMark compliance) — covers the patterns the assistant actually
// emits. No third-party Markdown framework dependency.
//
// Ported from DEV PLAN's MarkdownTextView.swift.
// Key changes vs DEV PLAN:
//   • `settings: AppSettings` removed; replaced with `fontSize: CGFloat = 14`
//   • `.geist(...)` font calls replaced with `.system(size:weight:design:)`
//   • Color tokens updated to Theme.Palette.* (NEW DAY)
//

import SwiftUI

struct MarkdownTextView: View {
    let text: String
    var isStreaming: Bool = false
    /// Chat body font size. Matches the size used in MessageBubbleViewV2.
    var fontSize: CGFloat = Theme.ChatLayout.bodyFontSize

    var body: some View {
        let blocks = identifiedBlocks
        VStack(alignment: .leading, spacing: Theme.Spacing.m) { // 12pt — air between blocks
            ForEach(blocks) { item in
                blockView(item.block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        // Growing last block only — do not animate the whole stack (flicker).
    }

    /// Prefix blocks keep a stable id so streaming tokens only rebuild the tail.
    private var identifiedBlocks: [IdentifiedMarkdownBlock] {
        let blocks = parseBlocks(text)
        return blocks.enumerated().map { i, block in
            let tail = isStreaming && i == blocks.count - 1
            return IdentifiedMarkdownBlock(
                id: tail ? "stream-tail" : "\(i)-\(Self.kind(block))",
                block: block)
        }
    }

    private static func kind(_ block: MarkdownBlock) -> String {
        switch block {
        case .heading: return "h"
        case .paragraph: return "p"
        case .codeBlock: return "code"
        case .list: return "list"
        case .table: return "table"
        case .blockquote: return "quote"
        case .horizontalRule: return "hr"
        }
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            headingView(level: level, content: content)
        case .paragraph(let content):
            inlineMarkdown(content)
                .font(Theme.Typography.body(size: fontSize))
                .foregroundColor(Theme.Palette.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .codeBlock(let lang, let code):
            CodeBlockView(language: lang, code: code, fontSize: max(12, fontSize - 1))
        case .list(let items, let ordered):
            listView(items: items, ordered: ordered)
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        case .blockquote(let content):
            blockquoteView(content: content)
        case .horizontalRule:
            Rectangle()
                .fill(Theme.Palette.divider)
                .frame(height: 0.5)
                .padding(.vertical, Theme.Spacing.xs)
        }
    }

    // Headings use SF Pro (same family as body) — modest size steps only.
    // Never .serif: New York mid-message felt like a different product.
    private func headingView(level: Int, content: String) -> some View {
        inlineMarkdown(content)
            .font(Theme.Typography.markdownHeading(level: level, base: fontSize))
            .foregroundColor(Theme.Palette.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, level <= 2 ? Theme.Spacing.xs : Theme.Spacing.xxs)
    }

    @ViewBuilder
    private func listView(items: [String], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { idx in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(ordered ? "\(idx + 1)." : "•")
                        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.Palette.accent.opacity(0.85))
                        .frame(width: ordered ? 22 : 14, alignment: .trailing)
                    inlineMarkdown(items[idx])
                        .font(Theme.Typography.body(size: fontSize))
                        .foregroundColor(Theme.Palette.primary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 2)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func tableView(headers: [String], rows: [[String]]) -> some View {
        // Each cell uses fixedSize(horizontal: false, vertical: true) so the
        // natural wrapped height is computed up-front — without it cells
        // render truncated. HStack alignment is .top so cells in mixed-line
        // rows align from the top edge rather than vertically centering.
        VStack(spacing: 0) {
            // Header row
            HStack(alignment: .top, spacing: 0) {
                ForEach(headers.indices, id: \.self) { i in
                    inlineMarkdown(headers[i])
                        .font(.system(size: fontSize, weight: .semibold, design: .default))
                        .foregroundColor(Theme.Palette.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Spacing.m - 2) // 10pt
                        .padding(.vertical, 7)
                }
            }
            .background(Theme.Palette.divider.opacity(0.18))

            // Data rows
            ForEach(rows.indices, id: \.self) { rowIdx in
                Rectangle()
                    .fill(Theme.Palette.divider.opacity(0.5))
                    .frame(height: 0.5)
                HStack(alignment: .top, spacing: 0) {
                    let row = rows[rowIdx]
                    ForEach(headers.indices, id: \.self) { colIdx in
                        let cell = colIdx < row.count ? row[colIdx] : ""
                        inlineMarkdown(cell)
                            .font(.system(size: fontSize, weight: .regular))
                            .foregroundColor(Theme.Palette.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Spacing.m - 2) // 10pt
                            .padding(.vertical, 7)
                    }
                }
                .background(rowIdx % 2 == 0 ? Color.clear : Theme.Palette.divider.opacity(0.07))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Palette.divider.opacity(0.5), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func blockquoteView(content: String) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Theme.Palette.accent.opacity(0.45))
                .frame(width: 3)
            inlineMarkdown(content)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundColor(Theme.Palette.secondary)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Theme.Spacing.m - 2) // 10pt
                .padding(.vertical, Theme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func inlineMarkdown(_ str: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: str,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(str)
        }
    }

    // MARK: - Block parser
    //
    // Walks text line-by-line and emits a typed array of blocks.
    // Handles the patterns the assistant actually emits plus tables and
    // blockquotes. Fenced code blocks preserve exact internal whitespace.

    private func parseBlocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var paragraphBuf: [String] = []

        func flushParagraph() {
            guard !paragraphBuf.isEmpty else { return }
            let joined = paragraphBuf
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                // Models often emit list-like lines without a blank line before
                // the first bullet — promote those to real list blocks.
                if let promoted = Self.promotePseudoList(joined) {
                    blocks.append(contentsOf: promoted)
                } else {
                    blocks.append(.paragraph(joined))
                }
            }
            paragraphBuf.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line → paragraph boundary
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Fenced code block — ```lang\n...\n```
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let codeLine = lines[i]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1; break
                    }
                    codeLines.append(codeLine)
                    i += 1
                }
                blocks.append(.codeBlock(lang.isEmpty ? nil : lang,
                                         codeLines.joined(separator: "\n")))
                continue
            }

            // Heading — # through ######
            if let (level, content) = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, content: content))
                i += 1; continue
            }

            // Horizontal rule — --- or *** alone on a line (3+ chars)
            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.horizontalRule)
                i += 1; continue
            }

            // Blockquote — one or more consecutive lines starting with >
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while i < lines.count {
                    let qTrim = lines[i].trimmingCharacters(in: .whitespaces)
                    guard qTrim.hasPrefix(">") else { break }
                    var stripped = qTrim
                    stripped.removeFirst() // drop the '>'
                    if stripped.hasPrefix(" ") { stripped.removeFirst() }
                    quoteLines.append(stripped)
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // List — unordered (-, *, +) or ordered (1. 2. ...) — consume run
            if let (items, ordered, consumed) = parseList(from: lines, start: i) {
                flushParagraph()
                blocks.append(.list(items: items, ordered: ordered))
                i += consumed
                continue
            }

            // Table — header row containing | and next row is | --- |
            if i + 1 < lines.count,
               let (headers, rows, consumed) = parseTable(from: lines, start: i) {
                flushParagraph()
                blocks.append(.table(headers: headers, rows: rows))
                i += consumed
                continue
            }

            // Default: accumulate as paragraph
            paragraphBuf.append(line)
            i += 1
        }
        flushParagraph()
        if blocks.isEmpty { blocks.append(.paragraph(text)) }
        return blocks
    }

    // MARK: - Parser helpers

    private func parseHeading(_ trimmed: String) -> (Int, String)? {
        var hashCount = 0
        for ch in trimmed {
            if ch == "#" { hashCount += 1 } else { break }
            if hashCount > 6 { return nil }
        }
        guard hashCount >= 1, hashCount <= 6 else { return nil }
        let rest = String(trimmed.dropFirst(hashCount))
        guard rest.hasPrefix(" ") || rest.isEmpty else { return nil }
        return (hashCount, rest.trimmingCharacters(in: .whitespaces))
    }

    private func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let chars = Set(trimmed)
        return chars == Set(["-"]) || chars == Set(["*"])
    }

    private func parseList(from lines: [String], start: Int)
        -> (items: [String], ordered: Bool, consumed: Int)?
    {
        let firstTrimmed = lines[start].trimmingCharacters(in: .whitespaces)
        // Accept "- ", "* ", "+ ", and en-dash "– " / em-dash "— " (models emit these).
        let unorderedPrefix = Self.isUnorderedBullet(firstTrimmed)
        let ordered = orderedPrefix(firstTrimmed) != nil
        guard unorderedPrefix || ordered else { return nil }

        var items: [String] = []
        var i = start
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if !ordered, let body = Self.unorderedBody(trimmed) {
                items.append(body)
            } else if ordered, let dropLen = orderedPrefix(trimmed) {
                items.append(String(trimmed.dropFirst(dropLen)))
            } else if !items.isEmpty, raw.hasPrefix("  ") || raw.hasPrefix("\t") {
                // Soft-wrapped continuation of previous bullet
                items[items.count - 1] += " " + trimmed
            } else {
                break
            }
            i += 1
        }
        guard items.count >= 1 else { return nil }
        return (items, ordered, i - start)
    }

    fileprivate static func isUnorderedBullet(_ trimmed: String) -> Bool {
        unorderedBody(trimmed) != nil
    }

    fileprivate static func unorderedBody(_ trimmed: String) -> String? {
        for prefix in ["- ", "* ", "+ ", "– ", "— ", "• "] {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        // Bare "-item" without space (common model slip)
        if trimmed.count > 1, trimmed.hasPrefix("-"),
           let second = trimmed.dropFirst().first, !second.isWhitespace, second != "-" {
            return String(trimmed.dropFirst())
        }
        return nil
    }

    /// If a paragraph is mostly bullet-like lines, split into paragraph + list blocks.
    fileprivate static func promotePseudoList(_ joined: String) -> [MarkdownBlock]? {
        let lines = joined.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        var lead: [String] = []
        var bullets: [String] = []
        var ordered = false
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if let body = unorderedBody(t) {
                bullets.append(body)
                i += 1
                while i < lines.count {
                    let t2 = lines[i].trimmingCharacters(in: .whitespaces)
                    if let b = unorderedBody(t2) { bullets.append(b); i += 1 }
                    else { break }
                }
                break
            }
            // ordered start?
            var digits = 0
            for ch in t {
                if ch.isNumber { digits += 1 } else { break }
            }
            if digits >= 1, t.count > digits + 1 {
                let idx = t.index(t.startIndex, offsetBy: digits)
                if t[idx] == "." {
                    let after = t.index(after: idx)
                    if after < t.endIndex, t[after] == " " || t[after].isLetter {
                        ordered = true
                        let drop = digits + (t[after] == " " ? 2 : 1)
                        bullets.append(String(t.dropFirst(drop)).trimmingCharacters(in: .whitespaces))
                        i += 1
                        while i < lines.count {
                            let t2 = lines[i].trimmingCharacters(in: .whitespaces)
                            var d2 = 0
                            for ch in t2 {
                                if ch.isNumber { d2 += 1 } else { break }
                            }
                            if d2 >= 1, t2.count > d2 + 1 {
                                let ix = t2.index(t2.startIndex, offsetBy: d2)
                                if t2[ix] == "." {
                                    let after2 = t2.index(after: ix)
                                    let drop2 = d2 + (after2 < t2.endIndex && t2[after2] == " " ? 2 : 1)
                                    bullets.append(String(t2.dropFirst(drop2)).trimmingCharacters(in: .whitespaces))
                                    i += 1
                                    continue
                                }
                            }
                            break
                        }
                        break
                    }
                }
            }
            lead.append(lines[i])
            i += 1
        }
        guard bullets.count >= 2 else { return nil }
        var out: [MarkdownBlock] = []
        let leadJoined = lead.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !leadJoined.isEmpty { out.append(.paragraph(leadJoined)) }
        out.append(.list(items: bullets, ordered: ordered))
        // Trailing non-list lines after the bullet run
        if i < lines.count {
            let rest = lines[i...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty {
                if let more = promotePseudoList(rest) {
                    out.append(contentsOf: more)
                } else {
                    out.append(.paragraph(rest))
                }
            }
        }
        return out
    }

    /// Returns the character count of the leading "N. " marker
    /// (e.g. 3 for "1. ", 4 for "10. ") or nil if not an ordered bullet.
    private func orderedPrefix(_ trimmed: String) -> Int? {
        var digits = 0
        for ch in trimmed {
            if ch.isNumber { digits += 1 } else { break }
        }
        guard digits >= 1, digits < trimmed.count else { return nil }
        let afterDigits = trimmed.index(trimmed.startIndex, offsetBy: digits)
        guard trimmed[afterDigits] == "." else { return nil }
        let afterDot = trimmed.index(after: afterDigits)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        return digits + 2  // digits + '.' + ' '
    }

    private func parseTable(from lines: [String], start: Int)
        -> (headers: [String], rows: [[String]], consumed: Int)?
    {
        let headerLine = lines[start].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|") else { return nil }
        let sepLine = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard isTableSeparator(sepLine) else { return nil }

        let headers = parseTableRow(headerLine)
        var rows: [[String]] = []
        var i = start + 2
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("|"), !trimmed.isEmpty else { break }
            rows.append(parseTableRow(trimmed))
            i += 1
        }
        guard !headers.isEmpty else { return nil }
        return (headers, rows, i - start)
    }

    private func isTableSeparator(_ line: String) -> Bool {
        let allowed: Set<Character> = ["|", "-", ":", " "]
        guard line.allSatisfy({ allowed.contains($0) }) else { return false }
        return line.contains("---") || line.contains(":--") || line.contains("--:")
    }

    private func parseTableRow(_ line: String) -> [String] {
        var trimmed = line
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Block type

enum MarkdownBlock {
    case heading(level: Int, content: String)
    case paragraph(String)
    case codeBlock(String?, String)
    case list(items: [String], ordered: Bool)
    case table(headers: [String], rows: [[String]])
    case blockquote(String)
    case horizontalRule
}

private struct IdentifiedMarkdownBlock: Identifiable {
    let id: String
    let block: MarkdownBlock
}

