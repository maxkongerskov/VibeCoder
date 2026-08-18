//
//  SessionReadTracker.swift
//
//  Tracks absolute file paths read during a conversation so edit tools
//  can enforce read-before-edit (except create-new).
//

import Foundation

public actor SessionReadTracker {
    public static let shared = SessionReadTracker()

    private var byConversation: [UUID: Set<String>] = [:]

    public func recordRead(path: String, conversationID: UUID) {
        let norm = SafeModeConfig.normalizePath(path)
        guard !norm.isEmpty else { return }
        var set = byConversation[conversationID] ?? []
        set.insert(norm)
        byConversation[conversationID] = set
    }

    /// Union persisted / decoded paths into the in-memory set (conversation resume).
    /// Empty `paths` is a no-op so a legacy JSON load cannot wipe live reads.
    public func seed(paths: some Sequence<String>, conversationID: UUID) {
        var set = byConversation[conversationID] ?? []
        for path in paths {
            let norm = SafeModeConfig.normalizePath(path)
            if !norm.isEmpty { set.insert(norm) }
        }
        if !set.isEmpty {
            byConversation[conversationID] = set
        }
    }

    public func paths(for conversationID: UUID) -> Set<String> {
        byConversation[conversationID] ?? []
    }

    public func hasRead(path: String, conversationID: UUID) -> Bool {
        let norm = SafeModeConfig.normalizePath(path)
        return byConversation[conversationID]?.contains(norm) == true
    }

    /// True when the path was read this conversation or listed in
    /// `sessionReadPaths`. Iterates the incoming set — do not wrap a
    /// Codable-decoded Set in another Set (SIGSEGV).
    public func hasSessionRead(
        path: String,
        conversationID: UUID,
        sessionReadPaths: Set<String>
    ) -> Bool {
        let norm = SafeModeConfig.normalizePath(path)
        if byConversation[conversationID]?.contains(norm) == true {
            return true
        }
        for raw in sessionReadPaths {
            if SafeModeConfig.normalizePath(raw) == norm {
                return true
            }
        }
        return false
    }

    public func clear(conversationID: UUID) {
        byConversation.removeValue(forKey: conversationID)
    }
}
