//
//  ThinkTagSplit.swift
//
//  Split model output into reasoning vs answer when the backend embeds
//  thinking in content (e.g. <think>…</think>) instead of reasoning_content.
//  Shared by AgentLoop finalize and App transcript UI.
//

import Foundation

public struct ThinkTagSplit: Equatable, Sendable {
    public var thinking: String?
    public var body: String
    public var isThinkingOpen: Bool

    public init(thinking: String?, body: String, isThinkingOpen: Bool) {
        self.thinking = thinking
        self.body = body
        self.isThinkingOpen = isThinkingOpen
    }

    public static func parse(_ raw: String) -> ThinkTagSplit {
        let pairs: [(String, String)] = [
            ("<thinking>", "</thinking>"),
            ("<thought>", "</thought>"),
            ("<reasoning>", "</reasoning>"),
            ("<think>", "</think>"),
        ]

        var thinkingParts: [String] = []
        var bodyParts: [String] = []
        var isThinkingOpen = false
        var cursor = raw.startIndex
        var foundAny = false

        while cursor < raw.endIndex {
            guard let (openRange, closeTag) = nextOpenTag(
                in: raw, from: cursor, pairs: pairs
            ) else {
                if foundAny {
                    bodyParts.append(String(raw[cursor...]))
                }
                break
            }
            foundAny = true
            if openRange.lowerBound > cursor {
                bodyParts.append(String(raw[cursor..<openRange.lowerBound]))
            }
            let afterOpen = openRange.upperBound
            if let close = raw.range(
                of: closeTag,
                options: .caseInsensitive,
                range: afterOpen..<raw.endIndex
            ) {
                let inner = String(raw[afterOpen..<close.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { thinkingParts.append(inner) }
                cursor = close.upperBound
            } else {
                let inner = String(raw[afterOpen...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { thinkingParts.append(inner) }
                isThinkingOpen = true
                cursor = raw.endIndex
            }
        }

        if !foundAny {
            return ThinkTagSplit(thinking: nil, body: raw, isThinkingOpen: false)
        }

        let thinking = thinkingParts.joined(separator: "\n\n")
        let body = bodyParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return ThinkTagSplit(
            thinking: thinking.isEmpty ? nil : thinking,
            body: body,
            isThinkingOpen: isThinkingOpen
        )
    }

    /// Earliest open tag from `cursor`. Longer tags win at the same index
    /// so `<thinking>` is not consumed as `<think>`.
    private static func nextOpenTag(
        in raw: String,
        from cursor: String.Index,
        pairs: [(String, String)]
    ) -> (Range<String.Index>, String)? {
        var best: (range: Range<String.Index>, close: String)?
        for (open, close) in pairs {
            guard let range = raw.range(
                of: open,
                options: .caseInsensitive,
                range: cursor..<raw.endIndex
            ) else { continue }
            if let current = best {
                if range.lowerBound < current.range.lowerBound {
                    best = (range, close)
                } else if range.lowerBound == current.range.lowerBound,
                          range.upperBound > current.range.upperBound {
                    best = (range, close)
                }
            } else {
                best = (range, close)
            }
        }
        guard let best else { return nil }
        return (best.range, best.close)
    }
}
