//
//  TurnLifecycle.swift
//  Host-agnostic turn/session extension contributors (Grok xai-agent-lifecycle).
//

import Foundation

public protocol TurnLifecycleContributor: Sendable {
    var id: String { get }
    func turnStart(conversation: Conversation) async
    func turnEnd(conversation: Conversation, reason: String) async
}

public extension TurnLifecycleContributor {
    func turnStart(conversation: Conversation) async {}
    func turnEnd(conversation: Conversation, reason: String) async {}
}

public actor ExtensionRegistry {
    public static let shared = ExtensionRegistry()
    private var contributors: [any TurnLifecycleContributor] = []

    public func register(_ c: any TurnLifecycleContributor) {
        contributors.removeAll { $0.id == c.id }
        contributors.append(c)
    }

    public func turnStart(conversation: Conversation) async {
        for c in contributors { await c.turnStart(conversation: conversation) }
    }

    public func turnEnd(conversation: Conversation, reason: String) async {
        for c in contributors { await c.turnEnd(conversation: conversation, reason: reason) }
    }
}

/// System-reminder style blocks injected beside the system prompt.
public enum SystemReminder: Sendable {
    public static func memoryFirstTurn(_ block: String) -> String {
        """
        # System reminder — memory
        \(block)
        """
    }

    public static func interjection(_ text: String) -> String {
        """
        # System reminder — user interjection mid-turn
        The user interrupted with:
        \(text)
        Incorporate this immediately.
        """
    }

    /// BuildGuard result as a user-role system reminder (never an orphan `.tool` row).
    public static func buildGuard(succeeded: Bool, detail: String = "") -> String {
        if succeeded {
            let extra = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = extra.isEmpty
                ? """
                BuildGuard: build succeeded.

                The project compiles. If core functionality is in place, prefer finishing \
                (tell the user the app path / how to run it) over endless polish unless they \
                asked for more visual refinement. Do not re-run a full build unless you \
                change code again.
                """
                : "BuildGuard: build succeeded.\n\n\(extra)"
            return """
            # System reminder — BuildGuard
            \(body)
            """
        }
        let log = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # System reminder — BuildGuard
        BuildGuard: build failed.

        \(log)
        """
    }

    /// Post-edit file tail as a user-role system reminder (never an orphan `.tool` row).
    public static func autoVerify(path: String, tail: String) -> String {
        """
        # System reminder — AutoVerify
        [AutoVerify] Tail of \(path) after edit:
        \(tail)
        """
    }

    /// Wire-only harness injections. They stay in conversation history for
    /// the model (user-role so OpenAI tool pairing stays intact) but must
    /// never render as a chat bubble or count as a user turn.
    public static func isWireOnly(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("# System reminder") { return true }
        if trimmed.hasPrefix("[system] Background job update") { return true }
        if trimmed.hasPrefix("[Background job completed]") { return true }
        return false
    }
}
