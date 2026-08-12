//
//  Message.swift  (Harness)
//
//  The conversation value types the whole harness speaks in. Clean-slate
//  versions of AgentCore's ChatMessage / ToolCallInvocation, with two
//  deliberate naming changes for the rewrite:
//
//    • `Role` is a top-level enum, not nested in ChatMessage — every layer
//      refers to it directly.
//    • The normalized tool call is `ToolCall` (was `ToolCallInvocation`).
//      It is what the loop sees AFTER the provider boundary has flattened
//      native `tool_calls`, Hermes/XML/bare-JSON inline formats, and
//      streaming-fragment reassembly into one uniform shape.
//
//  All value types, all Sendable — they cross the actor boundary between the
//  loop engine and the UI freely.
//

import Foundation

/// Who authored a message. Mirrors the OpenAI chat roles.
public enum Role: String, Codable, Sendable {
    case system, user, assistant, tool
}

/// One normalized tool call. `arguments` is the raw JSON string exactly as
/// the model emitted it — validation and coercion happen later, at the tool
/// dispatch seam, so the provider layer never has to know a tool's schema.
public struct ToolCall: Codable, Identifiable, Sendable, Equatable {
    /// Stable id, used to pair an assistant tool call with its `.tool` result
    /// message. Native backends supply it; inline-format calls get a
    /// synthesised `inline_…` id.
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One message in a turn. Assistant messages may carry `toolCalls`; a `.tool`
/// message carries the `toolCallID` of the call it satisfies. The harness
/// maintains the invariant that every assistant tool call is eventually
/// followed by exactly one `.tool` message with the matching id.
public struct ChatMessage: Codable, Identifiable, Sendable {
    public let id: UUID
    public let role: Role
    public var content: String
    public var toolCalls: [ToolCall]
    public var toolCallID: String?
    public var timestamp: Date

    public init(id: UUID = UUID(),
                role: Role,
                content: String,
                toolCalls: [ToolCall] = [],
                toolCallID: String? = nil,
                timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.timestamp = timestamp
    }
}
