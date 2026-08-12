//
//  HunkTracker.swift
//
//  Records successful file mutations as trackable hunks for Ask-mode
//  review and UI. Grok-port origin helpers for agent vs external edits.
//

import Foundation

public struct TrackedHunk: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let conversationID: UUID
    public let path: String
    public let originalContent: String
    public let updatedContent: String
    public let appliedAt: Date
    public var status: Status

    public enum Status: String, Sendable, Equatable {
        case applied
        case rejected
        case rolledBack
    }

    public init(id: UUID = UUID(),
                conversationID: UUID,
                path: String,
                originalContent: String,
                updatedContent: String,
                appliedAt: Date = Date(),
                status: Status = .applied) {
        self.id = id
        self.conversationID = conversationID
        self.path = path
        self.originalContent = originalContent
        self.updatedContent = updatedContent
        self.appliedAt = appliedAt
        self.status = status
    }
}

public actor HunkTracker {
    public static let shared = HunkTracker()

    private var hunks: [UUID: TrackedHunk] = [:]
    private var orderByConversation: [UUID: [UUID]] = [:]
    private var agentPaths: Set<String> = []

    public enum Origin: String, Sendable, Equatable {
        case agent, external, unknown
    }

    public func record(_ hunk: TrackedHunk) {
        hunks[hunk.id] = hunk
        var list = orderByConversation[hunk.conversationID] ?? []
        list.append(hunk.id)
        orderByConversation[hunk.conversationID] = list
    }

    public func hunks(for conversationID: UUID) -> [TrackedHunk] {
        (orderByConversation[conversationID] ?? []).compactMap { hunks[$0] }
    }

    /// Outcome of post-apply Undo (`reject`). Distinguishes drift from
    /// missing/already-undone so Chat can toast honestly.
    public enum RejectOutcome: String, Sendable, Equatable {
        case rolledBack
        case notFound
        case alreadyRolledBack
        case fileChanged
    }

    /// Roll disk back to `originalContent` when the file still matches
    /// `updatedContent`. Returns `false` (no write) if the hunk is missing,
    /// already rolled back, or the file was modified since the agent edit
    /// (fail-closed — do not clobber concurrent user/agent edits).
    public func reject(id: UUID) throws -> Bool {
        try rejectDetailed(id: id) == .rolledBack
    }

    /// Like `reject`, but reports why undo was skipped.
    public func rejectDetailed(id: UUID) throws -> RejectOutcome {
        guard let existing = hunks[id] else { return .notFound }
        if existing.status == .rolledBack || existing.status == .rejected {
            return .alreadyRolledBack
        }
        guard existing.status == .applied else { return .notFound }
        var hunk = existing
        let url = URL(fileURLWithPath: hunk.path)
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if current != hunk.updatedContent {
            return .fileChanged
        }
        try hunk.originalContent.write(to: url, atomically: true, encoding: .utf8)
        hunk.status = .rolledBack
        hunks[id] = hunk
        return .rolledBack
    }

    /// Drop a tracked hunk without rewriting disk (e.g. mid-batch write rollback
    /// already restored files — leave no ghost hunk for Ask reject UI).
    public func discard(id: UUID) {
        guard let hunk = hunks.removeValue(forKey: id) else { return }
        if var list = orderByConversation[hunk.conversationID] {
            list.removeAll { $0 == id }
            if list.isEmpty {
                orderByConversation.removeValue(forKey: hunk.conversationID)
            } else {
                orderByConversation[hunk.conversationID] = list
            }
        }
    }

    public func clear(conversationID: UUID) {
        for id in orderByConversation[conversationID] ?? [] {
            hunks.removeValue(forKey: id)
        }
        orderByConversation.removeValue(forKey: conversationID)
    }

    /// Mark a path as agent-origin for `classify` **without** inserting a
    /// `TrackedHunk` row. Restorable content lives only in full hunks from
    /// tools via `record(_:)`. Registry post-execute must use this so we do
    /// not double-book empty-original siblings next to tool-recorded hunks.
    public func recordAgentPath(_ path: String) {
        let norm = SafeModeConfig.normalizePath(path)
        agentPaths.insert(norm.isEmpty ? path : norm)
    }

    /// Origin bookkeeping only — does **not** insert a `TrackedHunk`.
    /// Prefer `recordAgentPath` at new call sites. `summary` / `conversationID`
    /// are ignored for storage (kept for API compatibility with older tests).
    public func recordAgentEdit(path: String, summary: String, conversationID: UUID? = nil) {
        _ = summary
        _ = conversationID
        recordAgentPath(path)
    }

    /// External-origin mark only (no restorable hunk). Classification stays
    /// non-agent; external edits are not undoable via `reject`.
    public func recordExternalEdit(path: String, summary: String) {
        _ = path
        _ = summary
    }

    public func classify(path: String) -> Origin {
        let norm = SafeModeConfig.normalizePath(path)
        if agentPaths.contains(norm) || agentPaths.contains(path) {
            return .agent
        }
        return .unknown
    }

    public func recent(limit: Int = 20) -> [TrackedHunk] {
        Array(hunks.values.sorted { $0.appliedAt < $1.appliedAt }.suffix(limit))
    }

    public func clear() {
        hunks.removeAll()
        orderByConversation.removeAll()
        agentPaths.removeAll()
    }
}
