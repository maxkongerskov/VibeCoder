//
//  MLXModelCatalog.swift
//
//  **NOT SURFACED IN v1.** MLX inference is paused per ROADMAP P2.
//  This file is retained so the v1.1 re-enable is a UI-only change
//  (restore the picker entry in ConnectionSettingsView, restore the
//  catalog loop in ModelsLandingView). The catalog data remains
//  accurate; nothing in the v1 app reads it.
//
//  Original docstring follows ↓
//
//  Curated MLX model entries for the in-process MLX backend. Ported from
//  the DEV PLAN's `CuratedMLXModel` + `MLXModelCatalog` enum into
//  AgentCore as `CuratedMLXEntry` + `CuratedMLXCatalog` so it does NOT
//  shadow the simpler `MLXEntry` already defined in `ModelCatalog.swift`.
//
//  SamplingDefaults lives here (was shared with removed GGUF catalog).
//

import Foundation

/// Author-published sampling defaults for curated catalog entries.
public struct SamplingDefaults: Hashable, Sendable, Codable {
    public let temperature: Double
    public let topP: Double
    public let topK: Int
    public let repeatPenalty: Double

    public init(temperature: Double, topP: Double, topK: Int, repeatPenalty: Double) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
    }
}

/// One curated, downloadable MLX model. Renamed from the DEV PLAN's
/// `CuratedMLXModel` to `CuratedMLXEntry` to avoid shadowing the
/// existing `MLXEntry`.
public struct CuratedMLXEntry: Identifiable, Hashable, Sendable, Codable {
    /// Hugging Face repo id, e.g. "mlx-community/Qwen3-Coder-Next-8bit".
    /// Stored as the selected model id; MUST match the repo exactly.
    public let repoId: String
    /// Human-facing name for the picker.
    public let displayName: String
    /// Approx parameter count in billions.
    public let paramsB: Double
    /// Quantisation label as published.
    public let quant: String
    /// On-disk download size in GB.
    public let downloadGB: Double
    /// Minimum total system RAM (GB) recommended for this model.
    public let minRAMGB: Int
    /// Does this model follow tool-calling protocols?
    public let toolCapable: Bool
    /// May the hardware-based auto-recommendation surface this entry?
    public var recommendable: Bool
    /// One-line description for the picker.
    public let blurb: String

    /// Maximum context window the model can handle.
    public var maxContextLength: Int
    /// Default ctx-size at first activation (= maxContextLength).
    public var defaultContextLength: Int
    /// Author-published sampling parameters; nil falls back to globals.
    public var samplingDefaults: SamplingDefaults?
    /// Family-specific stop tokens.
    public var stopSequences: [String]

    public var id: String { repoId }

    public init(repoId: String,
                displayName: String,
                paramsB: Double,
                quant: String,
                downloadGB: Double,
                minRAMGB: Int,
                toolCapable: Bool,
                recommendable: Bool = true,
                blurb: String,
                maxContextLength: Int = 32_768,
                defaultContextLength: Int = 32_768,
                samplingDefaults: SamplingDefaults? = nil,
                stopSequences: [String] = []) {
        self.repoId = repoId
        self.displayName = displayName
        self.paramsB = paramsB
        self.quant = quant
        self.downloadGB = downloadGB
        self.minRAMGB = minRAMGB
        self.toolCapable = toolCapable
        self.recommendable = recommendable
        self.blurb = blurb
        self.maxContextLength = maxContextLength
        self.defaultContextLength = defaultContextLength
        self.samplingDefaults = samplingDefaults
        self.stopSequences = stopSequences
    }
}

/// Curated MLX catalog. Renamed from DEV PLAN's `MLXModelCatalog`
/// because `ModelCatalog` already owns the lean JSON-driven shape.
public enum CuratedMLXCatalog {

