//
//  SemanticCompactor.swift
//
//  Threshold-based history compaction that replaces older turns with a
//  structured summary (decisions, todos, files, failures, goal) rather
//  than elision-only. Keeps recent turns verbatim and preserves
//  assistant↔tool pairing invariants.
//

import Foundation

/// Pluggable summarizer so tests can inject a deterministic implementation
/// while production uses a real backend-backed seam.
public protocol HistorySummarizing: Sendable {
    func summarize(messages: [ChatMessage], systemHint: String) async throws -> String
}

/// Deterministic extractive summarizer — no LLM required. Used as default
/// and in CI. Production can wrap a backend with `LLMHistorySummarizer`.
public struct ExtractiveHistorySummarizer: HistorySummarizing {
    public init() {}

    public func summarize(messages: [ChatMessage], systemHint: String) async throws -> String {
        Self.buildSummary(
            messages: messages,
            systemHint: systemHint,
            header: "[context summary — compacted older turns]")
    }

    /// Sync path for FullReplace / tests (same extractive body as `summarize`).
    public func forceSyncSummary(_ messages: [ChatMessage], hint: String) -> String {
        Self.buildSummary(
            messages: messages,
            systemHint: hint,
            header: "[full-replace summary]")
    }

    /// Shared extractive body — used by Semantic + FullReplace so `files_touched`
    /// and decision mining cannot drift.
    public static func buildSummary(
        messages: [ChatMessage],
        systemHint: String,
        header: String
    ) -> String {
        var decisions: [String] = []
        var files: Set<String> = []
        var failures: [String] = []
        var todos: [String] = []
        var goals: [String] = []
        var lastUser = ""

        for m in messages {
            if m.role == .user {
                lastUser = String(m.content.prefix(200))
                if m.content.lowercased().contains("goal") || m.content.count < 120 {
                    goals.append(String(m.content.prefix(160)))
                }
            }
            if m.role == .assistant {
                let lower = m.content.lowercased()
                if lower.contains("decide") || lower.contains("will ") {
                    decisions.append(String(m.content.prefix(160)))
                }
                for tc in m.toolCalls {
                    if tc.name.contains("plan") || tc.name.contains("todo") {
                        todos.append("\(tc.name): \(String(tc.arguments.prefix(80)))")
                    }
                    if let path = extractPathArgument(from: tc.arguments) {
                        files.insert(path)
                    }
                }
            }
            if m.role == .tool {
                if m.content.lowercased().contains("error")
                    || m.content.lowercased().contains("failed")
                    || m.content.hasPrefix("Tool error") {
                    failures.append(String(m.content.prefix(160)))
                }
                if m.content.contains("Edited ") || m.content.contains("Created ") {
                    files.insert(String(m.content.prefix(80)))
                }
            }
        }

        var lines: [String] = [
            header,
            systemHint.isEmpty ? "" : "hint: \(systemHint)",
            "current_goal: \(goals.last ?? lastUser)",
        ]
        if !decisions.isEmpty {
            lines.append("decisions:")
            lines.append(contentsOf: decisions.suffix(6).map { "  - \($0)" })
        }
        if !todos.isEmpty {
            lines.append("open_todos:")
            lines.append(contentsOf: todos.suffix(8).map { "  - \($0)" })
        }
        if !files.isEmpty {
            lines.append("files_touched:")
            lines.append(contentsOf: files.prefix(20).map { "  - \($0)" })
        }
        if !failures.isEmpty {
            lines.append("failing_commands_or_errors:")
            lines.append(contentsOf: failures.suffix(6).map { "  - \($0)" })
        }
        lines.append("note: recent turns after this summary are verbatim.")
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// JSON `"path"` field when present (same contract as ToolResultCompressor).
    public static func extractPathArgument(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String, !path.isEmpty else { return nil }
        return path
    }
}

public struct SemanticCompactionResult: Sendable {
    public let messages: [ChatMessage]
    public let didCompact: Bool
    public let summary: String?
    public let droppedCount: Int
}

public enum SemanticCompactor {

    public static let defaultSystemHint =
        "Retain decisions, open todos, files touched, failures, current goal."

    /// Compact when total tokens exceed budget. Replaces the older region
    /// (everything before `keepRecent` messages) with a single user-role
    /// summary message so tool_call pairing in the recent region stays valid.
    ///
    /// Strategy: find a cut index that does not split an assistant tool_calls
    /// message from its tool results — we only replace a clean prefix.
    public static func compact(
        _ messages: [ChatMessage],
        systemPromptTokens: Int,
        budgetTokens: Int,
        keepRecent: Int = 6,
        systemHint: String = SemanticCompactor.defaultSystemHint,
        summarizer: any HistorySummarizing = ExtractiveHistorySummarizer()
    ) async -> SemanticCompactionResult {
        guard budgetTokens > 0 else {
            return .init(messages: messages, didCompact: false, summary: nil, droppedCount: 0)
        }
        let total = ChatLoop.estimateTotalTokens(
            systemPromptTokens: systemPromptTokens, messages: messages)
        guard total > budgetTokens, messages.count > keepRecent + 1 else {
            return .init(messages: messages, didCompact: false, summary: nil, droppedCount: 0)
        }

        let cut = safeCutIndex(messages, keepRecent: keepRecent)
        guard cut > 0 else {
            return .init(messages: messages, didCompact: false, summary: nil, droppedCount: 0)
        }

        let older = Array(messages.prefix(cut))
        let recent = Array(messages.suffix(from: cut))
        let summaryText: String
        do {
            summaryText = try await summarizer.summarize(
                messages: older,
                systemHint: systemHint)
        } catch {
            // Fall back to elision-only on summarizer failure
            let elided = ChatLoop.compactHistory(
                messages,
                systemPromptTokens: systemPromptTokens,
                budgetTokens: budgetTokens,
                keepRecent: keepRecent)
            let changed = elided.count != messages.count
                || zip(elided, messages).contains { $0.content != $1.content }
            return .init(messages: elided, didCompact: changed,
                         summary: nil, droppedCount: 0)
        }

        let summaryMessage = ChatMessage(role: .user, content: summaryText)
        let merged = [summaryMessage] + recent
        return .init(
            messages: merged,
            didCompact: true,
            summary: summaryText,
            droppedCount: older.count
        )
    }

    /// Index such that `messages[0..<cut]` can be dropped without leaving
    /// dangling tool results in the kept suffix.
    ///
    /// Algorithm (aligned with FullReplaceCompactor): start at
    /// `n - keepRecent`, then walk **back** while the cut lands on a
    /// `.tool` so the owning assistant stays with its results in the
    /// kept region. Never walk *forward* over tools while dropping their
    /// assistant (that orphans tool messages — OpenAI 400).
    public static func safeCutIndex(_ messages: [ChatMessage], keepRecent: Int) -> Int {
        let n = messages.count
        guard n > keepRecent else { return 0 }
        var cut = n - keepRecent
        // Don't start the kept region mid tool-result run.
        while cut > 0 && cut < n && messages[cut].role == .tool {
            cut -= 1
        }
        // Prefer a nearby user boundary for cleaner narrative (optional snap).
        var snap = cut
        while snap > 0, messages[snap].role != .user, snap > cut - 4 {
            snap -= 1
        }
        if snap > 0, messages[snap].role == .user {
            // Only snap if it does not re-introduce a tool-start cut.
            if messages[snap].role != .tool {
                cut = snap
            }
        }
        // Final guard: never leave cut on a tool.
        while cut > 0 && cut < n && messages[cut].role == .tool {
            cut -= 1
        }
        return max(0, min(cut, n - 1))
    }
}
