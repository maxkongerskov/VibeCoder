//
//  FullReplaceCompactor.swift
//  Grok-class full-replace compaction: summarize older history into one
//  carrier message; keep recent turns verbatim. Extractive by default;
//  optional LLM summarizer via HistorySummarizing.
//

import Foundation

public struct FullReplaceResult: Sendable {
    public var messages: [ChatMessage]
    public var summary: String
    public var droppedCount: Int
    public var durableNote: String
}

public enum FullReplaceCompactor {

    /// When estimated tokens meet/exceed `budget * thresholdFraction`, compact.
    ///
    /// Default **1.0** (Wave C2): fire when over the configured budget.
    /// Budget already reserves headroom via `ContextBudget` (default 70% of
    /// window). Prior 0.85 default stacked as ~60% of window and fired early.
    public static func shouldCompact(
        messages: [ChatMessage],
        systemPromptTokens: Int,
        budgetTokens: Int,
        thresholdFraction: Double = 1.0
    ) -> Bool {
        guard budgetTokens > 0 else { return false }
        let used = ChatLoop.estimateTotalTokens(
            systemPromptTokens: systemPromptTokens, messages: messages)
        return Double(used) >= Double(budgetTokens) * thresholdFraction
    }

    public static func compact(
        _ messages: [ChatMessage],
        systemPromptTokens: Int,
        budgetTokens: Int,
        keepRecent: Int = 6,
        summarizer: (any HistorySummarizing)? = nil
    ) async -> FullReplaceResult {
        guard messages.count > keepRecent + 1 else {
            return FullReplaceResult(
                messages: messages, summary: "", droppedCount: 0, durableNote: "")
        }
        // Find a cut that doesn't split tool_calls from results
        var cut = max(0, messages.count - keepRecent)
        while cut > 0 && cut < messages.count {
            let m = messages[cut]
            if m.role == .tool { cut -= 1; continue }
            break
        }
        // No safe prefix to drop — do not inject an empty carrier (would bloat wire).
        guard cut > 0 else {
            return FullReplaceResult(
                messages: messages, summary: "", droppedCount: 0, durableNote: "")
        }
        let older = Array(messages.prefix(cut))
        guard !older.isEmpty else {
            return FullReplaceResult(
                messages: messages, summary: "", droppedCount: 0, durableNote: "")
        }
        let recent = Array(messages.suffix(messages.count - cut))
        let hint = "Preserve decisions, file paths, failures, and current goal."
        let summary: String
        if let summarizer {
            // Fail open to extractive — never leave the loop without a summary
            // when we already decided to drop older turns.
            summary = (try? await summarizer.summarize(messages: older, systemHint: hint))
                ?? ExtractiveHistorySummarizer().forceSyncSummary(older, hint: hint)
        } else {
            summary = ExtractiveHistorySummarizer().forceSyncSummary(older, hint: hint)
        }
        let durable = Self.extractDurableNote(from: summary, older: older)
        let carrier = ChatMessage(
            role: .user,
            content: "[context compaction — full replace of older turns]\n" + summary)
        var out = [carrier] + recent
        // If still over budget, elide
        if budgetTokens > 0 {
            out = ChatLoop.compactHistory(
                out, systemPromptTokens: systemPromptTokens, budgetTokens: budgetTokens)
        }
        return FullReplaceResult(
            messages: out,
            summary: summary,
            droppedCount: older.count,
            durableNote: durable)
    }

    /// Static helpers for word-boundary matching in `extractDurableNote`.
    /// Uses negative lookbehind/lookahead for `-` to reject compounds like "decision-making".
    private static let decisionRe = try! NSRegularExpression(
        pattern: #"(?<![a-zA-Z])(decide|decided|decision)(?![a-zA-Z-])"#, options: []
    )
    private static let avoidRe = try! NSRegularExpression(pattern: #"\bavoid\b"#, options: [])
    private static let willUseRe = try! NSRegularExpression(pattern: #"will use\b"#, options: [])
    private static let willRe = try! NSRegularExpression(pattern: #"will \b"#, options: [])
    private static func reMatches(_ re: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return re.firstMatch(in: s, range: range) != nil
    }

    public static func extractDurableNote(from summary: String, older: [ChatMessage]) -> String {
        var lines: [String] = []
        // Prefer body lines under a "decisions:" section (extractive summarizer format)
        var inDecisions = false
        for line in summary.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let l = trimmed.lowercased()
            if l == "decisions:" || l.hasPrefix("decisions:") {
                inDecisions = true
                continue
            }
            if inDecisions {
                if trimmed.isEmpty { inDecisions = false; continue }
                if trimmed.hasPrefix("open_todos") || trimmed.hasPrefix("files_touched")
                    || trimmed.hasPrefix("failing_") || trimmed.hasPrefix("note:")
                    || trimmed.hasPrefix("current_goal") {
                    inDecisions = false
                    continue
                }
                // Keep bullet bodies, not just the section header
                let body = trimmed.hasPrefix("-")
                    ? trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                    : trimmed
                if !body.isEmpty { lines.append(String(body.prefix(200))) }
                continue
            }
            // Also keep lines that themselves encode a decision.
            // Use word-boundary regex to avoid false-positives like "decisions" or "decision-making".
            let hasDecisionPattern = reMatches(decisionRe, l)
                || reMatches(avoidRe, l)
                || reMatches(willUseRe, l)
                || reMatches(willRe, l)
            if hasDecisionPattern {
                // Skip pure section headers / hints
                if l == "decisions:" || l.hasPrefix("hint:") || l.hasPrefix("[full-replace") {
                    continue
                }
                lines.append(String(trimmed.prefix(200)))
            }
        }
        // Always harvest assistant decision prose from older turns (source of truth)
        for m in older where m.role == .assistant {
            let c = m.content
            let lower = c.lowercased()
            let hasDecisionMessage = reMatches(decisionRe, lower)
                || reMatches(avoidRe, lower)
                || reMatches(willUseRe, lower)
            if hasDecisionMessage {
                lines.append(String(c.prefix(200)))
            }
        }
        // Dedupe while preserving order
        var seen = Set<String>()
        var unique: [String] = []
        for line in lines {
            let key = line.lowercased()
            if seen.insert(key).inserted { unique.append(line) }
        }
        return unique.prefix(8).joined(separator: "\n")
    }
}

// forceSyncSummary lives on ExtractiveHistorySummarizer in SemanticCompactor.swift
// (shared extractive body so FullReplace `files_touched` cannot go dead again).
