//
//  ArgumentCoercer.swift  (Harness)
//
//  The dispatch-seam gate that makes weak local models usable. They get
//  argument types wrong constantly — "3" for an integer, true for a string,
//  a bare value where an array is expected, a whole missing required key.
//  Two responses, by cost:
//
//    • SILENTLY COERCE the cheap, unambiguous cases ("3"→3, "true"→true,
//      scalar→[scalar]). Round-tripping these through the model wastes a
//      turn for no benefit.
//    • REJECT with a STRUCTURED, machine-actionable correction for the rest
//      ("missing required key `path` (string)"; "`count` must be integer, you
//      sent string"). A local model recovers from this far better than from a
//      generic "invalid arguments", and the correction closes the open tool
//      call (as a `.tool` result) WITHOUT dispatching the tool.
//
//  Pure value-type logic — no I/O, no tool knowledge beyond the schema — so it
//  is exhaustively unit-testable against malformed-argument fixtures.
//

import Foundation

/// One mistyped argument the model must fix.
public struct ArgTypeError: Sendable, Equatable {
    public let key: String
    public let expected: String
    public let got: String
    public init(key: String, expected: String, got: String) {
        self.key = key; self.expected = expected; self.got = got
    }
}

/// A structured, model-actionable explanation of why arguments were rejected.
public struct ToolCorrection: Sendable, Equatable {
    public let tool: String
    /// Non-nil when the arguments weren't valid JSON at all.
    public let parseError: String?
    public let missing: [String]
    public let typeErrors: [ArgTypeError]
    /// Keys not in the schema. Informational — unknown keys alone never cause
    /// a rejection (they're dropped with a note); listed here for context.
    public let unknownKeys: [String]

    public init(tool: String, parseError: String? = nil, missing: [String] = [],
                typeErrors: [ArgTypeError] = [], unknownKeys: [String] = []) {
        self.tool = tool
        self.parseError = parseError
        self.missing = missing
        self.typeErrors = typeErrors
        self.unknownKeys = unknownKeys
    }

    /// The correction rendered as a tool result (isError) the loop appends to
    /// close the call. Phrased as direct, literal instructions — local models
    /// follow "do X" far better than prose explanations.
    public func asToolResult() -> ToolResult {
        ToolResult(content: render(), isError: true)
    }

