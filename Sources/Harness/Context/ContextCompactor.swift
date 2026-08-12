//
//  ContextCompactor.swift  (Harness)
//
//  Token-aware context compaction, ported faithfully from AgentCore's
//  ChatLoop (`estimateMessageTokens`, `estimateTotalTokens`,
//  `compactHistory`). No logic changes — same thresholds, same
//  elision-only strategy, same 1000-char bucket markers. The only
//  adaptations for the clean-slate module:
//
//    • `ToolCallInvocation` → `ToolCall`, `ChatMessage.Role` → top-level
//      `Role` (both already defined in Harness/Core/Message.swift).
//    • the plan-authoring tool set comes from the already-ported
//      `StallDetector.planAuthoringTools` rather than a local copy.
//
//  Context-window management is what lets a long agentic run survive on a
//  local model with a small context window: without it, every iteration
//  resends the entire growing transcript until the model overflows.
//

import Foundation
import AgentCore

public enum ContextCompactor {

    // MARK: - Estimation

    /// Rough per-message token estimate (content + any tool-call
    /// arguments).
    public static func estimateMessageTokens(_ m: ChatMessage) -> Int {
        var t = TokenEstimator.estimate(m.content)
        for c in m.toolCalls {
            t += TokenEstimator.estimate(c.name)
            t += TokenEstimator.estimate(c.arguments)
        }
        return t
    }

    /// Total prompt tokens for a system-prompt size plus a message list.
    public static func estimateTotalTokens(systemPromptTokens: Int, messages: [ChatMessage]) -> Int {
        systemPromptTokens + messages.reduce(0) { $0 + estimateMessageTokens($1) }
    }

    // MARK: - Compaction

    /// Returns a context-fitted copy of `messages` for sending to the
    /// model. Context-window management is what lets a long agentic
    /// run survive on a local model with a small context window:
    /// without it, every iteration resends the entire growing transcript
    /// until the model overflows.
    ///
    /// Strategy — ELISION ONLY, never structural removal, so the
    /// assistant↔tool `tool_call_id` pairing strict OpenAI-compatible
    /// servers require is never broken:
    ///   1. If the estimate already fits `budgetTokens`, return
    ///      unchanged.
    ///   2. Otherwise walk the OLDER region (everything before the last
    ///      `keepRecent` messages) and replace large `.tool` bodies with
    ///      a short head + elision marker, stopping as soon as we're
    ///      under budget.
    ///   3. If still over, do the same to old `.assistant` prose
    ///      (tool-call structure stays intact — only `content` is
    ///      trimmed).
    ///
    /// NEVER touched: user messages, the most recent `keepRecent`
    /// messages, plan-authoring messages, and every message's structural
    /// fields. The caller keeps the full, un-compacted history for the
    /// UI and persistence — this copy is for the wire only.
    ///
    /// (Faithful port of AgentCore's `ChatLoop.compactHistory`; the name
    /// is kept for fidelity.)
    public static func compactHistory(_ messages: [ChatMessage],
                                      systemPromptTokens: Int,
                                      budgetTokens: Int,
                                      keepRecent: Int = 6,
                                      elideCap: Int = 240) -> [ChatMessage] {
        guard budgetTokens > 0,
              estimateTotalTokens(systemPromptTokens: systemPromptTokens, messages: messages) > budgetTokens
        else { return messages }

        var working = messages
        let protectedFrom = max(0, working.count - keepRecent)

        // Bucket the size hint to 1000-char granularity so the marker
        // doesn't change byte-for-byte every time the transcript grows
        // by a few chars (preserves KV-cache hits on the elided content).
        func elide(_ s: String, kind: String) -> String {
            let bucket = (s.count / 1000) * 1000
            return String(s.prefix(elideCap))
                + "\n\n[…\(kind) elided to fit the context window — ~\(bucket) chars in the saved transcript]"
        }

        // Maintain a running token total instead of re-scanning the full
        // message array on every elision check (O(N²) → O(N)).
        var runningTokens = estimateTotalTokens(
            systemPromptTokens: systemPromptTokens, messages: working)

        func underBudget() -> Bool { runningTokens <= budgetTokens }

        // Phase 1: elide old, large tool outputs (the dominant token cost).
        for i in 0..<protectedFrom where working[i].role == .tool {
            if underBudget() { return working }
            let old = working[i].content
            if old.count > elideCap {
                let replacement = elide(old, kind: "tool output")
                let delta = TokenEstimator.estimate(old) - TokenEstimator.estimate(replacement)
                working[i].content = replacement
                runningTokens -= delta
            }
        }

        // Phase 2: still over → trim old assistant prose. Tool-call
        // structure stays intact; user messages and plan-authoring
        // messages are never touched.
        for i in 0..<protectedFrom where working[i].role == .assistant
            && !working[i].toolCalls.contains(where: { ChatLoop.planAuthoringTools.contains($0.name) }) {
            if underBudget() { return working }
            let old = working[i].content
            if old.count > elideCap {
                let replacement = elide(old, kind: "assistant message")
                let delta = TokenEstimator.estimate(old) - TokenEstimator.estimate(replacement)
                working[i].content = replacement
                runningTokens -= delta
            }
        }

        return working
    }
}
