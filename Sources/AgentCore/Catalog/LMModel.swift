//
//  LMModel.swift
//
//  A lightweight, persisted "user has picked this model" reference. Distinct
//  from `ModelDescriptor` (which is the rich, runtime-discovered shape returned
//  by a backend's `/v1/models` probe) — `LMModel` is the slim id + provenance
//  pair that survives in `AppSettings` and conversation files.
//
//  Capability inference is keyword-driven on the model id. This is
//  intentionally fuzzy: backends don't reliably advertise tool/vision/
//  reasoning support, and matching against a curated keyword list gives us
//  a usable signal without baking a per-model table into the package.
//
//  Ported pure: no SwiftUI imports. The original `color` property on
//  `ModelCapability` is dropped — the App target re-adds visuals via its
//  own colour palette.
//

import Foundation

// MARK: - Model capability

public enum ModelCapability: String, CaseIterable, Identifiable, Sendable, Codable {
    case toolCalling = "Tools"
    case reasoning   = "Reasoning"
    case vision      = "Vision"
    case longContext = "128K+"

    public var id: String { rawValue }

    /// SF Symbol name. Returned as a String so AgentCore stays UI-framework-free.
    public var icon: String {
        switch self {
        case .toolCalling: return "wrench.and.screwdriver"
        case .reasoning:   return "brain"
        case .vision:      return "eye"
        case .longContext: return "doc.text.magnifyingglass"
        }
    }
}

// MARK: - Model

public struct LMModel: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    /// Which backend served this model in the multi-backend probe.
    /// Optional because (a) persisted state from older builds didn't carry it
    /// and (b) MLX / catalog-synthesised entries don't always fit a single backend.
    public var backendSource: BackendIdentifier?

    enum CodingKeys: String, CodingKey { case id, backendSource }

    public init(id: String, backendSource: BackendIdentifier? = nil) {
        self.id = id
        self.backendSource = backendSource
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.backendSource = try c.decodeIfPresent(BackendIdentifier.self, forKey: .backendSource)
    }

    public var displayName: String {
        id.components(separatedBy: "/").last ?? id
    }

    /// Whether we expect this model to handle tool-calling JSON schemas.
    public var probablySupportsTools: Bool {
        let l = id.lowercased()
        return toolCapableKeywords.contains { l.contains($0) }
    }

    public var capabilities: [ModelCapability] {
        let l = id.lowercased()
        var caps: [ModelCapability] = []

        if toolCapableKeywords.contains(where: { l.contains($0) }) {
            caps.append(.toolCalling)
        }
        if reasoningKeywords.contains(where: { l.contains($0) }) {
            caps.append(.reasoning)
        }
        if visionKeywords.contains(where: { l.contains($0) })
            && !isLlama32TextOnly(l)
            && !isGemma3TextOnly(l) {
            caps.append(.vision)
        }
        if longContextKeywords.contains(where: { l.contains($0) }) {
            caps.append(.longContext)
        }
        return caps
    }
}

// MARK: - Keyword lists
//
// Backends like EXO serve full HuggingFace paths (e.g. "mlx-community/Qwen3-Coder-Next-bf16").
// displayName strips the org prefix; these keywords match against the full
// lowercased id so both "qwen3-coder" and "mlx-community/qwen3-coder" hit correctly.

private let toolCapableKeywords = [
    "mistral", "mixtral",
    "llama-3", "llama3",
    "qwen",                               // Qwen2, Qwen3, Qwen3-Coder, etc.
    "coder",                              // any *-Coder variant (Qwen3-Coder, DeepSeek-Coder…)
    "instruct",                           // most instruction-tuned models support tools
    "hermes", "functionary",
    "deepseek-v", "deepseek-coder",
    "command-r",
    "phi-3", "phi-4",
    "kimi", "nous", "openhermes",
    "dolphin", "gemma", "granite",
    "nemotron", "aya",
    "smollm", "internlm",
    "gpt-4", "gpt-5",                     // OpenAI frontier families
    "gpt-3.5", "gpt-35", "gpt3.5",        // original function-calling model
    "minimax",                            // MiniMax-Text-01 / M1 / M2 — tool-capable,
                                          // but emit <minimax:tool_call> XML in content.
]

private let reasoningKeywords = [
    // explicit reasoning families
    "qwq", "deepseek-r", "r1", "o1", "o3", "o4",
    "thinking", "reason", "reflect", "cot",
    "skywork-o", "marco-o", "lfm",
    "magistral",                          // Mistral's reasoning model
    "kimi-k2", "kimi-reason",
    "glm-4.5", "glm-4.6",
    // frontier closed/hybrid families with native reasoning
    "qwen3", "qwen3-coder",
    "claude", "sonnet", "opus", "haiku",
    "gpt-5",
    "gemini-2.5", "gemini-3",
    "grok-3", "grok-4",
    "gemma-3", "gemma3",
    "gemma-4", "gemma4",
    "minimax-m1", "minimax-m2",
]

private let visionKeywords = [
    "vision", "-vl", "vl-",
    "llava", "bakllava", "moondream", "minicpm-v",
    "cogvlm", "internvl", "idefics", "pixtral", "llava-next",
    "qwen2-vl", "qwen2.5-vl", "qwen3-vl",
    "qwen3.6", "qwen3.7", "qwen3.8",
    "qwen4",
    "llama-3.2", "llama3.2",
    "phi-3-vision", "phi-3.5-vision",
    "gemma-3", "gemma3",
    "gemma-4", "gemma4",
    "claude",
    "sonnet", "opus", "haiku",
    "gpt-4o", "gpt-4-turbo", "gpt-4v", "gpt-5",
    "gemini",
    "grok-2", "grok-3",
]

private let longContextKeywords = [
    "128k", "256k", "200k", "1m", "gemini", "claude", "longctx",
]

/// Llama 3.2 1B/3B Instruct are text-only; 11B/90B are the VL checkpoints.
private func isLlama32TextOnly(_ l: String) -> Bool {
    guard l.contains("llama-3.2") || l.contains("llama3.2") else { return false }
    if l.contains("11b") || l.contains("90b") || l.contains("vision") || l.contains("-vl") {
        return false
    }
    return hasParamSize(l, "1b") || hasParamSize(l, "3b")
}

/// Gemma 3 1B is text-only; 4B+ are multimodal.
private func isGemma3TextOnly(_ l: String) -> Bool {
    guard l.contains("gemma-3") || l.contains("gemma3") else { return false }
    return hasParamSize(l, "1b")
}

/// Match a parameter-size token (`1b`, `3b`) that is not a substring of `11b` / `13b`.
private func hasParamSize(_ l: String, _ size: String) -> Bool {
    l.range(of: "(^|[^0-9])\(size)([^0-9]|$)", options: .regularExpression) != nil
}

// MARK: - API response

/// Wire shape returned by `/v1/models` on any OpenAI-compatible backend.
public struct ModelsResponse: Codable, Sendable {
    public struct ModelItem: Codable, Sendable {
        public let id: String
        public init(id: String) { self.id = id }
    }
    public let data: [ModelItem]
    public init(data: [ModelItem]) { self.data = data }
}
