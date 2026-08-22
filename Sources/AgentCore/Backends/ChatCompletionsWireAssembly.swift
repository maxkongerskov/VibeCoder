//
//  ChatCompletionsWireAssembly.swift
//
//  Shared OpenAI-compat message list for HTTP backends (Unsloth / llama.cpp
//  included). llama-server 400s when the last two roles are both `assistant`
//  ("Cannot have 2 or more assistant messages at the end of the list").
//

import Foundation

extension ChatCompletionRequestBody {

    /// Shipped chat-completions `messages` array: `WireMessage.from` plus
    /// tool `name` and a llama.cpp-safe tail (at most one trailing assistant).
    public static func assembledWireMessages(
        from messages: [ChatMessage],
        emptyTextAsEmptyString: Bool = false
    ) -> [WireMessage] {
        var nameByCallID: [String: String] = [:]
        for msg in messages where msg.role == .assistant {
            for inv in msg.toolCalls where !inv.id.isEmpty && !inv.name.isEmpty {
                nameByCallID[inv.id] = inv.name
            }
        }
        let raw: [WireMessage] = messages.map { msg in
            let base = WireMessage.from(msg, emptyTextAsEmptyString: emptyTextAsEmptyString)
            guard msg.role == .tool else { return base }
            let toolName = msg.toolCallID.flatMap { nameByCallID[$0] }
            return WireMessage(
                role: base.role,
                content: base.content,
                toolCalls: base.toolCalls,
                toolCallId: base.toolCallId,
                name: toolName
            )
        }
        return collapsingTrailingAssistants(raw)
    }

    /// llama.cpp: at most one `assistant` at the end of `messages`.
    /// Consecutive trailing assistants are merged (content + tool_calls).
    public static func collapsingTrailingAssistants(
        _ messages: [WireMessage]
    ) -> [WireMessage] {
        var wire = messages
        while wire.count >= 2,
              wire[wire.count - 1].role == "assistant",
              wire[wire.count - 2].role == "assistant" {
            let earlier = wire[wire.count - 2]
            let later = wire[wire.count - 1]
            wire.removeLast()
            wire[wire.count - 1] = mergeAssistant(earlier, later)
        }
        return wire
    }

    private static func mergeAssistant(_ a: WireMessage, _ b: WireMessage) -> WireMessage {
        let texts = [a.textValue, b.textValue].compactMap { $0 }.filter { !$0.isEmpty }
        let joined = texts.joined(separator: "\n")
        let content: WireContent = joined.isEmpty ? .text(nil) : .text(joined)
        return WireMessage(
            role: "assistant",
            content: content,
            toolCalls: b.toolCalls ?? a.toolCalls,
            toolCallId: b.toolCallId ?? a.toolCallId,
            name: b.name ?? a.name
        )
    }
}
