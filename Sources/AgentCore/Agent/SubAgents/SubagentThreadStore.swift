//
//  SubagentThreadStore.swift
//
//  Live child-agent transcript for the inspector / chat thread view.
//  SubAgentRunner publishes the ephemeral Conversation after each
//  append; the UI polls by BackgroundJob task_id.
//

import Foundation

public struct SubagentThreadItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case thought
        case assistant
        case tool
    }

    public enum Status: String, Sendable, Equatable {
        case pending
        case running
        case success
        case failure
    }

    public let id: String
    public let kind: Kind
    public let status: Status
    public let toolName: String?
    public let arguments: String
    public let output: String
    public let text: String

    public init(
        id: String,
        kind: Kind,
        status: Status = .success,
        toolName: String? = nil,
        arguments: String = "",
        output: String = "",
        text: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.toolName = toolName
        self.arguments = arguments
        self.output = output
        self.text = text
    }
}

/// Flatten a child Conversation into ZCode-style thread steps.
public enum SubagentThreadBuilder {
    public static func items(from messages: [ChatMessage]) -> [SubagentThreadItem] {
        var items: [SubagentThreadItem] = []
        var sawPrompt = false

        for msg in messages {
            switch msg.role {
            case .system:
                continue
            case .user:
                if !sawPrompt {
                    sawPrompt = true
                    continue
                }
                if msg.isWireOnlySystemReminder { continue }
                let text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if text.hasPrefix("[system]") { continue }
                if text.hasPrefix("[Background job") { continue }
                items.append(SubagentThreadItem(
                    id: "note-\(msg.id.uuidString)",
                    kind: .assistant,
                    text: text
                ))
            case .assistant:
                if let reasoning = msg.reasoningContent?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !reasoning.isEmpty {
                    items.append(SubagentThreadItem(
                        id: "thought-\(msg.id.uuidString)",
                        kind: .thought,
                        text: reasoning
                    ))
                }
                let prose = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prose.isEmpty {
                    items.append(SubagentThreadItem(
                        id: "asst-\(msg.id.uuidString)",
                        kind: .assistant,
                        text: prose
                    ))
                }
                for inv in msg.toolCalls {
                    items.append(SubagentThreadItem(
                        id: toolItemID(inv.id),
                        kind: .tool,
                        status: .running,
                        toolName: inv.name,
                        arguments: inv.arguments
                    ))
                }
            case .tool:
                guard let callID = msg.toolCallID else { continue }
                let failed = looksFailed(msg.content)
                let updated = SubagentThreadItem(
                    id: toolItemID(callID),
                    kind: .tool,
                    status: failed ? .failure : .success,
                    toolName: items.first(where: { $0.id == toolItemID(callID) })?.toolName,
                    arguments: items.first(where: { $0.id == toolItemID(callID) })?.arguments ?? "",
                    output: msg.content
                )
                if let idx = items.firstIndex(where: { $0.id == updated.id }) {
                    let existing = items[idx]
                    items[idx] = SubagentThreadItem(
                        id: updated.id,
                        kind: .tool,
                        status: updated.status,
                        toolName: updated.toolName ?? existing.toolName,
                        arguments: updated.arguments.isEmpty ? existing.arguments : updated.arguments,
                        output: updated.output
                    )
                } else {
                    items.append(updated)
                }
            }
        }
        return items
    }

    /// Snapshot used while the child model is still streaming this turn.
    /// Does not mutate the runner's committed transcript.
    public static func draftTranscript(
        committed: [ChatMessage],
        reasoning: String,
        content: String,
        toolCalls: [ToolCallInvocation]
    ) -> [ChatMessage] {
        let thought = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        let prose = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thought.isEmpty || !prose.isEmpty || !toolCalls.isEmpty else {
            return committed
        }
        var messages = committed
        messages.append(ChatMessage(
            role: .assistant,
            content: prose,
            reasoningContent: thought.isEmpty ? nil : thought,
            toolCalls: toolCalls
        ))
        return messages
    }

    /// Job-heartbeat lines are not a child thread.
    public static func isHeartbeatOutput(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[iter ") { return true }
        if trimmed.hasPrefix("[running]") { return true }
        return false
    }

    public static func toolItemID(_ toolCallID: String) -> String {
        "tool-\(toolCallID)"
    }

    public static func looksFailed(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("tool error") { return true }
        if lower.hasPrefix("skipped:") { return true }
        if lower.hasPrefix("cancelled by user") { return true }
        if lower.contains("is not available to this sub-agent") { return true }
        return false
    }
}

public actor SubagentThreadStore {
    public static let shared = SubagentThreadStore()

    private var messagesByJob: [UUID: [ChatMessage]] = [:]

    public func publish(jobID: UUID, messages: [ChatMessage]) {
        messagesByJob[jobID] = messages
    }

    public func messages(for jobID: UUID) -> [ChatMessage] {
        messagesByJob[jobID] ?? []
    }

    public func items(for jobID: UUID) -> [SubagentThreadItem] {
        SubagentThreadBuilder.items(from: messagesByJob[jobID] ?? [])
    }

    public func remove(jobID: UUID) {
        messagesByJob[jobID] = nil
    }

#if DEBUG
    public func removeAllForTests() {
        messagesByJob.removeAll()
    }
#endif
}
