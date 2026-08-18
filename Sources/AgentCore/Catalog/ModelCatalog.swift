//
//  ModelCatalog.swift
//
//  Curated model entries. We keep one struct for GGUF and one for MLX —
//  same field shape so the UI can render them uniformly, but separate
//  arrays because download semantics differ (split-file GGUF vs.
//  HF-cache layout for MLX).
//
//  Catalog is loaded from a bundled JSON at app launch and overlaid by
//  `https://agentos.tools/catalog.json` (stale-while-revalidate). P0
//  ships the bundled JSON with a small seed set; P2 wires the fetcher.
//

import Foundation

public struct ModelCatalog: Codable, Sendable {
    public var gguf: [GGUFEntry]
    public var mlx: [MLXEntry]
    public var version: String

    public init(gguf: [GGUFEntry] = [], mlx: [MLXEntry] = [], version: String = "0") {
        self.gguf = gguf; self.mlx = mlx; self.version = version
    }
}

public struct GGUFEntry: Codable, Sendable, Identifiable {
    public var id: String { repoId + "::" + ggufFile }
    public let displayName: String
    public let repoId: String              // "unsloth/Qwen2.5-Coder-32B-Instruct-GGUF"
    public let ggufFile: String            // first part for split-file models
    public let splitFileParts: Int         // 1 = single, >1 = number of parts
    public let downloadGB: Double
    public let minRAMGB: Int
    public let parameterCountB: Double
    public let toolCapable: Bool
    public let defaultContextLength: Int
    public let maxContextLength: Int
    public let recommendedSampling: SamplingParams
    public let stopSequences: [String]
}

public struct MLXEntry: Codable, Sendable, Identifiable {
    public var id: String { repoId }
    public let displayName: String
    public let repoId: String              // "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"
    public let downloadGB: Double
    public let minRAMGB: Int
    public let parameterCountB: Double
    public let toolCapable: Bool
    public let defaultContextLength: Int
    public let maxContextLength: Int
    public let recommendedSampling: SamplingParams
}

public enum ModelCatalogLoader {

    /// Historical seed. GGUF rows are empty: bundled llama.cpp is removed,
    /// and the chat picker used to surface these filenames as selectable
    /// Ollama models (they are not Ollama tags).
    public static func seed() -> ModelCatalog {
        ModelCatalog(
            gguf: [],
            mlx: [
                MLXEntry(
                    displayName: "Qwen2.5-Coder 7B Instruct (MLX 4bit)",
                    repoId: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                    downloadGB: 4.2,
                    minRAMGB: 10,
                    parameterCountB: 7,
                    toolCapable: true,
                    defaultContextLength: 32768,
                    maxContextLength: 131072,
                    recommendedSampling: .coder
                ),
                MLXEntry(
                    displayName: "Qwen2.5-Coder 32B Instruct (MLX 4bit)",
                    repoId: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",
                    downloadGB: 17.5,
                    minRAMGB: 36,
                    parameterCountB: 32,
                    toolCapable: true,
                    defaultContextLength: 32768,
                    maxContextLength: 131072,
                    recommendedSampling: .coder
                ),
                // Qwen3 family (small efficient models for local use / language models section)
                MLXEntry(
                    displayName: "Qwen3 0.6B (MLX 4bit)",
                    repoId: "mlx-community/Qwen3-0.6B-4bit",
                    downloadGB: 0.4,
                    minRAMGB: 4,
                    parameterCountB: 0.6,
                    toolCapable: true,
                    defaultContextLength: 32768,
                    maxContextLength: 131072,
                    recommendedSampling: .small
                ),
                MLXEntry(
                    displayName: "Qwen3 1.7B (MLX 4bit)",
                    repoId: "mlx-community/Qwen3-1.7B-4bit",
                    downloadGB: 1.0,
                    minRAMGB: 6,
                    parameterCountB: 1.7,
                    toolCapable: true,
                    defaultContextLength: 32768,
                    maxContextLength: 131072,
                    recommendedSampling: .small
                ),
                MLXEntry(
                    displayName: "Qwen3 4B (MLX 4bit)",
                    repoId: "mlx-community/Qwen3-4B-4bit",
                    downloadGB: 2.3,
                    minRAMGB: 8,
                    parameterCountB: 4.0,
                    toolCapable: true,
                    defaultContextLength: 32768,
                    maxContextLength: 131072,
                    recommendedSampling: .medium
                ),
            ],
            version: "p0-seed+qwen3-no-gguf"
        )
    }
}
