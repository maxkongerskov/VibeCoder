//
//  CompactEventCopy.swift
//
//  Human-readable copy for context-compaction notices.
//  Pure formatting — no UI framework — so AgentCore tests and ChatViewModel
//  share the same “what was summarized / elided” wording.
//

import Foundation

/// Title + detail + short status line for a compaction event.
public struct CompactEventCopy: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        /// Auto-compact on the wire path only (transcript stays full).
        case autoWire
        /// Manual `/compact` that rewrote the saved transcript.
        case manualRewrite
    }

    public let title: String
    public let detail: String
    public let statusLine: String
    public let source: Source
    public let droppedMessages: Int
    /// Short bullets extracted from the summary (files, decisions, goal).
    public let highlights: [String]

    public init(
        title: String,
        detail: String,
        statusLine: String,
        source: Source,
        droppedMessages: Int,
        highlights: [String]
    ) {
        self.title = title
        self.detail = detail
        self.statusLine = statusLine
        self.source = source
        self.droppedMessages = droppedMessages
        self.highlights = highlights
    }

    /// Build user-facing copy from the event payload (summary preview + drop count).
    public static func make(
        summaryPreview: String,
        droppedMessages: Int,
        source: Source = .autoWire
    ) -> CompactEventCopy {
        let preview = summaryPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        let extracted = extractHighlights(from: preview)
        let highlights = extracted.bullets

        let title: String
        switch source {
        case .autoWire:
            title = droppedMessages > 0
                ? "Context compacted"
                : "Context summarized"
        case .manualRewrite:
            title = "Conversation compacted"
        }

        let dropPhrase: String
        if droppedMessages <= 0 {
            dropPhrase = "Older tool outputs and long turns were elided on the model prompt"
        } else if droppedMessages == 1 {
            dropPhrase = "1 older message was summarized"
        } else {
            dropPhrase = "\(droppedMessages) older messages were summarized"
        }

        var detailParts: [String] = []
        detailParts.append(dropPhrase + ".")
        detailParts.append("Recent turns kept verbatim.")

        switch source {
        case .autoWire:
            detailParts.append("Auto-compact is wire-only — the chat transcript still shows full history.")
        case .manualRewrite:
            detailParts.append("The saved transcript was rewritten. Use /undo to restore the previous snapshot.")
        }

        if let goal = extracted.goal, !goal.isEmpty {
            detailParts.append("Goal kept: \(truncate(goal, 120))")
        }
        if !extracted.files.isEmpty {
            let listed = extracted.files.prefix(6).joined(separator: ", ")
            let more = extracted.files.count > 6 ? " (+\(extracted.files.count - 6) more)" : ""
            detailParts.append("Files in summary: \(listed)\(more).")
        }
        if !extracted.decisions.isEmpty {
            let d = extracted.decisions.prefix(2).map { truncate($0, 90) }.joined(separator: "; ")
            detailParts.append("Decisions retained: \(d).")
        }
        if !extracted.failures.isEmpty {
            detailParts.append("Failures noted: \(extracted.failures.count).")
        }

        // When structured fields are thin, surface a cleaned preview snippet
        // so the notice is never a silent no-op when the model produced text.
        if highlights.isEmpty, !preview.isEmpty {
            let cleaned = cleanPreviewSnippet(preview)
            if !cleaned.isEmpty {
                detailParts.append("Summary: \(truncate(cleaned, 200))")
            }
        }

        let detail = detailParts.joined(separator: " ")

        let statusLine: String
        if droppedMessages > 0, !extracted.files.isEmpty {
            let fileHint = extracted.files.prefix(2).joined(separator: ", ")
            statusLine = "Context compacted (\(droppedMessages) msgs) · \(fileHint)"
        } else if droppedMessages > 0, !preview.isEmpty {
            statusLine = "Context compacted (\(droppedMessages) msgs): \(truncate(cleanPreviewSnippet(preview), 80))"
        } else if droppedMessages > 0 {
            statusLine = "Context compacted (\(droppedMessages) older messages)"
        } else {
            statusLine = source == .manualRewrite
                ? "History already compact"
                : "Context elided on wire (no messages dropped)"
        }

        return CompactEventCopy(
            title: title,
            detail: detail,
            statusLine: statusLine,
            source: source,
            droppedMessages: droppedMessages,
            highlights: highlights
        )
    }

    // MARK: - Summary parsing

    private struct Extracted {
        var goal: String?
        var files: [String] = []
        var decisions: [String] = []
        var failures: [String] = []
        var bullets: [String] = []
    }

    /// Pull structured fields from extractive / full-replace summary text.
    private static func extractHighlights(from preview: String) -> Extracted {
        var out = Extracted()
        guard !preview.isEmpty else { return out }

        var section: String?
        for raw in preview.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()

            if lower.hasPrefix("current_goal:") {
                let v = String(line.dropFirst("current_goal:".count)).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { out.goal = v }
                section = nil
                continue
            }
            if lower == "decisions:" || lower.hasPrefix("decisions:") {
                section = "decisions"
                let rest = line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { out.decisions.append(stripBullet(rest)) }
                continue
            }
            if lower == "files_touched:" || lower.hasPrefix("files_touched:") {
                section = "files"
                let rest = line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { out.files.append(stripBullet(rest)) }
                continue
            }
            if lower == "failing_commands_or_errors:" || lower.hasPrefix("failing_commands_or_errors:") {
                section = "failures"
                continue
            }
            if lower == "open_todos:" || lower.hasPrefix("open_todos:") {
                section = "todos"
                continue
            }
            if lower.hasPrefix("hint:") || lower.hasPrefix("[context") || lower.hasPrefix("[full-replace")
                || lower.hasPrefix("note:") {
                section = nil
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("  -") {
                let item = stripBullet(line)
                switch section {
                case "files": out.files.append(item)
                case "decisions": out.decisions.append(item)
                case "failures": out.failures.append(item)
                default: break
                }
            }
        }

        if let g = out.goal { out.bullets.append("Goal: \(truncate(g, 80))") }
        for f in out.files.prefix(4) { out.bullets.append("File: \(truncate(f, 60))") }
        for d in out.decisions.prefix(2) { out.bullets.append("Decision: \(truncate(d, 80))") }
        return out
    }

    private static func stripBullet(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- ") { t = String(t.dropFirst(2)) }
        if t.hasPrefix("• ") { t = String(t.dropFirst(2)) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Drop machine headers so the status line shows readable content.
    private static func cleanPreviewSnippet(_ preview: String) -> String {
        let skipPrefixes = [
            "[context summary",
            "[full-replace",
            "[context compaction",
            "hint:",
            "note:",
        ]
        let lines = preview.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let lower = line.lowercased()
                if line.isEmpty { return false }
                for p in skipPrefixes where lower.hasPrefix(p) { return false }
                return true
            }
        return lines.joined(separator: " · ")
    }

    private static func truncate(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max - 1)) + "…"
    }
}
