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
        var set = byConversation[conversationID] ?? []
        set.insert(norm)
        byConversation[conversationID] = set
    }

    public func paths(for conversationID: UUID) -> Set<String> {
        byConversation[conversationID] ?? []
    }

    public func hasRead(path: String, conversationID: UUID) -> Bool {
        let norm = SafeModeConfig.normalizePath(path)
        return byConversation[conversationID]?.contains(norm) == true
    }

    /// True when the path was read this conversation or seeded via `sessionReadPaths` (tests).
    public func hasSessionRead(
        path: String,
        conversationID: UUID,
        sessionReadPaths: Set<String>
    ) -> Bool {
        let norm = SafeModeConfig.normalizePath(path)
        return sessionReadPaths.contains(norm) || (byConversation[conversationID]?.contains(norm) == true)
    }

    public func clear(conversationID: UUID) {
        byConversation.removeValue(forKey: conversationID)
    }
}
