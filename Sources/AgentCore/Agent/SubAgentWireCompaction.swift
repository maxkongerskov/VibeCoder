//
//  SubAgentWireCompaction.swift
//
//  Wave B S6b (W08): wire-only compaction for sub-agent model requests.
//  Extracted from SubAgentRunner so cancel/stall work (W06) can edit the
//  runner loop without clobbering the compaction helper.
//
//  Pipeline (min path of AgentLoop — no FullReplace / Semantic):
//    1. ToolResultCompressor.compress
//    2. ChatLoop.compactHistory when over budget
//
//  Contract: never mutates the caller's message array / stored transcript.
//

import Foundation

public enum SubAgentWireCompaction {

    /// Default context window when `ModelDescriptor.contextLength` is nil.
    public static let defaultContextWindowTokens: Int = 32_768

    /// Build the **wire-only** message list for one sub-agent model call.
    ///
    /// - Parameters:
    ///   - messages: Full sub-agent history (may include a leading system msg).
    ///   - model: Used for `contextLength` when `contextBudgetTokens` is nil.
    ///   - contextBudgetTokens: Explicit budget override. When nil, uses
    ///     `ContextBudget.budgetTokens` on the model window (default 70%).
    ///   - compactThresholdPercent: Threshold % when deriving budget from window.
    public static func wireMessages(
        from messages: [ChatMessage],
        model: ModelDescriptor,
        contextBudgetTokens: Int? = nil,
        compactThresholdPercent: Double = 70
    ) -> [ChatMessage] {
        let compressed = ToolResultCompressor.compress(messages)
        let window = max(2_048, model.contextLength ?? defaultContextWindowTokens)
        let budget = contextBudgetTokens
            ?? ContextBudget.budgetTokens(
                effectiveContextLength: window,
                compactThresholdPercent: compactThresholdPercent)
        guard budget > 0 else { return compressed }
        // System (if present) already lives inside `messages`; do not double-count.
        return ChatLoop.compactHistory(
            compressed,
            systemPromptTokens: 0,
            budgetTokens: budget)
    }
}

extension SubAgentRunner {
    /// Convenience forwarder — preferred call site for tests and external use.
    public static let defaultContextWindowTokens =
        SubAgentWireCompaction.defaultContextWindowTokens

    public static func wireMessages(
        from messages: [ChatMessage],
        model: ModelDescriptor,
        contextBudgetTokens: Int? = nil,
        compactThresholdPercent: Double = 70
    ) -> [ChatMessage] {
        SubAgentWireCompaction.wireMessages(
            from: messages,
            model: model,
            contextBudgetTokens: contextBudgetTokens,
            compactThresholdPercent: compactThresholdPercent)
    }
}
