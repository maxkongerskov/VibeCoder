//
//  SkillToolGate.swift
//
//  In-session tool allowlist after a successful `load_skill`.
//  Product rule: last successful load wins; not durable across relaunch.
//  Keyed by `conversationID` (same identity as `SessionReadTracker`).
//  In-memory only — no Codable, no seed/hydrate, no Conversation JSON field.
//

import Foundation

/// Restricts subsequent tool executions after a skill with a non-empty
/// `allowed-tools` list is loaded. Empty allowlist = no extra restriction.
///
/// Persistence (`ConversationStore.delete`) must call `clear(conversationID:)`.
/// This type cannot own that call. A process relaunch or `clear` leaves the
/// conversation unrestricted until the next successful `load_skill`.
public actor SkillToolGate {
    public static let shared = SkillToolGate()

    /// Always permitted while a skill allowlist is active so another skill
    /// can replace the gate.
    public static let loadSkillName = "load_skill"

    /// conversationID → allowlist. Missing key = unrestricted.
    /// Stored set always includes `loadSkillName`.
    private var allowlistByConversation: [UUID: Set<String>] = [:]

    public init() {}

    /// Replace the gate for this conversation (last successful `load_skill` wins).
    /// Empty / whitespace-only `allowedTools` clears the restriction.
    /// Always unions `loadSkillName` so a later skill can replace the gate.
    public func record(allowedTools: [String], conversationID: UUID) {
        guard let names = SkillDiscovery.sessionToolAllowlist(from: allowedTools) else {
            allowlistByConversation.removeValue(forKey: conversationID)
            return
        }
        var allowed = names
        allowed.insert(Self.loadSkillName)
        allowlistByConversation[conversationID] = allowed
    }

    /// Allowlist in force for this conversation, if any (includes `load_skill`).
    public func allowlist(for conversationID: UUID) -> Set<String>? {
        allowlistByConversation[conversationID]
    }

    /// Error result when the tool must not run; `nil` when unrestricted or allowed.
    /// `disabledToolNames` always wins over a skill allowlist.
    public func denialResult(
        toolName: String,
        conversationID: UUID,
        disabledToolNames: Set<String>
    ) -> ToolResult? {
        guard let allowed = allowlistByConversation[conversationID] else {
            return nil
        }
        if disabledToolNames.contains(toolName) {
            return ToolResult(
                content: "Error: tool `\(toolName)` is disabled in Settings → Tools and cannot run even if a loaded skill lists it.",
                isError: true
            )
        }
        if allowed.contains(toolName) {
            return nil
        }
        let listed = allowed.sorted().joined(separator: ", ")
        return ToolResult(
            content: "Error: tool `\(toolName)` is not permitted by the loaded skill allowlist (allowed: \(listed)).",
            isError: true
        )
    }

    /// Drop the in-session gate for this conversation.
    /// Call from conversation delete / `/clear` (Persistence / App own those
    /// surfaces). Does not write or read conversation JSON.
    public func clear(conversationID: UUID) {
        allowlistByConversation.removeValue(forKey: conversationID)
    }
}
