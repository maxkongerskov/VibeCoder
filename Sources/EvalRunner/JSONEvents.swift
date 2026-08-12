//
//  JSONEvents.swift
//
//  Machine-readable JSONL events for eval-runner (Phase B PB6).
//  Stable event types for oracles / CI: tool_call, text, done, error.
//

import Foundation
import AgentCore

/// One JSONL line on stdout when `--json-events` is set.
public enum EvalJSONEvent: Equatable, Sendable {
    case toolCall(id: String, name: String, phase: ToolPhase, isError: Bool)
    case text(String)
    case done(reason: String, toolCalls: Int, messages: Int, ok: Bool)
    case error(String)

    public enum ToolPhase: String, Sendable, Equatable {
        case started
        case completed
    }

    /// Encode as a single JSON object (one line when written as JSONL).
    public func jsonObject() -> [String: Any] {
        switch self {
        case .toolCall(let id, let name, let phase, let isError):
            return [
                "type": "tool_call",
                "id": id,
                "name": name,
                "phase": phase.rawValue,
                "is_error": isError,
            ]
        case .text(let s):
            return ["type": "text", "text": s]
        case .done(let reason, let toolCalls, let messages, let ok):
            return [
                "type": "done",
                "reason": reason,
                "tool_calls": toolCalls,
                "messages": messages,
                "ok": ok,
            ]
        case .error(let message):
            return ["type": "error", "message": message]
        }
    }

    /// UTF-8 JSON object bytes + newline (JSONL).
    public func jsonLine() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: jsonObject(),
            options: [.sortedKeys]
        )
        guard var line = String(data: data, encoding: .utf8) else {
            throw EvalRunnerLibError.encodeFailed
        }
        line.append("\n")
        return line
    }

    /// Map a loop event into zero or more JSON events (pure; no I/O).
    public static func from(loopEvent: LoopEvent) -> [EvalJSONEvent] {
        switch loopEvent {
        case .toolStarted(let id, let name, _):
            return [.toolCall(id: id, name: name, phase: .started, isError: false)]
        case .toolCompleted(let id, let name, _, let isError):
            return [.toolCall(id: id, name: name, phase: .completed, isError: isError)]
        case .contentDelta(let s):
            guard !s.isEmpty else { return [] }
            return [.text(s)]
        case .error(let description):
            return [.error(description)]
        case .finished(let reason):
            // `done` is emitted by the runner after the loop returns so we
            // can include final tool_calls / message counts. Ignore here.
            _ = reason
            return []
        default:
            return []
        }
    }
}

public enum EvalRunnerLibError: Error, CustomStringConvertible, Equatable {
    case encodeFailed
    case resumeMissing(String)
    case resumeDecode(String)
    case saveFailed(String)

    public var description: String {
        switch self {
        case .encodeFailed: return "failed to encode JSON event"
        case .resumeMissing(let p): return "resume file not found: \(p)"
        case .resumeDecode(let s): return "resume decode failed: \(s)"
        case .saveFailed(let s): return "save conversation failed: \(s)"
        }
    }
}
