//
//  ContextUsageBreakdown.swift
//
//  Token breakdown of the live conversation for the ZCode-style
//  context inspector (what uses the window).
//

import Foundation

/// Category totals for the context inspector sheet.
public struct ContextUsageBreakdown: Sendable, Equatable {
    public struct Category: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let tokens: Int
        /// Short secondary line (e.g. "12 messages").
        public let detail: String

        public init(id: String, label: String, tokens: Int, detail: String = "") {
            self.id = id
            self.label = label
            self.tokens = tokens
            self.detail = detail
        }
    }

    public let categories: [Category]
    public let totalTokens: Int
    /// Compaction budget (threshold × window).
    public let budgetTokens: Int
    /// Effective model context window after user max-window cap.
    public let windowTokens: Int
    public let compactThresholdPercent: Double

    public init(
        categories: [Category],
        totalTokens: Int,
        budgetTokens: Int,
        windowTokens: Int,
        compactThresholdPercent: Double
    ) {
        self.categories = categories
        self.totalTokens = totalTokens
        self.budgetTokens = budgetTokens
        self.windowTokens = windowTokens
        self.compactThresholdPercent = compactThresholdPercent
    }

    public var budgetFraction: Double {
        guard budgetTokens > 0 else { return 0 }
        return Double(totalTokens) / Double(budgetTokens)
    }

    public var windowFraction: Double {
        guard windowTokens > 0 else { return 0 }
        return Double(totalTokens) / Double(windowTokens)
    }

    /// Tokens left before auto-compact threshold (0 when already past).
    public var tokensUntilCompact: Int {
        max(0, budgetTokens - totalTokens)
    }

    /// True when estimated usage is at or past the compact budget.
    public var isAtOrPastCompact: Bool {
        budgetTokens > 0 && totalTokens >= budgetTokens
    }

    /// 0…1+ fraction of the path to auto-compact (same as budgetFraction).
    public var compactProgress: Double { budgetFraction }

    /// Percent of the effective model window used (0…100+, rounded).
    public var windowPercent: Int {
        guard windowTokens > 0 else { return 0 }
        return Int((windowFraction * 100).rounded())
    }

    /// Percent of the auto-compact budget used (0…100+, rounded).
    public var budgetPercent: Int {
        guard budgetTokens > 0 else { return 0 }
        return Int((budgetFraction * 100).rounded())
    }

    /// Compact meter primary label: used / window tokens (e.g. "12.3k / 128k").
    public var meterUsedOverWindowLabel: String {
        "\(Self.formatTokenCount(totalTokens)) / \(Self.formatTokenCount(windowTokens))"
    }

    /// Compact meter secondary: window fill % (e.g. "27%" or "compact" when past budget).
    public var meterWindowPercentLabel: String {
        if isAtOrPastCompact { return "compact" }
        return "\(min(100, max(0, windowPercent)))%"
    }

    /// Shared k/M token formatting for UI + slash `/context`.
    public static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    /// Build a breakdown from live conversation state.
    public static func build(
        systemPrompt: String,
        messages: [ChatMessage],
        streamingContent: String = "",
        streamingReasoning: String = "",
        windowTokens: Int,
        budgetTokens: Int,
        compactThresholdPercent: Double
    ) -> ContextUsageBreakdown {
        var system = TokenEstimator.estimate(systemPrompt)
        var user = 0
        var assistant = 0
        var reasoning = TokenEstimator.estimate(streamingReasoning)
        var tools = 0
        var toolCallArgs = 0
        var userCount = 0
        var assistantCount = 0
        var toolCount = 0

        for m in messages {
            switch m.role {
            case .system:
                system += TokenEstimator.estimate(m.content)
            case .user:
                user += TokenEstimator.estimate(m.content)
                userCount += 1
            case .assistant:
                assistant += TokenEstimator.estimate(m.content)
                if let r = m.reasoningContent, !r.isEmpty {
                    reasoning += TokenEstimator.estimate(r)
                }
                for c in m.toolCalls {
                    toolCallArgs += TokenEstimator.estimate(c.name) + TokenEstimator.estimate(c.arguments)
                }
                assistantCount += 1
            case .tool:
                tools += TokenEstimator.estimate(m.content)
                toolCount += 1
            }
        }

        assistant += TokenEstimator.estimate(streamingContent)

        let cats: [Category] = [
            .init(id: "system", label: "System prompt", tokens: system,
                  detail: system > 0 ? "Instructions + project rules" : ""),
            .init(id: "user", label: "Your messages", tokens: user,
                  detail: userCount == 0 ? "" : "\(userCount) message\(userCount == 1 ? "" : "s")"),
            .init(id: "assistant", label: "Assistant replies", tokens: assistant,
                  detail: assistantCount == 0 ? "" : "\(assistantCount) message\(assistantCount == 1 ? "" : "s")"),
            .init(id: "reasoning", label: "Thinking / reasoning", tokens: reasoning,
                  detail: reasoning > 0 ? "Model internal monologue" : ""),
            .init(id: "tools", label: "Tool results", tokens: tools,
                  detail: toolCount == 0 ? "" : "\(toolCount) result\(toolCount == 1 ? "" : "s")"),
            .init(id: "tool_calls", label: "Tool call args", tokens: toolCallArgs,
                  detail: toolCallArgs > 0 ? "Outgoing tool invocations" : ""),
        ].filter { $0.tokens > 0 }

        let total = cats.reduce(0) { $0 + $1.tokens }
        return ContextUsageBreakdown(
            categories: cats,
            totalTokens: total,
            budgetTokens: budgetTokens,
            windowTokens: windowTokens,
            compactThresholdPercent: compactThresholdPercent
        )
    }
}
