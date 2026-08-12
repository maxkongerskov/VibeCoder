//
//  ArtifactDiffView.swift
//

import SwiftUI
import AppKit

struct ArtifactDiffView: View {
    let diffText: String
    var maxHeight: CGFloat = 400
    var languageHint: String? = nil

    var body: some View {
        ScrollView {
            Text(highlightedDiff)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
    }

    private var highlightedDiff: AttributedString {
        DiffSyntaxHighlighter.attributedString(
            from: diffText.isEmpty ? "(empty diff)" : diffText,
            languageHint: languageHint
        )
    }
}

@MainActor
enum DiffSyntaxHighlighter {

    // Use NSColor (AppKit) instead of Color (SwiftUI) to avoid
    // non-Sendable key path issues with AttributedString attributes.
    private static let addColor = NSColor(red: 0.20, green: 0.62, blue: 0.32, alpha: 1)
    private static let removeColor = NSColor(red: 0.82, green: 0.25, blue: 0.28, alpha: 1)
    private static let keywordColor = NSColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 1)
    private static let stringColor = NSColor(red: 0.75, green: 0.45, blue: 0.20, alpha: 1)
    private static let headerColor = NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1)
    private static let hunkColor = NSColor(red: 0.45, green: 0.65, blue: 0.95, alpha: 1)
    private static let primaryColor = NSColor.labelColor

    static func attributedString(from text: String, languageHint: String? = nil) -> AttributedString {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let swift = isSwift(languageHint)

        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(NSMutableAttributedString(string: "\n")) }
            result.append(attributedLine(String(line), swift: swift))
        }
        return AttributedString(result)
    }

    private static func isSwift(_ languageHint: String?) -> Bool {
        guard let languageHint else { return false }
        return languageHint == "swift" || languageHint.hasSuffix(".swift")
    }

    // Build an NSMutableAttributedString for a single diff line.
    // Uses NSAttributedString.Key string keys to avoid non-Sendable
    // key path formation in Swift 6 strict concurrency mode.
    private static func attributedLine(_ line: String, swift: Bool) -> NSMutableAttributedString {
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            return makeStyled(line, foreground: headerColor)
        }
        if line.hasPrefix("@@") {
            return makeStyled(line, foreground: hunkColor)
        }

        let isAdd = line.hasPrefix("+") && !line.hasPrefix("+++")
        let isRemove = line.hasPrefix("-") && !line.hasPrefix("---")
        if isAdd || isRemove {
            let prefix = String(line.prefix(1))
            let content = String(line.dropFirst())
            let fg = isAdd ? addColor : removeColor

            let result = NSMutableAttributedString()
            // Prefix character with foreground + background
            result.append(makeStyled(prefix, foreground: fg, background: bg(for: fg)))
            // Content with optional syntax highlighting
            if !content.isEmpty {
                if swift {
                    result.append(highlightSwiftCode(content, baseColor: fg))
                } else {
                    result.append(makeStyled(content, foreground: fg, background: bg(for: fg)))
                }
            }
            return result
        }

        if swift {
            return highlightSwiftCode(line, baseColor: primaryColor)
        }
        return makeStyled(line, foreground: primaryColor)
    }

    private static func bg(for color: NSColor) -> NSColor {
        color.withAlphaComponent(0.10)
    }

    /// Create a styled NSMutableAttributedString using string-based
    /// attribute keys (NSAttributedString.Key) which do not form
    /// non-Sendable key paths in Swift 6.
    private static func makeStyled(
        _ text: String,
        foreground: NSColor,
        background: NSColor? = nil
    ) -> NSMutableAttributedString {
        let attr = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: text.utf16.count)
        attr.addAttribute(.foregroundColor, value: foreground, range: range)
        if let bg = background {
            attr.addAttribute(.backgroundColor, value: bg, range: range)
        }
        return attr
    }

    /// Syntax-highlight Swift code in a diff line using string-based
    /// attribute keys to avoid non-Sendable key path formation.
    private static func highlightSwiftCode(
        _ line: String,
        baseColor: NSColor
    ) -> NSMutableAttributedString {
        let attr = makeStyled(line, foreground: baseColor)

        // Highlight Swift keywords
        let keywords = ["func", "struct", "class", "enum", "import", "let", "var", "return", "if", "else", "guard"]
        for keyword in keywords {
            let nsLine = line as NSString
            var searchRange = NSRange(location: 0, length: nsLine.length)
            while let kwRange = nsLine.range(of: keyword, options: [], range: searchRange).rangeIfFound {
                attr.addAttribute(.foregroundColor, value: keywordColor, range: kwRange)
                searchRange = NSRange(location: kwRange.location + kwRange.length, length: nsLine.length - (kwRange.location + kwRange.length))
            }
        }

        // Highlight strings
        if line.contains("\"") {
            let nsLine = line as NSString
            let searchRange = NSRange(location: 0, length: nsLine.length)
            if let firstQuote = nsLine.range(of: "\"", options: [], range: searchRange).rangeIfFound,
               let lastQuote = nsLine.range(of: "\"", options: .backwards, range: searchRange).rangeIfFound,
               firstQuote.location < lastQuote.location {
                let stringRange = NSRange(location: firstQuote.location, length: lastQuote.location - firstQuote.location + 1)
                attr.addAttribute(.foregroundColor, value: stringColor, range: stringRange)
            }
        }

        return attr
    }
}

// MARK: - NSRange helper

private extension NSRange {
    /// Convert `Range(found: Bool)` to Optional<NSRange>
    var rangeIfFound: NSRange? {
        if location == NSNotFound { return nil }
        return self
    }

    /// Helper for `NSString.range(of:)` which returns a tuple (range, found)
    static func search(_ nsString: NSString, _ str: String, range: NSRange) -> NSRange? {
        let r = nsString.range(of: str, options: [], range: range)
        return r.location == NSNotFound ? nil : r
    }
}