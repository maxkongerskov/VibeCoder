//
//  ThinkingCapability.swift
//
//  Thinking / reasoning effort detection for OpenAI-compatible local models.
//  Ported from BuildCode's ModelCapabilities scanner (which itself mirrors
//  z.ai's agent UX), adapted for VibeCoder's local-LLM-first architecture.
//
//  Most OpenAI-compatible servers (llama.cpp, LM Studio, EXO) do NOT
//  advertise thinking support in their /v1/models response — so we scan
//  the model id against known reasoning-family patterns. Unknown models
//  return nil, which hides the thinking-effort picker in the input card.
//
//  Four encoding styles are supported, matching how each model family
//  expects the thinking parameter in the HTTP request body:
//
//    1. openaiReasoningEffort — top-level `reasoning_effort: "low"|"medium"|…`
//       (OpenAI o-series, GPT-5, DeepSeek-R1, QwQ, Grok)
//    2. glmThinking — `thinking: { type:"enabled" }` + `reasoning_effort`
//       (GLM-5.x / z.ai style)
//    3. anthropicBudget — `thinking: { type, budget_tokens }` (Claude)
//    4. openaiReasoningObject — nested `reasoning: { effort }` (some GPT-5 stacks)
//

import Foundation

// MARK: - ThinkingEffort

/// How hard the model should "think" when the backend supports it.
public enum ThinkingEffort: String, CaseIterable, Identifiable, Sendable, Codable {
    case off
    case low
    case medium
    case high
    case max

    public var id: String { rawValue }

    /// Human-readable label for the picker menu.
    public var title: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .max: "Max"
        }
    }

    /// Short label for the chip display (e.g. "Think high").
    public var shortTitle: String {
        switch self {
        case .off: "Think off"
        case .low: "Think low"
        case .medium: "Think med"
        case .high: "Think high"
        case .max: "Think max"
        }
    }

    /// SF Symbol name for the effort level. Kept as a String so
    /// AgentCore stays UI-framework-free; the App target maps to SwiftUI.
    public var iconName: String {
        switch self {
        case .off: "brain"
        case .low: "brain.head.profile"
        case .medium: "brain.head.profile"
        case .high: "brain.head.profile.fill"
        case .max: "sparkles"
        }
    }

    /// OpenAI-style `reasoning_effort` value (nil = omit / off).
    public var openaiEffortValue: String? {
        switch self {
        case .off: "none"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .max: "max"
        }
    }
}

// MARK: - ThinkingAPIStyle

/// How we encode thinking into the HTTP request body for a given model family.
public enum ThinkingAPIStyle: String, Sendable, Codable {
    /// Top-level `reasoning_effort: "low"|"medium"|…` (OpenAI o-series, GPT-5)
    case openaiReasoningEffort
    /// Nested `reasoning: { "effort": "…" }` (Responses API / some GPT-5 stacks)
    case openaiReasoningObject
    /// GLM / z.ai style: `thinking: { type }` + optional `reasoning_effort`
    case glmThinking
    /// Anthropic extended thinking with token budget (Claude 4 / 3.7)
    case anthropicBudget
}

// MARK: - ThinkingCapability

/// Describes a model's thinking support: which API style to use, which
/// effort levels are valid, the default level, and a human label.
public struct ThinkingCapability: Sendable, Equatable {
    public let style: ThinkingAPIStyle
    public let levels: [ThinkingEffort]
    public let defaultLevel: ThinkingEffort
    /// Human label for UI (e.g. "Reasoning", "Thinking")
    public let label: String

    public var isSupported: Bool { !levels.isEmpty }

    /// Clamp a user-chosen effort to the levels this model supports.
    public func clamp(_ effort: ThinkingEffort) -> ThinkingEffort {
        if levels.contains(effort) { return effort }
        if levels.contains(defaultLevel) { return defaultLevel }
        return levels.first ?? .off
    }

    public init(style: ThinkingAPIStyle, levels: [ThinkingEffort],
                defaultLevel: ThinkingEffort, label: String) {
        self.style = style
        self.levels = levels
        self.defaultLevel = defaultLevel
        self.label = label
    }
}

// MARK: - ModelCapabilities (thinking scanner)

/// Scans model ids for thinking / reasoning support. Most OpenAI-compatible
/// servers do not advertise this in /v1/models, so we use known patterns.
/// Unknown models → nil (thinking picker stays hidden).
public enum ThinkingModelScanner {

    // Canonical level sets — never show a level the API family can't encode.
    // The brain menu only lists `capability.levels` for the active model.

