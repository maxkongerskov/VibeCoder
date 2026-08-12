//
//  InlineToolCallParser.swift
//
//  Some local-model families emit tool calls as XML/JSON embedded in
//  the assistant's content string instead of using OpenAI's standard
//  `tool_calls` field. LM Studio's chat-completions adapter forwards
//  the raw text without converting, so the agent sees a plain
//  assistant message with no `tool_calls` set, and the call never
//  reaches `ToolRegistry` — the tool never runs.
//
//  Known formats this parser handles:
//
//    1. MiniMax / Anthropic-style XML invoke blocks:
//         <minimax:tool_call>           (or any wrapper, or none at all)
//           <invoke name="run_shell">
//             <parameter name="command">mkdir -p /tmp/x</parameter>
//           </invoke>
//         </minimax:tool_call>
//
//       Wrapper tags vary (<minimax:tool_call>, <function_calls>,
//       <tool_calls>, …). We don't require any specific wrapper — we
//       look for <invoke name="..."> blocks anywhere in the content and
//       strip the standard wrapper tags afterwards.
//
//    2. Hermes-style JSON inside <tool_call>:
//         <tool_call>
//           {"name": "run_shell", "arguments": {"command": "ls"}}
//         </tool_call>
//
//    3. Bare top-level JSON in the tool-call shape, with no wrapper at
//       all. Last-resort gate — only runs when the wrapped passes find
//       nothing.
//
//  Called from the agent loop as a fallback: only runs when the
//  response's standard `tool_calls` field is empty. If the standard
//  field has calls, we trust those and don't double-execute.
//

import Foundation

public enum InlineToolCallParser {

    /// Result of an extraction pass. Not Equatable because
    /// `ToolCallInvocation.arguments` is a free-form JSON string and
    /// callers compare on individual fields anyway.
    public struct Result: Sendable {
        /// The assistant content with all detected tool-call markup
        /// removed (and whitespace trimmed). Safe to display in the
        /// chat bubble alongside the synthesised tool-call UI cards.
        public let cleaned: String
        /// Tool calls extracted from the content, ready to dispatch
        /// exactly like a standard `tool_calls` payload.
        public let calls: [ToolCallInvocation]

        public init(cleaned: String, calls: [ToolCallInvocation]) {
            self.cleaned = cleaned
            self.calls = calls
        }
    }

    /// Walk the content string and extract any embedded tool calls.
    /// When no patterns match, `calls` is empty and `cleaned` is the
    /// trimmed input — so callers can always use `result.cleaned` as
    /// the authoritative content.
    public static func extract(from content: String) -> Result {
        var working = content
        var calls: [ToolCallInvocation] = []

        // Pass 1: <invoke name="..."> ... </invoke> blocks. MiniMax,
        // Anthropic-style, and several Qwen variants all use this.
        calls.append(contentsOf: extractInvokeBlocks(in: &working))

        // Pass 2: <tool_call>{"name":..., "arguments":...}</tool_call>
        // (Hermes-style). Done after Pass 1 so a malformed JSON inside
        // <tool_call> doesn't shadow a valid XML invoke block.
        calls.append(contentsOf: extractHermesBlocks(in: &working))

        // Pass 3 (LAST RESORT): bare top-level JSON with no wrapper tags.
        // Observed with Qwen2.5-Coder / Qwen3.6 under llama.cpp and LM
        // Studio: the model emits tool calls as prose JSON instead of
        // native `tool_calls`. Gated on `calls.isEmpty` so it only fires
        // when nothing wrapped was found — keeps the false-positive blast
        // radius tiny.
        if calls.isEmpty {
            calls.append(contentsOf: extractJSONArrayToolCalls(in: &working))
            if calls.isEmpty {
                calls.append(contentsOf: extractBareJSONToolCalls(in: &working))
            }
        }

        // Strip residual wrapper tags that pass 1 left behind (the
        // <invoke> body was removed but `<minimax:tool_call>...</...>`
        // outer tags remain).
        for wrapper in residualWrappers {
            working = working.replacingOccurrences(of: wrapper, with: "")
        }

        let cleaned = working.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(cleaned: cleaned, calls: calls)
    }

    // MARK: - Pass 1: <invoke name="..."> blocks

    /// `<invoke name="X">…<parameter name="K">V</parameter>…</invoke>`.
    /// The XML-ish format used by MiniMax (<minimax:tool_call> wrapper)
    /// and the historical Anthropic format (<function_calls> wrapper).
    private static let invokePattern = #"<invoke name="([^"]+)">([\s\S]*?)</invoke>"#