    func render() -> String {
        var lines = ["Your call to `\(tool)` had invalid arguments — fix them and call again."]
        if let parseError { lines.append("• \(parseError)") }
        for m in missing { lines.append("• missing required argument `\(m)`") }
        for t in typeErrors {
            lines.append("• `\(t.key)` must be \(t.expected) — you sent \(t.got)")
        }
        if !unknownKeys.isEmpty {
            lines.append("• these arguments are not used by this tool and were ignored: "
                         + unknownKeys.map { "`\($0)`" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

public enum ArgCoercion: Sendable {
    /// Arguments matched the schema exactly.
    case ok(ToolArguments)
    /// Arguments needed cheap coercions but are now valid; `notes` describes
    /// what was adjusted (useful for telemetry/UI, not sent to the model).
    case correctable(ToolArguments, notes: [String])
    /// Arguments can't be salvaged; the correction goes back to the model.
    case rejected(ToolCorrection)
}

public enum ArgumentCoercer {

    public static func coerce(rawJSON: String, against schema: ToolSchema) -> ArgCoercion {
        guard let parsed = JSONValue.parse(rawJSON), case .object(let obj) = parsed else {
            // Not valid JSON, or a non-object (a bare array/string/number).
            return .rejected(ToolCorrection(
                tool: schema.name,
                parseError: "arguments must be a JSON object like {\"key\": value}",
                missing: schema.requiredNames))
        }

        var out: [String: JSONValue] = [:]
        var notes: [String] = []
        var missing: [String] = []
        var typeErrors: [ArgTypeError] = []

        let known = Set(schema.parameters.map(\.name))
        let unknownKeys = obj.keys.filter { !known.contains($0) }.sorted()
        for k in unknownKeys { notes.append("dropped unexpected argument '\(k)'") }

        for p in schema.parameters {
            guard let v = obj[p.name] else {
                if p.required { missing.append(p.name) }
                continue
            }
            switch coerce(v, to: p) {
            case .exact(let cv):
                out[p.name] = cv
            case .coerced(let cv, let note):
                out[p.name] = cv
                notes.append(note)
            case .fail(let got):
                typeErrors.append(ArgTypeError(key: p.name, expected: expectedDescription(p), got: got))
            }
        }

        if !missing.isEmpty || !typeErrors.isEmpty {
            return .rejected(ToolCorrection(
                tool: schema.name, missing: missing,
                typeErrors: typeErrors, unknownKeys: unknownKeys))
        }
        let args = ToolArguments(out)
        return notes.isEmpty ? .ok(args) : .correctable(args, notes: notes)
    }

    // MARK: - per-value coercion

    private enum Coerced {
        case exact(JSONValue)
        case coerced(JSONValue, String)
        case fail(got: String)
    }

    private static func expectedDescription(_ p: ToolParameter) -> String {
        if let e = p.enumValues { return "one of [\(e.joined(separator: ", "))]" }
        if p.type == .array { return "array of \((p.arrayElementType ?? .string).rawValue)" }
        return p.type.rawValue
    }

    private static func coerce(_ v: JSONValue, to p: ToolParameter) -> Coerced {
        // Enum constraint is checked on top of the (string) type.
        if let allowed = p.enumValues {
            guard case .string(let s) = v else { return .fail(got: v.typeName) }
            return allowed.contains(s) ? .exact(v)
                : .fail(got: "\"\(s)\" (not one of [\(allowed.joined(separator: ", "))])")
        }

        switch p.type {
        case .string:
            switch v {
            case .string: return .exact(v)
            case .int(let i): return .coerced(.string(String(i)), "coerced integer \(i) to string for `\(p.name)`")
            case .double(let d): return .coerced(.string(trimDouble(d)), "coerced number to string for `\(p.name)`")
            case .bool(let b): return .coerced(.string(b ? "true" : "false"), "coerced boolean to string for `\(p.name)`")
            default: return .fail(got: v.typeName)
            }

        case .integer:
            switch v {
            case .int: return .exact(v)
            case .double(let d) where d == d.rounded() && d.isFinite:
                if let i = Int(exactly: d) {
                    return .coerced(.int(i), "coerced \(trimDouble(d)) to integer for `\(p.name)`")
                }
                return .fail(got: "number \(trimDouble(d)) exceeds Int range for `\(p.name)`")
            case .string(let s):
                if let i = Int(s.trimmingCharacters(in: .whitespaces)) {
                    return .coerced(.int(i), "parsed \"\(s)\" as integer for `\(p.name)`")
                }
                if let d = Double(s), d == d.rounded() {
                    if let i = Int(exactly: d) {
                        return .coerced(.int(i), "parsed \"\(s)\" as integer for `\(p.name)`")
                    }
                    return .fail(got: "number \"\(s)\" exceeds Int range for `\(p.name)`")
                }
                return .fail(got: "string \"\(s)\"")
            default: return .fail(got: v.typeName)
            }

        case .number:
            switch v {
            case .double: return .exact(v)
            case .int(let i): return .coerced(.double(Double(i)), "coerced integer \(i) to number for `\(p.name)`")
            case .string(let s):
                if let d = Double(s.trimmingCharacters(in: .whitespaces)) {
                    return .coerced(.double(d), "parsed \"\(s)\" as number for `\(p.name)`")
                }
                return .fail(got: "string \"\(s)\"")
            default: return .fail(got: v.typeName)
            }

        case .boolean:
            switch v {
            case .bool: return .exact(v)
            case .string(let s):
                switch s.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true": return .coerced(.bool(true), "parsed \"\(s)\" as boolean for `\(p.name)`")
                case "false": return .coerced(.bool(false), "parsed \"\(s)\" as boolean for `\(p.name)`")
                default: return .fail(got: "string \"\(s)\"")
                }
            case .int(let i) where i == 0 || i == 1:
                return .coerced(.bool(i == 1), "coerced \(i) to boolean for `\(p.name)`")
            default: return .fail(got: v.typeName)
            }

        case .array:
            switch v {
            case .array: return .exact(v)
            case .string, .int, .double, .bool:
                return .coerced(.array([v]), "wrapped single value in an array for `\(p.name)`")
            default: return .fail(got: v.typeName)
            }

        case .object:
            switch v {
            case .object: return .exact(v)
            case .string(let s):
                if let parsed = JSONValue.parse(s), case .object = parsed {
                    return .coerced(parsed, "parsed JSON string into an object for `\(p.name)`")
                }
                return .fail(got: "string \"\(s)\"")
            default: return .fail(got: v.typeName)
            }
        }
    }

    /// Render a double without a trailing ".0" when it is integral.
    private static func trimDouble(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
    }
}
