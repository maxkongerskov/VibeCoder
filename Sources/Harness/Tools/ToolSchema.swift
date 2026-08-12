//
//  ToolSchema.swift  (Harness)
//
//  The in-process description of a tool's parameters. Two jobs:
//    • drives argument validation/coercion before dispatch (ArgumentCoercer),
//    • renders to the OpenAI function-schema wire shape (`ToolSpec`) the
//      provider sends to the model.
//  Modelling the schema as a value type (rather than a JSON string) means the
//  coercer can reason about each parameter's expected type without re-parsing
//  a schema string per call.
//

import Foundation

/// The JSON Schema scalar/compound types a tool parameter can declare.
public enum JSONType: String, Sendable, Codable, Equatable {
    case string, integer, number, boolean, array, object
}

public struct ToolParameter: Sendable, Equatable {
    public let name: String
    public let type: JSONType
    public let required: Bool
    public let description: String
    /// Optional closed set of allowed string values.
    public let enumValues: [String]?
    /// For `array` parameters, the element type (enables scalar→[scalar]
    /// coercion to keep the right element shape).
    public let arrayElementType: JSONType?

    public init(name: String,
                type: JSONType,
                required: Bool = false,
                description: String = "",
                enumValues: [String]? = nil,
                arrayElementType: JSONType? = nil) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
        self.enumValues = enumValues
        self.arrayElementType = arrayElementType
    }
}

public struct ToolSchema: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: [ToolParameter]

    public init(name: String, description: String, parameters: [ToolParameter] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public func parameter(named name: String) -> ToolParameter? {
        parameters.first { $0.name == name }
    }

    public var requiredNames: [String] {
        parameters.filter(\.required).map(\.name)
    }

    /// Render to the wire `ToolSpec` (OpenAI function schema). Deterministic
    /// (sorted keys) so identical schemas serialize byte-for-byte — which
    /// keeps prompt-prefix caching stable across iterations.
    public func toSpec() -> ToolSpec {
        var properties: [String: Any] = [:]
        for p in parameters {
            var prop: [String: Any] = ["type": p.type.rawValue]
            if !p.description.isEmpty { prop["description"] = p.description }
            if let e = p.enumValues { prop["enum"] = e }
            if p.type == .array {
                prop["items"] = ["type": (p.arrayElementType ?? .string).rawValue]
            }
            properties[p.name] = prop
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": requiredNames,
        ]
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            json = s
        } else {
            json = #"{"type":"object","properties":{},"required":[]}"#
        }
        return ToolSpec(name: name, description: description, parametersJSON: json)
    }
}