    /// Compile the regex once for the process lifetime instead of per
    /// message. Force-try because the pattern is a static string
    /// constant — a syntax error would surface during tests on first
    /// invocation and we'd rather crash loudly than silently strip
    /// nothing.
    private static let invokeRegex = try! NSRegularExpression(pattern: invokePattern)

    private static func extractInvokeBlocks(in content: inout String) -> [ToolCallInvocation] {
        let regex = invokeRegex
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        // Build calls in match order (so they execute in the order the
        // model emitted them), then strip the matched ranges in REVERSE
        // order so removals don't shift earlier indices.
        var calls: [ToolCallInvocation] = []
        for m in matches {
            let name = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            let args = parseInvokeParameters(from: body)
            let argsJSON = encodeArguments(args)
            calls.append(ToolCallInvocation(
                id: "inline_\(UUID().uuidString.prefix(8))",
                name: name,
                arguments: argsJSON
            ))
        }
        var mutated = content as NSString
        for m in matches.reversed() {
            mutated = mutated.replacingCharacters(in: m.range, with: "") as NSString
        }
        content = mutated as String
        return calls
    }

    /// `<parameter name="K">V</parameter>` repeated. V can be multiline
    /// and contain any chars except literally `</parameter>`. We trim
    /// surrounding whitespace because models often indent params.
    private static let parameterPattern = #"<parameter name="([^"]+)">([\s\S]*?)</parameter>"#
    private static let parameterRegex = try! NSRegularExpression(pattern: parameterPattern)

    private static func parseInvokeParameters(from body: String) -> [String: String] {
        let regex = parameterRegex
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var dict: [String: String] = [:]
        for m in matches {
            let key = ns.substring(with: m.range(at: 1))
            let val = ns.substring(with: m.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            dict[key] = val
        }
        return dict
    }

    // MARK: - Pass 2: <tool_call>{json}</tool_call> (Hermes)

    private static let hermesPattern = #"<tool_call>\s*(\{[\s\S]*?\})\s*</tool_call>"#
    private static let hermesRegex = try! NSRegularExpression(pattern: hermesPattern)

    private static func extractHermesBlocks(in content: inout String) -> [ToolCallInvocation] {
        let regex = hermesRegex
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        var calls: [ToolCallInvocation] = []
        var keepRanges = matches  // matches we successfully parsed (so we can remove them)
        for m in matches {
            let json = ns.substring(with: m.range(at: 1))
            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let call = parseToolCallDict(dict) else {
                // Malformed inside the tags — leave the block in place so
                // the user can see the broken output rather than have it
                // silently swallowed.
                keepRanges.removeAll { $0.range == m.range }
                continue
            }
            calls.append(call)
        }
        var mutated = content as NSString
        for m in keepRanges.reversed() {
            mutated = mutated.replacingCharacters(in: m.range, with: "") as NSString
        }
        content = mutated as String
        return calls
    }

    // MARK: - Pass 3: bare top-level JSON tool call (no wrapper)

    /// Extract tool calls that arrive as a BARE JSON object —
    /// `{"name": "read_file", "arguments": {"path": "…"}}` — with no
    /// `<tool_call>`/`<invoke>` wrapper. Only the tool-call SHAPE
    /// qualifies: a top-level object with a non-empty string `name`
    /// AND an `arguments` (or `parameters`) value that is itself an
    /// OBJECT. That shape guard is what keeps this from stealing
    /// ordinary JSON the model might print as content. (A false
    /// positive at worst yields an unknown-tool error downstream,
    /// which the registry already handles gracefully.)
    private static func extractBareJSONToolCalls(in content: inout String) -> [ToolCallInvocation] {
        let ns = content as NSString
        let ranges = topLevelJSONObjectRanges(in: content)
        guard !ranges.isEmpty else { return [] }

        var calls: [ToolCallInvocation] = []
        var matched: [NSRange] = []
        for r in ranges {
            let json = ns.substring(with: r)
            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let call = parseToolCallDict(dict) else { continue }
            calls.append(call)
            matched.append(r)
        }
        guard !calls.isEmpty else { return [] }
        var mutated = content as NSString
        for r in matched.reversed() {
            mutated = mutated.replacingCharacters(in: r, with: "") as NSString
        }
        content = mutated as String
        return calls
    }

    /// `[{"tool": "list_directory", "path": "."}, …]` — Qwen3.6 via LM
    /// Studio often emits a JSON array of flat tool objects instead of
    /// native `tool_calls`.
    private static func extractJSONArrayToolCalls(in content: inout String) -> [ToolCallInvocation] {
        let ns = content as NSString
        let ranges = topLevelJSONArrayRanges(in: content)
        guard !ranges.isEmpty else { return [] }

        var calls: [ToolCallInvocation] = []
        var matched: [NSRange] = []
        for r in ranges {
            let json = ns.substring(with: r)
            guard let data = json.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  !raw.isEmpty else { continue }
            var parsed: [ToolCallInvocation] = []
            for element in raw {
                guard let dict = element as? [String: Any],
                      let call = parseToolCallDict(dict) else {
                    parsed = []
                    break
                }
                parsed.append(call)
            }
            guard !parsed.isEmpty else { continue }
            calls.append(contentsOf: parsed)
            matched.append(r)
        }
        guard !calls.isEmpty else { return [] }
        var mutated = content as NSString
        for r in matched.reversed() {
            mutated = mutated.replacingCharacters(in: r, with: "") as NSString
        }
        content = mutated as String
        return calls
    }

    /// Normalize one inline tool-call object. Accepts `name` or `tool` for
    /// the tool id; `arguments`/`parameters` nested objects, or flat
    /// top-level params (everything except the reserved keys).
    private static func parseToolCallDict(_ dict: [String: Any]) -> ToolCallInvocation? {
        let name = (dict["name"] as? String) ?? (dict["tool"] as? String)
        guard let name, !name.isEmpty else { return nil }

        let argsJSON: String
        if let argsObj = dict["arguments"] ?? dict["parameters"] {
            if let s = argsObj as? String {
                argsJSON = s
            } else if let d = argsObj as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: d),
                      let s = String(data: data, encoding: .utf8) {
                argsJSON = s
            } else {
                argsJSON = "{}"
            }
        } else {
            let reserved: Set<String> = ["name", "tool", "arguments", "parameters"]
            var flat: [String: Any] = [:]
            for (k, v) in dict where !reserved.contains(k) {
                flat[k] = v
            }
            if let data = try? JSONSerialization.data(withJSONObject: flat),
               let s = String(data: data, encoding: .utf8) {
                argsJSON = s
            } else {
                argsJSON = "{}"
            }
        }
        return ToolCallInvocation(
            id: "inline_\(UUID().uuidString.prefix(8))",
            name: name,
            arguments: argsJSON
        )
    }