    /// Curated set as of 2026-06-01. Arch-verified against the
    /// mlx-swift-lm registry.
    public static let all: [CuratedMLXEntry] = [
        // Small Qwen3 (seed catalog) — 8–16GB Macs. Without these,
        // recommended() can only offer 24GB+ entries.
        CuratedMLXEntry(
            repoId: "mlx-community/Qwen3-0.6B-4bit",
            displayName: "Qwen3 0.6B (4-bit)",
            paramsB: 0.6, quant: "4-bit", downloadGB: 0.4, minRAMGB: 4,
            toolCapable: true, recommendable: true,
            blurb: "Tiny local Qwen3 · fits 8GB machines",
            maxContextLength: 131072,
            defaultContextLength: 32768,
            samplingDefaults: SamplingDefaults(temperature: 0.7, topP: 0.8, topK: 20, repeatPenalty: 1.05),
            stopSequences: ["<|im_end|>"]),
        CuratedMLXEntry(
            repoId: "mlx-community/Qwen3-1.7B-4bit",
            displayName: "Qwen3 1.7B (4-bit)",
            paramsB: 1.7, quant: "4-bit", downloadGB: 1.0, minRAMGB: 6,
            toolCapable: true, recommendable: true,
            blurb: "Small local Qwen3 · fits 8–16GB Macs",
            maxContextLength: 131072,
            defaultContextLength: 32768,
            samplingDefaults: SamplingDefaults(temperature: 0.7, topP: 0.8, topK: 20, repeatPenalty: 1.05),
            stopSequences: ["<|im_end|>"]),
        CuratedMLXEntry(
            repoId: "mlx-community/Qwen3-4B-4bit",
            displayName: "Qwen3 4B (4-bit)",
            paramsB: 4.0, quant: "4-bit", downloadGB: 2.3, minRAMGB: 8,
            toolCapable: true, recommendable: true,
            blurb: "Compact local Qwen3 · tool-capable, fits 16GB Macs",
            maxContextLength: 131072,
            defaultContextLength: 32768,
            samplingDefaults: SamplingDefaults(temperature: 0.7, topP: 0.8, topK: 20, repeatPenalty: 1.05),
            stopSequences: ["<|im_end|>"]),

        // Qwen 3.6 27B (Alibaba, 2026-04) — dense w/ vision
        CuratedMLXEntry(
            repoId: "lmstudio-community/Qwen3.6-27B-MLX-4bit",
            displayName: "Qwen 3.6 27B (4-bit)",
            paramsB: 27, quant: "4-bit", downloadGB: 13.5, minRAMGB: 24,
            toolCapable: true, recommendable: true,
            blurb: "Alibaba's 27B with vision · 262K context, strong reasoning + tool use",
            maxContextLength: 262144,
            defaultContextLength: 262144,
            samplingDefaults: SamplingDefaults(temperature: 0.7, topP: 0.8, topK: 20, repeatPenalty: 1.05),
            stopSequences: ["<|im_end|>"]),

        // Qwen 3.6 35B-A3B MoE (Alibaba, 2026-04)
        CuratedMLXEntry(
            repoId: "lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit",
            displayName: "Qwen 3.6 35B-A3B MoE (4-bit)",
            paramsB: 35, quant: "4-bit", downloadGB: 17.5, minRAMGB: 32,
            toolCapable: true, recommendable: true,
            blurb: "Alibaba's 35B/3B-active MoE · vision + tool + 262K context",
            maxContextLength: 262144,
            defaultContextLength: 262144,
            samplingDefaults: SamplingDefaults(temperature: 0.7, topP: 0.8, topK: 20, repeatPenalty: 1.05),
            stopSequences: ["<|im_end|>"]),
        CuratedMLXEntry(
            repoId: "lmstudio-community/Qwen3.6-35B-A3B-MLX-6bit",
            displayName: "Qwen 3.6 35B-A3B MoE (6-bit)",
            paramsB: 35, quant: "6-bit", downloadGB: 26.0, minRAMGB: 40,
            toolCapable: true,
            blurb: "Alibaba's 35B/3B-active MoE · vision + tool + 262K context",
            maxContextLength: 262144,
            defaultContextLength: 262144,
            samplingDefaults: SamplingDefaults(temperature: 0.7, topP: 0.8, topK: 20, repeatPenalty: 1.05),
            stopSequences: ["<|im_end|>"]),
        CuratedMLXEntry(
            repoId: "lmstudio-community/Qwen3.6-35B-A3B-MLX-8bit",
            displayName: "Qwen 3.6 35B-A3B MoE (8-bit)",
            paramsB: 35, quant: "8-bit MLX", downloadGB: 34.0, minRAMGB: 56,
            toolCapable: true,
            blurb: "Alibaba's 35B/3B-active MoE · vision + tool + 262K context",
            maxContextLength: 262144,
            defaultContextLength: 262144,
            samplingDefaults: SamplingDefaults(temperature: 0.7, topP: 0.8, topK: 20, repeatPenalty: 1.05),
            stopSequences: ["<|im_end|>"]),

        // Gemma 4 31B (Google, 2026-04) — vision-capable
        CuratedMLXEntry(
            repoId: "lmstudio-community/gemma-4-31B-it-MLX-4bit",
            displayName: "Gemma 4 31B (4-bit)",
            paramsB: 31, quant: "4-bit", downloadGB: 15.5, minRAMGB: 24,
            toolCapable: true, recommendable: true,
            blurb: "Google's vision-capable flagship · LiveCodeBench 80%, native tool calling",
            maxContextLength: 131072,
            defaultContextLength: 131072,
            samplingDefaults: SamplingDefaults(temperature: 1.0, topP: 0.95, topK: 64, repeatPenalty: 1.0),
            stopSequences: ["<end_of_turn>"]),
        CuratedMLXEntry(
            repoId: "lmstudio-community/gemma-4-31B-it-MLX-5bit",
            displayName: "Gemma 4 31B (5-bit)",
            paramsB: 31, quant: "5-bit", downloadGB: 19.4, minRAMGB: 32,
            toolCapable: true,
            blurb: "Google's vision-capable flagship · LiveCodeBench 80%, native tool calling",
            maxContextLength: 131072,
            defaultContextLength: 131072,
            samplingDefaults: SamplingDefaults(temperature: 1.0, topP: 0.95, topK: 64, repeatPenalty: 1.0),
            stopSequences: ["<end_of_turn>"]),
        CuratedMLXEntry(
            repoId: "lmstudio-community/gemma-4-31B-it-MLX-6bit",
            displayName: "Gemma 4 31B (6-bit)",
            paramsB: 31, quant: "6-bit", downloadGB: 23.3, minRAMGB: 40,
            toolCapable: true,
            blurb: "Google's vision-capable flagship · LiveCodeBench 80%, native tool calling",
            maxContextLength: 131072,
            defaultContextLength: 131072,
            samplingDefaults: SamplingDefaults(temperature: 1.0, topP: 0.95, topK: 64, repeatPenalty: 1.0),
            stopSequences: ["<end_of_turn>"]),
        CuratedMLXEntry(
            repoId: "lmstudio-community/gemma-4-31B-it-MLX-8bit",
            displayName: "Gemma 4 31B (8-bit)",
            paramsB: 31, quant: "8-bit MLX", downloadGB: 31.0, minRAMGB: 48,
            toolCapable: true,
            blurb: "Google's vision-capable flagship · LiveCodeBench 80%, native tool calling",
            maxContextLength: 131072,
            defaultContextLength: 131072,
            samplingDefaults: SamplingDefaults(temperature: 1.0, topP: 0.95, topK: 64, repeatPenalty: 1.0),
            stopSequences: ["<end_of_turn>"]),

        // Qwen3-Coder-Next 80B MoE (Alibaba, 2026-02)
        CuratedMLXEntry(
            repoId: "mlx-community/Qwen3-Coder-Next-8bit",
            displayName: "Qwen3-Coder-Next 80B (8-bit)",
            paramsB: 80, quant: "8-bit MLX", downloadGB: 84.7, minRAMGB: 96,
            toolCapable: true, recommendable: false,
            blurb: "Strongest open coder · 80B/3B-active MoE, agent-grade tool use",
            maxContextLength: 262144,
            defaultContextLength: 262144,
            samplingDefaults: SamplingDefaults(temperature: 0.7, topP: 0.8, topK: 20, repeatPenalty: 1.05),
            stopSequences: ["<|im_end|>"]),
    ]

    /// Default when no hardware-based recommendation is available.
    public static let defaultRepoId = "lmstudio-community/gemma-4-31B-it-MLX-4bit"

    /// Look up a curated entry by its repo id.
    public static func model(forRepoId id: String) -> CuratedMLXEntry? {
        all.first { $0.repoId == id }
    }

    /// Pick the most capable catalog model that comfortably fits the
    /// given total system RAM. Never prefers a model whose `minRAMGB`
    /// exceeds `ram` when a smaller entry exists. If nothing fits,
    /// return the smallest-RAM catalog entry (do not pretend it fits).
    public static func recommended(forSystemRAMGB ram: Int) -> CuratedMLXEntry {
        let candidates = all.filter { $0.toolCapable && $0.recommendable }
        let fits = candidates.filter { $0.minRAMGB <= ram }
        if let best = fits.max(by: { $0.paramsB < $1.paramsB }) { return best }
        if let smallest = all.min(by: { $0.minRAMGB < $1.minRAMGB }) { return smallest }
        return candidates.min(by: { $0.paramsB < $1.paramsB }) ?? all[0]
    }
}
