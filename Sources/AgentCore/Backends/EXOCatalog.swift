//
//  EXOCatalog.swift
//  AgentCore
//
//  EXO's model catalog (GET /models) plus the pooled-memory fit math that
//  powers the Cluster pane's "what can this cluster run" browser.
//
//  EXO returns an OpenAI-style envelope: { "data": [ { id, name, family,
//  quantization, base_model, context_length, capabilities,
//  storage_size_megabytes, is_custom, ... }, ... ] }. The downloaded subset
//  comes from GET /models?status=downloaded (there is no per-item flag).
//
//  storage_size_megabytes is MiB (model-weights size / 1024^2) — the same
//  units as ClusterTopology.pooledMemoryGB (ramTotal / 1024^3), so the fit
//  comparison is apples-to-apples.
//

import Foundation

/// One entry in EXO's model catalog, enriched with downloaded status.
public struct EXOCatalogModel: Sendable, Equatable, Identifiable {
    public let id: String              // "mlx-community/MiniMax-M2.7-4bit"
    public let name: String            // "MiniMax-M2.7-4bit"
    public let family: String?         // "minimax"
    public let quantization: String?   // "4bit"
    public let baseModel: String?      // "MiniMax M2.7"
    public let contextLength: Int?
    public let capabilities: [String]  // ["text","thinking"]
    public let storageMB: Int?         // storage_size_megabytes (MiB)
    public let isCustom: Bool
    public let downloaded: Bool

    public init(id: String, name: String, family: String?, quantization: String?,
                baseModel: String?, contextLength: Int?, capabilities: [String],
                storageMB: Int?, isCustom: Bool, downloaded: Bool) {
        self.id = id
        self.name = name
        self.family = family
        self.quantization = quantization
        self.baseModel = baseModel
        self.contextLength = contextLength
        self.capabilities = capabilities
        self.storageMB = storageMB
        self.isCustom = isCustom
        self.downloaded = downloaded
    }

    /// Weights size in binary GB (GiB) — comparable to pooled cluster memory.
    public var storageGB: Double? {
        storageMB.map { Double($0) / 1024.0 }
    }

    /// Display label without the HF org prefix: "mlx-community/Foo" → "Foo".
    public var shortName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}

/// How a model's memory footprint relates to the cluster's pooled RAM.
/// A pure, testable verdict used to badge catalog rows. Deliberately
/// conservative: weights must leave headroom for KV cache + activations,
/// so "fits" requires the model to sit under ~90% of pooled memory.
public enum ClusterFit: String, Sendable, Equatable {
    case fits      // comfortably within pooled memory
    case tight     // would load but leaves little headroom
    case exceeds   // larger than the whole pool — cannot run here
    case unknown   // size or pooled memory not reported

    /// - Parameters:
    ///   - modelGB: model weights size in GiB (nil → `.unknown`)
    ///   - pooledGB: cluster pooled memory in GiB (0 → `.unknown`)
    public static func evaluate(modelGB: Double?, pooledGB: Int) -> ClusterFit {
        guard let modelGB, pooledGB > 0 else { return .unknown }
        let pooled = Double(pooledGB)
        if modelGB > pooled { return .exceeds }
        if modelGB > pooled * 0.9 { return .tight }
        return .fits
    }
}

// MARK: - Wire DTOs (GET /models)

/// OpenAI-style envelope returned by EXO's /models.
struct EXOModelsResponseDTO: Decodable {
    let data: [EXOModelDTO]
}

/// One model descriptor as it appears on the wire. Decoded with
/// `.convertFromSnakeCase`, so `storage_size_megabytes` → `storageSizeMegabytes`.
/// Every field optional except `id` so catalog drift can't break the list.
struct EXOModelDTO: Decodable {
    let id: String
    let name: String?
    let family: String?
    let quantization: String?
    let baseModel: String?
    let contextLength: Int?
    let capabilities: [String]?
    let storageSizeMegabytes: Int?
    let isCustom: Bool?
}
