//
//  SessionGrantStore.swift
//
//  In-memory, conversation-scoped grants for "Allow for this session".
//  Process lifetime only — no disk. Dangerous shell is never stored
//  here; the host sheet / coordinator must refuse Session for those.
//

import Foundation

/// One session-scoped allow. Prefix grants apply to every shell segment
/// whose first token matches (chip: `git *`).
public struct SessionGrant: Sendable, Equatable, Identifiable {
    public enum Scope: Sendable, Equatable {
        /// First-token prefix, compared case-insensitively (`git` → `git *`).
        case shellPrefix(String)
        /// Exact tool name, optional subagent origin tag.
        case tool(name: String, originTag: String?)
    }

    public let id: UUID
    public let conversationID: UUID
    public let scope: Scope

    public init(id: UUID = UUID(), conversationID: UUID, scope: Scope) {
        self.id = id
        self.conversationID = conversationID
        switch scope {
        case .shellPrefix(let raw):
            self.scope = .shellPrefix(SessionGrantStore.normalizedPrefix(raw))
        case .tool(let name, let origin):
            let tag = origin?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.scope = .tool(
                name: name,
                originTag: (tag?.isEmpty == false) ? tag : nil
            )
        }
    }

    /// Mono chip label shown on the approval sheet (`git *` / tool name).
    public var chipLabel: String {
        switch scope {
        case .shellPrefix(let prefix):
            return "\(prefix) *"
        case .tool(let name, _):
            return name
        }
    }
}

/// Process-lifetime session grants, keyed by conversation id.
public final class SessionGrantStore: @unchecked Sendable {

    /// Used when the host has not bound an active conversation yet.
    public static let unscopedConversationID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
    )

    private let lock = NSLock()
    private var grantsByConversation: [UUID: [SessionGrant]] = [:]
    private var boundConversationID: UUID?

    public init() {}

    /// Bind the 2-arg `matches(toolName:command:)` form to `id`.
    public func bindConversation(_ id: UUID) {
        lock.lock()
        boundConversationID = id
        lock.unlock()
    }

    public func add(grant: SessionGrant) {
        lock.lock()
        defer { lock.unlock() }
        var list = grantsByConversation[grant.conversationID] ?? []
        if !list.contains(where: { $0.scope == grant.scope }) {
            list.append(grant)
        }
        grantsByConversation[grant.conversationID] = list
    }

    /// `nil` = no session grant, `true` = allow. Session never stores deny.
    public func matches(toolName: String, command: String?) -> Bool? {
        let id: UUID?
        lock.lock()
        id = boundConversationID
        lock.unlock()
        guard let id else { return nil }
        return matches(conversationID: id, toolName: toolName, command: command)
    }

    public func matches(
        conversationID: UUID,
        toolName: String,
        command: String?,
        originTag: String? = nil
    ) -> Bool? {
        let list = grants(for: conversationID)
        guard !list.isEmpty else { return nil }

        if Self.isShellTool(toolName), let command, !command.isEmpty {
            let tokens = Self.segmentPrefixes(of: command)
            guard !tokens.isEmpty else { return nil }
            let covered = tokens.allSatisfy { token in
                list.contains { grant in
                    if case .shellPrefix(let prefix) = grant.scope {
                        return prefix == token
                    }
                    return false
                }
            }
            return covered ? true : nil
        }

        let origin = originTag?.trimmingCharacters(in: .whitespacesAndNewlines)
        let originNorm = (origin?.isEmpty == false) ? origin : nil
        let hit = list.contains { grant in
            guard case .tool(let name, let tag) = grant.scope else { return false }
            guard PermissionRuleMatch.toolNamesMatch(name, toolName) else { return false }
            if let tag { return originNorm == tag }
            return true
        }
        return hit ? true : nil
    }

    public func clearConversation(_ id: UUID) {
        lock.lock()
        grantsByConversation.removeValue(forKey: id)
        lock.unlock()
    }

    public func grants(for conversationID: UUID) -> [SessionGrant] {
        lock.lock()
        defer { lock.unlock() }
        return grantsByConversation[conversationID] ?? []
    }

    /// Chip for the incoming ask (`git *` or the tool name).
    public static func scopeChipLabel(toolName: String, command: String?) -> String {
        grant(
            conversationID: unscopedConversationID,
            toolName: toolName,
            command: command
        ).chipLabel
    }

    public static func grant(
        conversationID: UUID,
        toolName: String,
        command: String?,
        originTag: String? = nil
    ) -> SessionGrant {
        if isShellTool(toolName),
           let command,
           let prefix = firstToken(of: command) {
            return SessionGrant(
                conversationID: conversationID,
                scope: .shellPrefix(prefix)
            )
        }
        return SessionGrant(
            conversationID: conversationID,
            scope: .tool(name: toolName, originTag: originTag)
        )
    }

    public static func isShellTool(_ toolName: String) -> Bool {
        toolName == "run_shell" || toolName == "run_shell_command"
    }

    static func normalizedPrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return executableBasename(trimmed).lowercased()
    }

    static func firstToken(of command: String) -> String? {
        let segs = SafeBash.segments(of: command)
        guard let first = segs.first else { return nil }
        return firstToken(ofSegment: first)
    }

    static func segmentPrefixes(of command: String) -> [String] {
        let segs = SafeBash.segments(of: command)
        let subjects = segs.isEmpty ? [command] : segs
        return subjects.compactMap { firstToken(ofSegment: $0) }
    }

    private static func firstToken(ofSegment segment: String) -> String? {
        let tokens = SafeBash.peelWrappers(SafeBash.tokenize(segment))
        guard let raw = tokens.first else { return nil }
        let norm = normalizedPrefix(raw)
        return norm.isEmpty ? nil : norm
    }

    private static func executableBasename(_ token: String) -> String {
        let unified = token.replacingOccurrences(of: "\\", with: "/")
        guard let slash = unified.lastIndex(of: "/") else { return token }
        let base = String(unified[unified.index(after: slash)...])
        return base.isEmpty ? token : base
    }
}
