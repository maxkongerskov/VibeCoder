//
//  Turn.swift
//
//  Groups a conversation's flat message list into per-user-message turns.
//  Each Turn = the user message that started it + every assistant/tool
//  message produced in response, split into "process" (intermediate work)
//  and "answer" (the final assistant-with-content-and-no-tool-calls reply).
//
//  Adapted for the Claude Edition `ChatMessage` shape, where `toolCalls`
//  is a non-optional `[ToolCallInvocation]`.
//

import Foundation

public struct Turn: Identifiable, Sendable {
    public let user: ChatMessage
    public let process: [ChatMessage]
    public let answer: ChatMessage?

    public var id: UUID { user.id }

    public init(user: ChatMessage, process: [ChatMessage], answer: ChatMessage?) {
        self.user = user
        self.process = process
        self.answer = answer
    }

    public static func group(_ messages: [ChatMessage]) -> [Turn] {
        var turns: [Turn] = []
        var currentUser: ChatMessage?
        var currentBuffer: [ChatMessage] = []

        func flush() {
            guard let u = currentUser else { return }
            let split = splitAnswer(currentBuffer)
            turns.append(Turn(user: u, process: split.process, answer: split.answer))
            currentUser = nil
            currentBuffer = []
        }

        for msg in messages where msg.role != .system {
            if msg.role == .user {
                // Harness reminders are user-role on the wire only.
                if msg.isWireOnlySystemReminder { continue }
                flush()
                currentUser = msg
            } else {
                if currentUser != nil { currentBuffer.append(msg) }
            }
        }
        flush()
        return turns
    }

    /// Final answer = last assistant message with non-empty content and no
    /// tool calls. Claude Edition's `ChatMessage.toolCalls` is non-optional,
    /// so we check `isEmpty` directly (DEV PLAN used `?.isEmpty ?? true`).
    private static func splitAnswer(_ buffer: [ChatMessage]) -> (process: [ChatMessage], answer: ChatMessage?) {
        guard let answerIdx = buffer.lastIndex(where: {
            $0.role == .assistant && !$0.content.isEmpty && $0.toolCalls.isEmpty
        }) else {
            return (buffer, nil)
        }
        let process = Array(buffer[..<answerIdx])
        return (process, buffer[answerIdx])
    }
}
