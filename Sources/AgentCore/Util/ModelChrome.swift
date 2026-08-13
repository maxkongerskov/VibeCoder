//
//  ModelChrome.swift
//
//  Presentation filter for model control chrome (channel tokens, specials).
//  Closed vocabulary only — no aesthetic rewrite. When disabled, returns input.
//  Safe for clean models (no-op when nothing matches).
//

import Foundation

public enum ModelChrome: Sendable {

    public struct Split: Equatable, Sendable {
        public var thinking: String?
        public var body: String
        public var isThinkingOpen: Bool

        public init(thinking: String?, body: String, isThinkingOpen: Bool = false) {
            self.thinking = thinking
            self.body = body
            self.isThinkingOpen = isThinkingOpen
        }
    }

    /// Full presentation pass: channel chrome → think-tag split → leftover specials.
    /// When `enabled` is false, returns raw as body (no thinking extract).
    public static func present(_ raw: String, enabled: Bool) -> Split {
        guard enabled else {
            return Split(thinking: nil, body: raw, isThinkingOpen: false)
        }
        // Channel markers first (they use `<|channel|>name` form — must not
        // be nuked by the generic special-token strip).
        let channel = splitChannels(raw)
        let tag = ThinkTagSplit.parse(channel.body)
        var thinking = mergeThinking(channel.thinking, tag.thinking)
        // Think-only input must stay empty-bodied — do not fall back to raw tags.
        var body = tag.body.trimmingCharacters(in: .whitespacesAndNewlines)
        thinking = thinking.map { stripControlTokens($0) }
        body = stripControlTokens(body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Split(
            thinking: {
                let t = thinking?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return t.isEmpty ? nil : t
            }(),
            body: body,
            isThinkingOpen: tag.isThinkingOpen || channel.isThinkingOpen
        )
    }

    /// Body-only convenience for previews / titles.
    public static func displayBody(_ raw: String, enabled: Bool) -> String {
        let p = present(raw, enabled: enabled)
        let body = p.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body }
        return p.thinking?.trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
    }

    // MARK: - Channel dialect (Gemma / Qwen / oMLX-style)

    /// Patterns like `<|channel|>thought`, `<channel|>final`, bare `<channel|>`.
    /// Name is only a known channel token (not the first word of the answer).
    private static let channelLine = try! NSRegularExpression(
        pattern: #"(?i)<\|?channel\|?>\s*(thought|thinking|think|reasoning|analysis|scratchpad|final|answer|response|text|assistant|message)?"#,
        options: []
    )

    private static func splitChannels(_ raw: String) -> Split {
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = channelLine.matches(in: raw, options: [], range: full)
        guard !matches.isEmpty else {
            return Split(thinking: nil, body: raw, isThinkingOpen: false)
        }

        var thinkingParts: [String] = []
        var bodyParts: [String] = []
        var openThinking = false
        var cursor = 0
        var mode: ChannelMode = .body

        for m in matches {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            appendSegment(before, mode: mode, thinking: &thinkingParts, body: &bodyParts)

            let nameRange = m.range(at: 1)
            let name: String = {
                guard nameRange.location != NSNotFound, nameRange.length > 0 else { return "" }
                return ns.substring(with: nameRange).lowercased()
            }()
            mode = classifyChannel(name)
            if mode == .thinking { openThinking = true }
            if mode == .body { openThinking = false }
            cursor = m.range.location + m.range.length
        }
        let tail = ns.substring(from: cursor)
        appendSegment(tail, mode: mode, thinking: &thinkingParts, body: &bodyParts)

        let thinking = thinkingParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let body = bodyParts
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Split(
            thinking: thinking.isEmpty ? nil : thinking,
            body: body,
            isThinkingOpen: openThinking && body.isEmpty
        )
    }

    private enum ChannelMode { case thinking, body, drop }

    private static func classifyChannel(_ name: String) -> ChannelMode {
        switch name {
        case "", "text", "final", "answer", "response", "assistant", "message":
            return .body
        case "thought", "thinking", "think", "reasoning", "analysis", "scratchpad":
            return .thinking
        default:
            // Unknown channel name: treat as body content after stripping the marker.
            return .body
        }
    }

    private static func appendSegment(
        _ s: String,
        mode: ChannelMode,
        thinking: inout [String],
        body: inout [String]
    ) {
        guard !s.isEmpty else { return }
        switch mode {
        case .thinking: thinking.append(s)
        case .body: body.append(s)
        case .drop: break
        }
    }

    // MARK: - Lone special tokens

    private static let specialToken = try! NSRegularExpression(
        pattern: #"<\|[^|>]{1,64}\|>"#,
        options: []
    )

    /// Remove leftover `<|…|>` specials after channel split (not code fences).
    private static func stripControlTokens(_ raw: String) -> String {
        // Avoid stripping inside fenced code blocks.
        var out = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i...].hasPrefix("```") {
                if let end = raw.range(of: "```", range: raw.index(i, offsetBy: 3)..<raw.endIndex) {
                    out += raw[i..<end.upperBound]
                    i = end.upperBound
                    continue
                }
            }
            // Find next special or end
            let rest = String(raw[i...])
            let ns = rest as NSString
            if let m = specialToken.firstMatch(in: rest, options: [], range: NSRange(location: 0, length: ns.length)),
               m.range.location != NSNotFound {
                let before = ns.substring(with: NSRange(location: 0, length: m.range.location))
                out += before
                // Skip the token
                let advance = m.range.location + m.range.length
                i = raw.index(i, offsetBy: advance)
            } else {
                out += rest
                break
            }
        }
        return out
    }

    private static func mergeThinking(_ a: String?, _ b: String?) -> String? {
        let parts = [a, b]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }
}