    /// GLM / z.ai: thinking on|off; effort is high|max only (no low/medium).
    private static let glmLevels: [ThinkingEffort] = [.off, .high, .max]
    /// Classic OpenAI o-series: low / medium / high (no off on many stacks).
    private static let oSeriesLevels: [ThinkingEffort] = [.low, .medium, .high]
    /// Newer GPT-5 / OSS stacks that accept off + max / xhigh.
    private static let gpt5FullLevels: [ThinkingEffort] = [.off, .low, .medium, .high, .max]
    /// DeepSeek / generic OpenAI-compatible reasoners.
    private static let openAIFullLevels: [ThinkingEffort] = [.off, .low, .medium, .high, .max]
    /// Qwen3 / QwQ: four steps, no max on most local servers.
    private static let qwenLevels: [ThinkingEffort] = [.off, .low, .medium, .high]
    /// xAI Grok reasoning: no off (always reasons at some level).
    private static let grokLevels: [ThinkingEffort] = [.low, .medium, .high, .max]
    /// Anthropic budget ladder.
    private static let claudeLevels: [ThinkingEffort] = [.off, .low, .medium, .high, .max]
    /// MiniMax local dumps — medium ladder, no max required.
    private static let minimaxLevels: [ThinkingEffort] = [.off, .low, .medium, .high]

    /// Detect thinking support for a model id. Returns nil if the model
    /// is not recognised as a reasoning/thinking model.
    ///
    /// `levels` are **that family's** supported efforts only — the input-card
    /// brain menu must not list Low/Med for GLM or Off for Grok, etc.
    public static func detect(modelId: String) -> ThinkingCapability? {
        // Normalize HF paths / file paths so "…/GLM-5.2-mxfp4" still matches.
        let id = normalizeModelId(modelId)
        guard !id.isEmpty else { return nil }

        // --- GLM / z.ai (GLM-5.x, GLM-4.5+ MoE). ChatGLM-3/4 are not this API. ---
        // API: thinking { type } + reasoning_effort high|max only.
        if matches(id, anyOf: [
            "glm-5", "glm5", "glm_5", "glm-4.5", "glm-4.6", "glm-4.7",
            "glm-moe", "glm_moe", "glm-4-moe",
        ]) {
            return ThinkingCapability(
                style: .glmThinking,
                levels: glmLevels,
                defaultLevel: .high,
                label: "Thinking")
        }

        // --- MiniMax reasoners (M1/M2/M3). Text-01 is plain chat. ---
        if matches(id, anyOf: ["minimax-m1", "minimax-m2", "minimax-m3", "mini-max-m"]) {
            return ThinkingCapability(
                style: .openaiReasoningEffort,
                levels: minimaxLevels,
                defaultLevel: .medium,
                label: "Thinking")
        }

        // --- OpenAI o-series / GPT-5 / codex ---
        if matches(id, anyOf: ["o1", "o3", "o4", "gpt-5", "gpt5",
                                 "gpt-oss", "codex"]) {
            let full = matches(id, anyOf: [
                "gpt-5.1", "gpt-5.2", "gpt-5.5", "gpt-5.4", "xhigh", "oss",
            ])
            return ThinkingCapability(
                style: .openaiReasoningEffort,
                levels: full ? gpt5FullLevels : oSeriesLevels,
                defaultLevel: .medium,
                label: "Reasoning")
        }

        // --- DeepSeek reasoners ---
        if matches(id, anyOf: ["deepseek-r1", "deepseek-reasoner",
                                 "deepseek-v4", "r1-"]) {
            return ThinkingCapability(
                style: .openaiReasoningEffort,
                levels: openAIFullLevels,
                defaultLevel: .medium,
                label: "Thinking")
        }

        // --- Qwen / QwQ thinking variants (not plain qwen2.5 instruct,
        //     and not official Qwen3-*-Instruct-2507 non-thinking dumps) ---
        let isQwen3Instruct2507 = id.contains("qwen3")
            && id.contains("instruct")
            && id.contains("2507")
        if !isQwen3Instruct2507
            && (matches(id, anyOf: ["qwq", "qwen3"])
                || (id.contains("qwen") && id.contains("think")))
        {
            return ThinkingCapability(
                style: .openaiReasoningEffort,
                levels: qwenLevels,
                defaultLevel: .medium,
                label: "Thinking")
        }

        // --- Grok reasoning ids (xAI) ---
        if matches(id, anyOf: ["grok-3", "grok-4", "grok-4.5", "grok-4-1", "grok-reason"]) {
            return ThinkingCapability(
                style: .openaiReasoningEffort,
                levels: grokLevels,
                defaultLevel: .high,
                label: "Reasoning")
        }

        // --- Claude extended thinking (3.7 / 4+ only; 3.5 / 3 Opus / 3 Sonnet
        //     reject thinking.budget_tokens with HTTP 400) ---
        if matches(id, anyOf: [
            "claude-sonnet-4", "claude-opus-4", "claude-haiku-4",
            "claude-3-7", "claude-3.7",
            "claude-4-", "claude-4.",
        ]) || id.hasSuffix("claude-4") || id.contains("claude4") {
            return ThinkingCapability(
                style: .anthropicBudget,
                levels: claudeLevels,
                defaultLevel: .medium,
                label: "Thinking")
        }

        // --- oMLX quant dumps: inherit the family table, not a full ladder ---
        if matches(id, anyOf: ["mxfp4", "mxfp8"]) {
            if matches(id, anyOf: ["glm"]) {
                return ThinkingCapability(
                    style: .glmThinking,
                    levels: glmLevels,
                    defaultLevel: .high,
                    label: "Thinking")
            }
            if matches(id, anyOf: ["qwen", "qwq"]) {
                return ThinkingCapability(
                    style: .openaiReasoningEffort,
                    levels: qwenLevels,
                    defaultLevel: .medium,
                    label: "Thinking")
            }
            if matches(id, anyOf: ["deepseek", "r1"]) {
                return ThinkingCapability(
                    style: .openaiReasoningEffort,
                    levels: openAIFullLevels,
                    defaultLevel: .medium,
                    label: "Thinking")
            }
        }

        // --- Generic: id literally says reason/think — full OpenAI ladder ---
        if id.contains("reason") || id.contains("think") {
            return ThinkingCapability(
                style: .openaiReasoningEffort,
                levels: openAIFullLevels,
                defaultLevel: .medium,
                label: "Thinking")
        }

        // Non-reasoning models → nil → brain chip hidden entirely.
        return nil
    }

