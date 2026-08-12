//
//  ArtifactRebuild.swift
//
//  Reconstruct artifact cards from persisted conversation messages + live UI state.

import Foundation
import AgentCore

enum ArtifactRebuild {

    /// Maximum cards retained in the rail per conversation.
    static let maxCards = 50

    /// Walk assistant messages and rebuild artifact cards. Newest first.
    static func rebuild(
        from messages: [ChatMessage],
        toolStates: [UUID: [ToolCallUIState]] = [:]
    ) -> [ArtifactCard] {
        var cards: [ArtifactCard] = []

        for msg in messages where msg.role == .assistant {
            let states = toolStates[msg.id] ?? synthesizeStates(for: msg, in: messages)
            for state in states {
                guard ArtifactLabel.shouldShowInRail(toolName: state.toolName) else { continue }
                if let card = card(from: state, createdAt: msg.timestamp) {
                    cards.append(card)
                }
            }
        }

        let sorted = cards.sorted { $0.createdAt > $1.createdAt }
        return Array(sorted.prefix(maxCards))
    }

    static func card(from state: ToolCallUIState, createdAt: Date = Date()) -> ArtifactCard? {
        guard ArtifactLabel.shouldShowInRail(toolName: state.toolName) else { return nil }
        let desc = ArtifactLabel.make(
            toolName: state.toolName,
            argsJSON: state.input,
            output: state.output
        )
        let body = state.output.isEmpty ? state.input : state.output
        return ArtifactCard(
            id: state.id,
            toolName: state.toolName,
            kind: desc.kind,
            title: desc.title,
            subtitle: desc.subtitle,
            body: body,
            input: state.input,
            status: state.status,
            createdAt: createdAt
        )
    }

    /// Rebuild UI states from persisted tool-call invocations + matching tool results.
    private static func synthesizeStates(
        for assistant: ChatMessage,
        in messages: [ChatMessage]
    ) -> [ToolCallUIState] {
        guard !assistant.toolCalls.isEmpty else { return [] }
        var outputByID: [String: String] = [:]
        for msg in messages where msg.role == .tool {
            if let id = msg.toolCallID { outputByID[id] = msg.content }
        }
        return assistant.toolCalls.map { inv in
            let output = outputByID[inv.id] ?? ""
            let status: ToolCallStatus = output.isEmpty ? .pending : .success
            return ToolCallUIState(
                id: inv.id,
                toolName: inv.name,
                status: status,
                input: inv.arguments,
                output: output
            )
        }
    }
}