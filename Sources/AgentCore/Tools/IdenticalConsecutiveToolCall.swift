//
//  IdenticalConsecutiveToolCall.swift
//
//  Fail-closed bounce when the model repeats the same tool + equivalent
//  args twice in a row (typical: identical curl/python GitHub probes).
//  Lives next to ToolRegistry so AgentLoop.swift does not grow.
//  Complements DoomLoopDetector / Governor (those wait for 4–6 repeats).
//

import Foundation

public enum IdenticalConsecutiveToolCall: Sendable {

    public static func signature(name: String, arguments: ToolArguments) -> String {
        let args: String
        if JSONSerialization.isValidJSONObject(arguments.raw),
           let data = try? JSONSerialization.data(
            withJSONObject: arguments.raw, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            args = text
        } else {
            args = ChatLoop.canonicalJSONArguments(String(describing: arguments.raw))
        }
        return name + "\u{1e}" + args
    }

    public static func isRepeat(previous: String?, current: String) -> Bool {
        guard let previous, !previous.isEmpty else { return false }
        return previous == current
    }

    public static func failClosedResult(toolName: String) -> ToolResult {
        ToolResult(
            content: """
            Identical consecutive tool call blocked: `\(toolName)` was just run with equivalent arguments. \
            Do not execute it again. Use the previous tool result. If that result already has \
            merged=true or PR_STATUS: MERGED, stop probing.
            """,
            isError: true)
    }
}
