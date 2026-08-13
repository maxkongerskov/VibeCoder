//
//  TokenEstimator.swift
//
//  Rough char-based token estimator. Tokenisation differs per model
//  family (BPE vs SentencePiece vs different vocabularies), and
//  shipping a real tokenizer per model would mean bundling 1MB+ of
//  vocab data per family. The char/4 rule of thumb is industry-standard
//  for budgeting English + code and is off by ~20% in either direction
//  for most modern models — fine for "is the system prompt eating most
//  of the context window?" decisions.
//
//  Used by the chat-header context-usage indicator and (in due course)
//  by the agent loop to pick a compact prompt path on tiny/small
//  presets.
//

import Foundation

public enum TokenEstimator {

    /// Estimated tokens for an arbitrary string. Rounds up — better to
    /// overestimate when sizing against a context window than to silently
    /// truncate output. Always returns at least 0 (empty string → 0).
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let chars = text.count
        // Equivalent to ceil(chars / 4) using integer math.
        return (chars + 3) / 4
    }

    /// Percentage (0–100, rounded) of the model's nominal context window
    /// that a prompt of size `tokens` would occupy. Caller supplies the
    /// context cap because it varies per model — we don't carry a table
    /// of model→cap mappings here.
    public static func percentOfContext(tokens: Int, contextSize: Int) -> Int {
        guard contextSize > 0 else { return 0 }
        let raw = (Double(tokens) / Double(contextSize) * 100).rounded()
        if raw.isNaN || raw.isInfinite { return 0 }
        return min(100, max(0, Int(raw)))
    }
}
