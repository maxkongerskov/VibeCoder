//
//  ToolDefinition.swift
//
//  Wire-format tool spec for OpenAI-compatible chat completions. AgentCore
//  already has `ToolSchema` (the in-process tool's parameter description)
//  and the `Tool` protocol — this file adds the OUTBOUND JSON envelope
//  shape that gets serialized into a request body:
//
//      { "type": "function",
//        "function": { "name": "...", "description": "...",
//                      "parameters": { "type": "object", "properties": {...}, "required": [...] } } }
//
//  The DEV PLAN's `ToolDefinition` mixed wire-format with conversation
//  resolution logic (AppSettings / Conversation / ModelPreset wiring). The
//  conversation-resolution side belongs in a higher layer that has access
//  to those types; this port ships ONLY the pure encoder surface plus a
//  small adapter that builds a `ToolDefinition` from an in-process
//  `ToolSchema`. Pure types, Sendable, no UI imports.
//

import Foundation

/// JSON wire-format tool definition for OpenAI-shaped chat completion
/// endpoints. Encoded with snake_case-ish keys: `enum` survives in
/// `PropertyDef` via a CodingKey remap.
public struct ToolDefinition: Sendable, Encodable, Equatable {
    public let type: String
    public let function: FunctionDef

    public init(function: FunctionDef) {
        self.type = "function"
        self.function = function
    }

    public struct FunctionDef: Sendable, Encodable, Equatable {
        public let name: String
        public let description: String
        public let parameters: ParametersDef

        public init(name: String, description: String, parameters: ParametersDef) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    public struct ParametersDef: Sendable, Encodable, Equatable {
        public let type: String
        public let properties: [String: PropertyDef]
        public let required: [String]

        public init(properties: [String: PropertyDef], required: [String] = []) {
            self.type = "object"
            self.properties = properties
            self.required = required
        }
    }

    public struct PropertyDef: Sendable, Encodable, Equatable {
        public let type: String
        public let description: String
        public var enumValues: [String]?

        public init(type: String, description: String, enumValues: [String]? = nil) {
            self.type = type
            self.description = description
            self.enumValues = enumValues
        }

        enum CodingKeys: String, CodingKey {
            case type
            case description
            case enumValues = "enum"
        }
    }
}

public extension ToolDefinition {
    /// Lift an in-process `ToolSchema` into the wire-format envelope.
    /// `ToolSchema` is the dispatch-time shape (used by `Tool`); this
    /// extension serializes it into the OpenAI-compatible request body.
    init(schema: ToolSchema) {
        let props: [String: PropertyDef] = schema.parameters.properties.reduce(into: [:]) { acc, kv in
            acc[kv.key] = PropertyDef(
                type: kv.value.type,
                description: kv.value.description,
                enumValues: kv.value.enum
            )
        }
        self.init(function: FunctionDef(
            name: schema.name,
            description: schema.description,
            parameters: ParametersDef(properties: props, required: schema.parameters.required)
        ))
    }
}
