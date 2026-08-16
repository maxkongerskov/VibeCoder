//
//  ContextOverflowClassifier.swift
//
//  Detects provider context-window overflow (reactive-compact signal).
//  Output-length stops (`max_tokens` / finish-reason `length`) are NOT overflow.
//

import Foundation

public enum ContextOverflowClassifier: Sendable {

    /// ZCode finish-reason / error-code markers (`KOi` / `isModelContextExceededMarker`).
    public static let markers: [String] = [
        "model_context_exceeded",
        "context_exceeded",
        "context_length_exceeded",
        "context_window_exceeded",
        "model_context_window_exceeded",
        "prompt_too_long",
    ]

    /// True when `message` is a context-window overflow (not an output-length stop).
    public static func isContextExceeded(_ message: String) -> Bool {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        if isLengthStopOnly(t) { return false }

        for marker in markers where t.contains(marker) {
            return true
        }

        // OpenAI / Anthropic prose (ZCode `TUr` + `QOi` plus listed variants).
        if t.contains("maximum context length") { return true }
        if t.contains("too many tokens") { return true }
        if t.contains("prompt is too long") { return true }
        if t.contains("context") && t.contains("too long") { return true }
        if t.contains("prompt") && t.contains("too long") { return true }
        if t.contains("context") && t.contains("exceed") { return true }
        if t.contains("input token count") && t.contains("exceed")
            && t.contains("maximum number of tokens allowed") {
            return true
        }
        if t.contains("range of input length should be") { return true }
        if t.contains("total message token length") && t.contains("exceed")
            && t.contains("model limit") {
            return true
        }
        return false
    }

    /// Walks `Error` text (description, `BackendError` body, `NSError` userInfo).
    public static func isContextExceeded(error: Error) -> Bool {
        var seen = Set<ObjectIdentifier>()
        return isContextExceeded(error: error, depth: 0, seen: &seen)
    }

    // MARK: - Internals

    /// `max_tokens` / `length` finish-reason with no overflow marker.
    private static func isLengthStopOnly(_ lowercased: String) -> Bool {
        let t = lowercased.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "max_tokens" || t == "max tokens" || t == "length" {
            return true
        }
        let lengthStopPhrases = [
            "finish_reason: length",
            "finish_reason=length",
            "finish_reason: max_tokens",
            "finish_reason=max_tokens",
            "stop_reason: max_tokens",
            "stop_reason=max_tokens",
            "stop_reason: length",
            "stop_reason=length",
            "\"finish_reason\":\"length\"",
            "\"finish_reason\": \"length\"",
            "\"finish_reason\":\"max_tokens\"",
            "stop reason: length",
            "stopped because max_tokens",
            "output truncated due to max_tokens",
        ]
        if lengthStopPhrases.contains(where: { t.contains($0) }) {
            return !hasOverflowSignal(t)
        }
        if (t.contains("max_tokens") || t == "max_token") && !hasOverflowSignal(t) {
            // Bare output-limit wording — not input overflow.
            let mentionsContext = t.contains("context") || t.contains("prompt")
                || t.contains("window") || t.contains("too many tokens")
            return !mentionsContext
        }
        return false
    }

    private static func hasOverflowSignal(_ t: String) -> Bool {
        for marker in markers where t.contains(marker) { return true }
        if t.contains("maximum context length") { return true }
        if t.contains("too many tokens") { return true }
        if t.contains("prompt is too long") { return true }
        if t.contains("context") && t.contains("exceed") { return true }
        if t.contains("context") && t.contains("too long") { return true }
        if t.contains("prompt") && t.contains("too long") { return true }
        return false
    }

    private static func isContextExceeded(
        error: Error,
        depth: Int,
        seen: inout Set<ObjectIdentifier>
    ) -> Bool {
        guard depth < 8 else { return false }

        if isContextExceeded(error.localizedDescription) { return true }
        if isContextExceeded(String(describing: error)) { return true }

        if let backend = error as? BackendError {
            switch backend {
            case .http(_, let body):
                if isContextExceeded(body) { return true }
            case .transport(let s), .decoding(let s), .unsupported(let s):
                if isContextExceeded(s) { return true }
            case .cancelled:
                break
            }
        }

        if let localized = error as? LocalizedError {
            if let d = localized.errorDescription, isContextExceeded(d) { return true }
            if let f = localized.failureReason, isContextExceeded(f) { return true }
            if let r = localized.recoverySuggestion, isContextExceeded(r) { return true }
        }

        let ns = error as NSError
        let oid = ObjectIdentifier(ns)
        if seen.contains(oid) { return false }
        seen.insert(oid)

        if isContextExceeded(ns.domain) { return true }
        if isContextExceeded(ns.localizedDescription) { return true }

        for (_, value) in ns.userInfo {
            if let s = value as? String, isContextExceeded(s) { return true }
            if let nested = value as? Error {
                if isContextExceeded(error: nested, depth: depth + 1, seen: &seen) {
                    return true
                }
            }
        }
        return false
    }
}
