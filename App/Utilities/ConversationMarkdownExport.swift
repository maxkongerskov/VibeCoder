//
//  ConversationMarkdownExport.swift
//  Product S6 — reliable, complete Markdown export of a conversation.
//

import Foundation
import AgentCore

/// Pure markdown renderer for chat transcripts (clipboard + Save panel).
enum ConversationMarkdownExport {

    /// Render a conversation to Markdown suitable for sharing / archives.
    /// - Parameters:
    ///   - conversation: Source transcript.
    ///   - streamingContent: In-flight assistant buffer (optional).
    ///   - streamingReasoning: In-flight reasoning buffer (optional).
    ///   - exportedAt: Timestamp for the metadata footer (tests inject fixed date).
    static func render(
        conversation: Conversation,
        streamingContent: String = "",
        streamingReasoning: String = "",
        exportedAt: Date = Date()
    ) -> String {
        var out = ""
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.isEmpty ? "Conversation" : title
        out += "# \(displayTitle)\n\n"

        // Metadata (discoverable; not injected into the model).
        out += "_Exported \(isoDate(exportedAt))_"
        if let mid = conversation.modelID, !mid.isEmpty {
            out += " · model `\(mid)`"
        }
        if let root = conversation.projectRoot {
            out += " · project `\(root.path)`"
        }
        out += "\n\n---\n\n"

        var invocationsByID: [String: ToolCallInvocation] = [:]
        for msg in conversation.messages where msg.role == .assistant {
            for inv in msg.toolCalls {
                invocationsByID[inv.id] = inv
            }
        }

        for msg in conversation.messages {
            switch msg.role {
            case .system:
                continue

            case .user:
                if msg.isWireOnlySystemReminder { continue }
                let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if content.isEmpty { continue }
                out += "## User\n\n\(content)\n\n"

            case .assistant:
                out += renderAssistant(msg)

            case .tool:
                let result = msg.content
                if let id = msg.toolCallID, let inv = invocationsByID[id] {
                    out += "## Tool — `\(inv.name)`\n\n"
                    let args = inv.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !args.isEmpty {
                        out += "**Arguments:**\n\n\(fenced(args, language: "json"))\n\n"
                    }
                    out += "**Result:**\n\n\(fenced(result))\n\n"
                } else {
                    out += "## Tool\n\n\(fenced(result))\n\n"
                }
            }
        }

        let stream = streamingContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let streamReason = streamingReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stream.isEmpty || !streamReason.isEmpty {
            out += "## Assistant (streaming)\n\n"
            if !streamReason.isEmpty {
                out += "### Reasoning\n\n\(streamReason)\n\n"
            }
            if !stream.isEmpty {
                out += "\(stream)\n\n"
            }
        }

        return out
    }

    /// Safe default filename from conversation title.
    static func suggestedFilename(for conversation: Conversation) -> String {
        let safe = conversation.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safe.isEmpty ? "conversation" : safe
        return base.hasSuffix(".md") ? base : base + ".md"
    }

    // MARK: - Private

    private static func renderAssistant(_ msg: ChatMessage) -> String {
        let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoning = (msg.reasoningContent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTools = !msg.toolCalls.isEmpty
        // Skip only when there is nothing useful to show.
        if content.isEmpty && reasoning.isEmpty && !hasTools {
            return ""
        }

        var out = "## Assistant\n\n"
        if !reasoning.isEmpty {
            out += "### Reasoning\n\n\(reasoning)\n\n"
        }
        if !content.isEmpty {
            out += "\(content)\n\n"
        } else if hasTools {
            let names = msg.toolCalls.map(\.name).joined(separator: ", ")
            out += "_(tool calls: \(names))_\n\n"
        }
        if let secs = msg.workDurationSeconds, secs > 0 {
            out += "_Worked for \(secs)s_\n\n"
        }
        return out
    }

    private static func isoDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f.string(from: date)
    }

    /// Fence body with enough backticks that an embedded ``` cannot close it.
    private static func fenced(_ body: String, language: String = "") -> String {
        var tickCount = 3
        for line in body.components(separatedBy: "\n") {
            let run = line.prefix(while: { $0 == "`" }).count
            if run >= tickCount { tickCount = run + 1 }
        }
        let fence = String(repeating: "`", count: tickCount)
        return "\(fence)\(language)\n\(body)\n\(fence)"
    }
}
