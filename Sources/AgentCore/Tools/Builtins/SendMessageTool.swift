//
//  SendMessageTool.swift
//
//  send_message — parent → child inbox (ZCode SendMessage).
//  Wave-2 SubAgentRunner drains AgentMailbox; this tool only writes.
//

import Foundation

public struct SendMessageTool: Tool {
    public static let name = "send_message"
    public static let category: ToolCategory = .agent
    /// Talks to other agents (steer / resume), not a read-only inspect.
    public static let permission: ToolPermission = .executes
    public static let availability: ToolAvailability = .core

    public static let maxToLength = 200
    public static let maxSummaryLength = 200
    public static let maxMessageLength = 20_000

    public static let schema = ToolSchema(
        name: name,
        description: """
        Send a message to another agent.

        Your plain text output is NOT visible to other agents — to communicate, you MUST call this tool. \
        Messages from agents are delivered automatically; you don't check an inbox. \
        Refer to local agents by the agentId returned in the task spawn result (format agent_<uuid>). \
        To resume a completed agent, use its agentId; it resumes in the background and you'll be notified when it finishes.
        """,
        parameters: .init(
            properties: [
                "to": .init(
                    type: "string",
                    description: "Recipient: local agent ID returned by task (format agent_<uuid>)."
                ),
                "summary": .init(
                    type: "string",
                    description: "A 5-10 word summary shown as a preview in the UI."
                ),
                "message": .init(
                    type: "string",
                    description: "Plain text message content."
                ),
            ],
            required: ["to", "summary", "message"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let toRaw = arguments.stringOptional("to")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = arguments.stringOptional("summary")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = arguments.stringOptional("message")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if toRaw.isEmpty {
            return ToolResult(content: "send_message: 'to' (agent id) is required.", isError: true)
        }
        if toRaw.count > Self.maxToLength {
            return ToolResult(
                content: "send_message: 'to' exceeds \(Self.maxToLength) characters.",
                isError: true)
        }
        if summary.isEmpty {
            return ToolResult(content: "send_message: 'summary' is required (5-10 words).", isError: true)
        }
        if summary.count > Self.maxSummaryLength {
            return ToolResult(
                content: "send_message: 'summary' exceeds \(Self.maxSummaryLength) characters.",
                isError: true)
        }
        if message.isEmpty {
            return ToolResult(content: "send_message: 'message' is required.", isError: true)
        }
        if message.count > Self.maxMessageLength {
            return ToolResult(
                content: "send_message: 'message' exceeds \(Self.maxMessageLength) characters.",
                isError: true)
        }

        let from = context.conversationID.uuidString.lowercased()
        let sent = await AgentMailbox.shared.send(
            to: toRaw, summary: summary, message: message, from: from)
        let agentId = sent.message.to
        let delivery = sent.resumeRequested ? "resumed_background" : "queued"
        var extras: [String: String] = [:]
        if sent.resumeRequested {
            extras[AgentMailbox.extrasResumeKey] = "true"
        }
        var lines = [
            "Message queued for \(agentId).",
            "delivery: \(delivery)",
            "summary: \(summary)",
        ]
        if sent.resumeRequested {
            lines.append("Completed agent marked for background resume.")
        }
        return ToolResult(content: lines.joined(separator: "\n"), isError: false, extras: extras)
    }
}
