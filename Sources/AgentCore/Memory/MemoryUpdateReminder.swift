//
//  MemoryUpdateReminder.swift
//
//  Mid-turn reminder payload when `memory` writes durable notes.
//  AgentLoop caches project memory once per run(); this reminder is what
//  later iterations (and a future recordToolResult extras hook) should
//  treat as current. No embeddings. Not a compactor.
//

import Foundation

public enum MemoryUpdateReminder: Sendable {

    /// COORDINATION extras key. Opaque to the model unless folded into content.
    public static let extrasKey = "memory_update"

    /// Matches `SystemReminder` wire-only prefix (`# System reminder`).
    public static let heading = "# System reminder — memory update"

    public static let defaultMaxChars = 400

    /// Write actions that emit a reminder. `read` never does.
    public static let writeActions: Set<String> = [
        "remember", "log_decision", "write_handoff",
    ]

    /// True when this turn should publish a reminder.
    public static func shouldEmit(action: String, isError: Bool, body: String) -> Bool {
        guard !isError else { return false }
        guard writeActions.contains(action) else { return false }
        return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Model-facing reminder body (also stored in `ToolResult.extras`).
    public static func format(
        action: String,
        body: String,
        maxChars: Int = defaultMaxChars
    ) -> String {
        let clipped = clip(body, maxChars: maxChars)
        return """
        \(heading)
        Action: \(action)
        The following was just written to project memory. The cached memory \
        block in the system prompt is stale until the next user turn — treat \
        this as current.

        \(clipped)
        """
    }

    public static func extract(_ extras: [String: String]) -> String? {
        guard let raw = extras[extrasKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    public static func isMemoryUpdate(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(heading)
    }

    /// Successful write → ack content + extras payload (content first line unchanged).
    public static func result(
        content: String,
        action: String,
        body: String,
        mutatedPaths: [String] = []
    ) -> ToolResult {
        guard shouldEmit(action: action, isError: false, body: body) else {
            return ToolResult(content: content, mutatedPaths: mutatedPaths)
        }
        let reminder = format(action: action, body: body)
        return ToolResult(
            content: content + "\n\n" + reminder,
            mutatedPaths: mutatedPaths,
            extras: [extrasKey: reminder]
        )
    }

    // MARK: - Internals

    public static func clip(_ body: String, maxChars: Int = defaultMaxChars) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        return String(trimmed.prefix(maxChars)) + "…"
    }
}