    /// Locate top-level (depth-0) balanced `[ … ]` substrings, ignoring
    /// brackets inside JSON string literals. `{`/`}` nesting counts too so
    /// objects inside an array are not mistaken for standalone objects.
    private static func topLevelJSONArrayRanges(in s: String) -> [NSRange] {
        topLevelJSONContainerRanges(in: s, open: 91, close: 93)  // [ ]
    }

    /// Locate top-level (depth-0) balanced `{ … }` substrings, ignoring
    /// braces that appear inside JSON string literals. `[`/`]` nesting
    /// counts too so objects inside an array are not mistaken for
    /// standalone tool calls.
    private static func topLevelJSONObjectRanges(in s: String) -> [NSRange] {
        topLevelJSONContainerRanges(in: s, open: 123, close: 125)  // { }
    }

    private static func topLevelJSONContainerRanges(in s: String, open: unichar, close: unichar) -> [NSRange] {
        let ns = s as NSString
        let n = ns.length
        var ranges: [NSRange] = []
        var nest = 0
        var start = -1
        var inString = false
        var escaped = false
        var i = 0
        while i < n {
            let c = ns.character(at: i)
            if inString {
                if escaped { escaped = false }
                else if c == 92 { escaped = true }      // backslash
                else if c == 34 { inString = false }    // closing quote
            } else if c == 34 {                          // opening quote
                inString = true
            } else if c == open {
                if nest == 0 { start = i }
                nest += 1
            } else if c == close {
                if nest > 0 {
                    nest -= 1
                    if nest == 0, start >= 0 {
                        ranges.append(NSRange(location: start, length: i - start + 1))
                        start = -1
                    }
                }
            } else if c == 91 || c == 123 {              // [ or {
                nest += 1
            } else if c == 93 || c == 125 {              // ] or }
                if nest > 0 { nest -= 1 }
            }
            i += 1
        }
        return ranges
    }

    // MARK: - Helpers

    /// Wrapper tags we strip after extraction. Adding a new family? Add
    /// its opener + closer here. Order doesn't matter — these are plain
    /// substring replaces.
    private static let residualWrappers: [String] = [
        "<minimax:tool_call>", "</minimax:tool_call>",
        "<function_calls>",    "</function_calls>",
        "<tool_calls>",        "</tool_calls>",
    ]

    /// JSON-encode the parameters dict into the string format the rest
    /// of AgentCore expects (matches what arrives in the standard
    /// `tool_calls.function.arguments` field). Empty dict → `"{}"`.
    private static func encodeArguments(_ args: [String: String]) -> String {
        guard !args.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
