//
//  JSONValue.swift  (Harness)
//
//  A Sendable JSON value, plus `ToolArguments` (typed read accessors over a
//  validated argument object). Foundation's `[String: Any]` is not Sendable
//  and can't cross the loop actor boundary, so the harness models JSON
//  explicitly. The bool-vs-number distinction (both arrive as NSNumber from
//  JSONSerialization) is resolved via objCType so a model sending `true` for a
//  string parameter is told it sent a boolean, not the number 1.
//

import Foundation

public enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Human-readable type name, used in coercion error messages.
    public var typeName: String {
        switch self {
        case .string: return "string"
        case .int: return "integer"
        case .double: return "number"
        case .bool: return "boolean"
        case .array: return "array"
        case .object: return "object"
        case .null: return "null"
        }
    }

    /// Parse a JSON string into a `JSONValue`. Returns nil only when the text
    /// is not valid JSON at all. Accepts fragments (a bare string/number),
    /// though tool arguments are normally objects.
    public static func parse(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .object([:]) }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return from(obj)
    }

    /// Convert a Foundation JSON object graph into a `JSONValue`.
    public static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        case let s as String:
            return .string(s)
        case let n as NSNumber:
            // Booleans are NSNumber too — disambiguate first.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let t = String(cString: n.objCType)
            if t == "d" || t == "f" { return .double(n.doubleValue) }
            return .int(n.intValue)
        case let arr as [Any]:
            return .array(arr.map { from($0) })
        case let obj as [String: Any]:
            return .object(obj.mapValues { from($0) })
        default:
            return .null
        }
    }
}

/// A validated, coerced argument set a tool executes against. Read-only —
/// produced by `ArgumentCoercer` and handed to `Tool.execute`.
public struct ToolArguments: Sendable, Equatable {
    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    public var isEmpty: Bool { values.isEmpty }

    public func string(_ key: String) -> String? {
        if case .string(let s)? = values[key] { return s }
        return nil
    }

    public func int(_ key: String) -> Int? {
        if case .int(let i)? = values[key] { return i }
        return nil
    }

    public func double(_ key: String) -> Double? {
        switch values[key] {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public func bool(_ key: String) -> Bool? {
        if case .bool(let b)? = values[key] { return b }
        return nil
    }

    public func stringArray(_ key: String) -> [String]? {
        guard case .array(let a)? = values[key] else { return nil }
        return a.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }
}
