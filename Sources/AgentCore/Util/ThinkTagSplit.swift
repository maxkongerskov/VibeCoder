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
            ("<think>", "</think>"),
            ("<thinking>", "</thinking>"),
            ("<thought>", "</thought>"),
            ("<reasoning>", "</reasoning>"),
        ]
        for (open, close) in pairs {
            if let split = parseTagged(raw, open: open, close: close) {
                return split
            }
        }
        return ThinkTagSplit(thinking: nil, body: raw, isThinkingOpen: false)
    }

    private static func parseTagged(
        _ raw: String,
        open openTag: String,
        close closeTag: String
    ) -> ThinkTagSplit? {
        if let open = raw.range(of: openTag, options: .caseInsensitive),
           let close = raw.range(of: closeTag, options: .caseInsensitive),
           open.lowerBound < close.lowerBound
        {
            let thinking = String(raw[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let before = String(raw[..<open.lowerBound])
            let after = String(raw[close.upperBound...])
            let body = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
            return ThinkTagSplit(
                thinking: thinking.isEmpty ? nil : thinking,
                body: body,
                isThinkingOpen: false
            )
        }
        if let open = raw.range(of: openTag, options: .caseInsensitive) {
            let thinking = String(raw[open.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let before = String(raw[..<open.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ThinkTagSplit(
                thinking: thinking.isEmpty ? nil : thinking,
                body: before,
                isThinkingOpen: true
            )
        }
        return nil
    }
}