    /// Lowercase + last path/repo segment so HF / folder ids still match.
    private static func normalizeModelId(_ modelId: String) -> String {
        var s = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.contains("/") {
            s = s.split(separator: "/").map(String.init).last ?? s
        }
        // File-ish suffixes sometimes appear in local catalogs.
        for ext in [".gguf", ".safetensors", ".bin", ".mlx"] {
            if s.hasSuffix(ext) { s = String(s.dropLast(ext.count)) }
        }
        return s
    }

    /// Merge thinking parameters into an OpenAI-compatible JSON request body.
    /// Called by the backend's encode step right before sending.
    public static func applyThinking(
        to body: inout [String: Any],
        capability: ThinkingCapability,
        effort: ThinkingEffort
    ) {
        let level = capability.clamp(effort)
        switch capability.style {
        case .openaiReasoningEffort:
            if let value = level.openaiEffortValue {
                // Some stacks want omission for off; send "none" when supported
                if level == .off && !capability.levels.contains(.off) {
                    return
                }
                body["reasoning_effort"] = value
            }
        case .openaiReasoningObject:
            if level == .off {
                body["reasoning"] = ["effort": "none"]
            } else if let value = level.openaiEffortValue {
                body["reasoning"] = ["effort": value]
            }
        case .glmThinking:
            // GLM-5.x: only Off / High / Max are real. Never send low|medium.
            if level == .off {
                body["thinking"] = ["type": "disabled"]
            } else {
                body["thinking"] = ["type": "enabled"]
                switch level {
                case .max:
                    body["reasoning_effort"] = "max"
                case .high, .medium, .low:
                    // Medium/low should already be clamped out; map safely to high.
                    body["reasoning_effort"] = "high"
                case .off:
                    break
                }
            }
        case .anthropicBudget:
            guard level != .off else { return }
            let budget: Int
            switch level {
            case .low: budget = 2_048
            case .medium: budget = 8_192
            case .high: budget = 16_384
            case .max: budget = 32_768
            default: fatalError("ThinkingLevel(rawValue:) produced unknown case")
            }
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": budget
            ]
        }
    }

    private static func matches(_ id: String, anyOf needles: [String]) -> Bool {
        needles.contains { id.contains($0) }
    }
}

// MARK: - Catalog helper (scan a list of models)

public extension ThinkingModelScanner {
    /// Mark which catalog models support thinking (for settings / model pickers).
    static func scan(models: [String]) -> [(id: String, capability: ThinkingCapability)] {
        models.compactMap { id in
            guard let cap = detect(modelId: id) else { return nil }
            return (id, cap)
        }
    }
}