//
//  PendingWakeInject.swift
//
//  Depth D4 — Next-turn / next-iteration inject queue for background job
//  completion wakes. Separate from InterjectionBuffer so hard-stop `clear`
//  cannot drop job completions that finished after the last drain.
//
//  AgentLoop drains at each iteration start into system-reminder nudges
//  (and a user-visible transcript line). Not a Grok full monitor product.
//

import Foundation

public actor PendingWakeInject {
    public static let shared = PendingWakeInject()

    private var pending: [UUID: [String]] = [:]
    private static let maxPerConversation = 32

    /// Queue a model-visible wake for a conversation (idempotent per message text not required).
    public func enqueue(conversationID: UUID, message: String) {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var list = pending[conversationID] ?? []
        list.append(t)
        while list.count > Self.maxPerConversation { list.removeFirst() }
        pending[conversationID] = list
    }

    /// Atomically take all wakes for a conversation (FIFO).
    public func drain(conversationID: UUID) -> [String] {
        let items = pending[conversationID] ?? []
        pending[conversationID] = nil
        return items
    }

    public func peekCount(conversationID: UUID) -> Int {
        pending[conversationID]?.count ?? 0
    }

    public func clear(conversationID: UUID) {
        pending[conversationID] = nil
    }

    public func clearAll() {
        pending.removeAll()
    }

    /// Format a BackgroundJobCompletion into inject text for the parent model.
    public static func formatWakeMessage(_ notice: BackgroundJobCompletion) -> String {
        let kind = notice.kind == .subagent ? "subagent" : "shell"
        let status = notice.status.rawValue
        let cmd = notice.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = notice.outputPreview
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortPreview = preview.count > 200 ? String(preview.prefix(197)) + "…" : preview
        var lines = [
            "[Background job \(status)] kind=\(kind) task_id=\(notice.taskId.uuidString)",
        ]
        if !cmd.isEmpty {
            lines.append("command: \(cmd)")
        }
        if !shortPreview.isEmpty {
            lines.append("output: \(shortPreview)")
        }
        lines.append("Use get_task_output / list_background_jobs if you need more detail.")
        return lines.joined(separator: "\n")
    }
}
