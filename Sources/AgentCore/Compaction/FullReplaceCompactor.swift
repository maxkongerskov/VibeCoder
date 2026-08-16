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

    /// ZCode `yke` continuation framing injected as the carrier user message.
    public static let continuationPreamble =
        "This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation."

    /// Numbered headings matching ZCode `dxi` (extractive + LLM).
    public static let nineSectionHeadings: [String] = [
        "Primary Request and Intent",
        "Key Technical Concepts",
        "Files and Code Sections",
        "Errors and fixes",
        "Problem Solving",
        "All user messages",
        "Pending Tasks",
        "Current Work",
        "Optional Next Step",
    ]

    /// Full ZCode compact-prompt instructions for an optional LLM summarizer.
    public static let nineSectionInstructions: String = """
    CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.

    - Do NOT use Read, Bash, Grep, Glob, Edit, Write, or ANY other tool.
    - You already have all the context you need in the conversation above.
    - Tool calls will be REJECTED and will waste your only turn — you will fail the task.
    - Your entire response must be plain text: an <analysis> block followed by a <summary> block.

    Your task is to create a detailed summary of the conversation so far, paying close attention to the user's explicit requests and your previous actions.
    This summary should be thorough in capturing technical details, code patterns, and architectural decisions that would be essential for continuing development work without losing context.

    Before providing your final summary, wrap your analysis in <analysis> tags to organize your thoughts and ensure you've covered all necessary points. In your analysis process:

    1. Chronologically analyze each message and section of the conversation. For each section thoroughly identify:
       - The user's explicit requests and intents
       - Your approach to addressing the user's requests
       - Key decisions, technical concepts and code patterns
       - Specific details like file names, full code snippets, function signatures, file edits
       - Errors that you ran into and how you fixed them
       - Pay special attention to specific user feedback that you received, especially if the user told you to do something differently.
       - Note any security-relevant instructions or constraints the user stated. These MUST be preserved verbatim in the summary so they continue to apply after compaction.
    2. Double-check for technical accuracy and completeness, addressing each required element thoroughly.

    Your summary should include the following sections:

    1. Primary Request and Intent: Capture all of the user's explicit requests and intents in detail
    2. Key Technical Concepts: List all important technical concepts, technologies, and frameworks discussed.
    3. Files and Code Sections: Enumerate specific files and code sections examined, modified, or created. Pay special attention to the most recent messages and include full code snippets where applicable and include a summary of why this file read or edit is important.
    4. Errors and fixes: List all errors that you ran into, and how you fixed them. Pay special attention to specific user feedback that you received, especially if the user told you to do something differently.
    5. Problem Solving: Document problems solved and any ongoing troubleshooting efforts.
    6. All user messages: List ALL user messages that are not tool results. These are critical for understanding the users' feedback and changing intent. Preserve any security-relevant instructions or constraints verbatim so they remain in effect after compaction.
    7. Pending Tasks: Outline any pending tasks that you have explicitly been asked to work on.
    8. Current Work: Describe in detail precisely what was being worked on immediately before this summary request, paying special attention to the most recent messages from both user and assistant. Include file names and code snippets where applicable.
    9. Optional Next Step: List the next step that you will take that is related to the most recent work you were doing. IMPORTANT: ensure that this step is DIRECTLY in line with the user's most recent explicit requests, and the task you were working on immediately before this summary request. If your last task was concluded, then only list next steps if they are explicitly in line with the users request. Do not start on tangential requests or really old requests that were already completed without confirming with the user first.
                           If there is a next step, include direct quotes from the most recent conversation showing exactly what task you were working on and where you left off. This should be verbatim to ensure there's no drift in task interpretation.

    REMINDER: Do NOT call any tools. Respond with plain text only — an <analysis> block followed by a <summary> block. Tool calls will be rejected and you will fail the task.
    """

    /// Strip ZCode `<analysis>` and unwrap `<summary>` (no-op on extractive text).
    public static func formatCompactSummary(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        if let analysis = t.range(
            of: #"<analysis>[\s\S]*?</analysis>"#,
            options: .regularExpression
        ) {
            t.removeSubrange(analysis)
        }
        if let match = t.range(
            of: #"<summary>([\s\S]*?)</summary>"#,
            options: .regularExpression
        ) {
            let inner = t[match]
            let stripped = inner
                .replacingOccurrences(of: "<summary>", with: "")
                .replacingOccurrences(of: "</summary>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            t.replaceSubrange(match, with: "Summary:\n\(stripped)")
        }
        while t.contains("\n\n\n") {
            t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Model-facing carrier body: continuation preamble + formatted summary.
    public static func wrapContinuation(
        summary: String,
        recentMessagesPreserved: Bool = true
    ) -> String {
        var body = continuationPreamble + "\n\n" + formatCompactSummary(summary)
        if recentMessagesPreserved {
            body += "\n\nRecent messages are preserved verbatim."
        }
        return body
    }

    public static func makeContinuationCarrier(
        summary: String,
        recentMessagesPreserved: Bool = true
    ) -> ChatMessage {
        ChatMessage(
            role: .user,
            content: wrapContinuation(
                summary: summary,
                recentMessagesPreserved: recentMessagesPreserved))
    }

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
        let hint = nineSectionInstructions
        let summary: String
        if let summarizer {
            // Fail open to extractive — never leave the loop without a summary
            // when we already decided to drop older turns.
            let raw = (try? await summarizer.summarize(messages: older, systemHint: hint))
                ?? ExtractiveHistorySummarizer.buildNineSectionSummary(messages: older)
            summary = formatCompactSummary(raw)
        } else {
            summary = ExtractiveHistorySummarizer.buildNineSectionSummary(messages: older)
        }
        let durable = Self.extractDurableNote(from: summary, older: older)
        let carrier = makeContinuationCarrier(summary: summary)
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

    private static func isNineSectionBoundary(_ trimmed: String) -> Bool {
        let l = trimmed.lowercased()
        if l.hasPrefix("1.") || l.hasPrefix("2.") || l.hasPrefix("3.")
            || l.hasPrefix("4.") || l.hasPrefix("5.") || l.hasPrefix("6.")
            || l.hasPrefix("7.") || l.hasPrefix("8.") || l.hasPrefix("9.") {
            return nineSectionHeadings.contains { l.contains($0.lowercased()) }
        }
        return nineSectionHeadings.contains { heading in
            l == heading.lowercased() || l.hasPrefix(heading.lowercased() + ":")
        }
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
            if l.contains("key technical concepts") {
                inDecisions = true
                continue
            }
            if inDecisions {
                if trimmed.isEmpty { inDecisions = false; continue }
                if trimmed.hasPrefix("open_todos") || trimmed.hasPrefix("files_touched")
                    || trimmed.hasPrefix("failing_") || trimmed.hasPrefix("note:")
                    || trimmed.hasPrefix("current_goal")
                    || trimmed.hasPrefix("pending_tasks")
                    || isNineSectionBoundary(trimmed) {
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

// Extractive 9-section + legacy `forceSyncSummary` live on
// ExtractiveHistorySummarizer (shared fact mining with SemanticCompactor).
