//
//  ModelContextLengthResolver.swift
//
//  Normalizes context-length fields from OpenAI-compatible `/v1/models`
//  responses and supplies known defaults for IDs that omit metadata.
//

import Foundation

public enum ModelContextLengthResolver {

    /// Max of advertised window fields. A smaller loaded `context_length`
    /// (e.g. Unsloth n_ctx 32k) must not beat native/max when those exist.
    /// Returns nil when every candidate is missing or non-positive — never
    /// invents a 1M window.
    public static func advertisedMax(
        nativeContextLength: Int? = nil,
        maxContextLength: Int? = nil,
        contextLength: Int? = nil,
        extra: [Int?] = []
    ) -> Int? {
        var best: Int?
        for candidate in [nativeContextLength, maxContextLength, contextLength] + extra {
            guard let n = candidate, n > 0 else { continue }
            best = max(best ?? n, n)
        }
        return best
    }

    /// Extract context length from a `/v1/models` item (OMLX/LM Studio/Unsloth).
    public static func fromAPIItem(_ item: [String: Any]) -> Int? {
        func intVal(_ key: String) -> Int? {
            if let n = item[key] as? Int, n > 0 { return n }
            if let n = item[key] as? Double, n > 0 { return Int(n) }
            return nil
        }
        if let n = advertisedMax(
            nativeContextLength: intVal("native_context_length") ?? intVal("nativeContextLength"),
            maxContextLength: intVal("max_context_length") ?? intVal("maxContextLength"),
            contextLength: intVal("context_length") ?? intVal("contextLength"),
            extra: [intVal("max_model_len"), intVal("maxModelLen")]
        ) {
            return n
        }
        if let meta = item["metadata"] as? [String: Any] {
            return fromAPIItem(meta)
        }
        return nil
    }

    /// Known native window when `/v1/models` omits metadata (or only reports a
    /// loaded n_ctx like 32k). Never a guess for unknown IDs.
    public static func knownContextLength(for modelId: String) -> Int? {
        let id = modelId.lowercased()
        if id.contains("glm-5.2") || id.contains("glm-5.1") || id.contains("glm-5") {
            return 256_000
        }
        if id.contains("qwen3-coder-next") || id.contains("qwen3.6") {
            return 262_144
        }
        if id.contains("gpt-oss-120b") || id.contains("gpt-oss") {
            return 131_072
        }
        if id.contains("minimax-m2") || id.contains("minimax-m3") {
            return 196_608
        }
        // NVIDIA Nemotron 3.5 Lightning: native 1M (Unsloth / NVIDIA cards).
        if id.contains("nemotron") && id.contains("lightning") {
            return 1_048_576
        }
        return nil
    }

    /// Prefer the larger of API advertised length and the known native window
    /// so a loaded 32k n_ctx does not replace Lightning's 1M model window.
    public static func resolve(modelId: String, apiValue: Int?) -> Int? {
        let known = knownContextLength(for: modelId)
        if let apiValue, apiValue > 0 {
            if let known { return max(apiValue, known) }
            return apiValue
        }
        return known
    }

    /// Loaded/effective n_ctx (Unsloth `context_length`) when present.
    /// Distinct from `advertisedMax` — a 32k load must not hide a 1M native/max.
    public static func loadedWindow(
        nativeContextLength: Int? = nil,
        maxContextLength: Int? = nil,
        contextLength: Int? = nil
    ) -> Int? {
        if let n = contextLength, n > 0 { return n }
        return advertisedMax(
            nativeContextLength: nativeContextLength,
            maxContextLength: maxContextLength,
            contextLength: nil)
    }

    /// Status/Settings/meter copy: never a lone loaded 32k when native/max is 1M.
    public static func honestyLabel(nativeMax: Int?, loaded: Int?) -> String {
        let n = (nativeMax ?? 0) > 0 ? nativeMax : nil
        let l = (loaded ?? 0) > 0 ? loaded : nil
        switch (n, l) {
        case let (n?, l?) where n != l:
            return "\(ContextUsageBreakdown.formatTokenCount(l)) loaded / \(ContextUsageBreakdown.formatTokenCount(n)) native"
        case let (n?, _):
            return ContextUsageBreakdown.formatTokenCount(n)
        case let (nil, l?):
            return ContextUsageBreakdown.formatTokenCount(l)
        default:
            return "unknown"
        }
    }

    public static func honestyLabel(fromAPIItem item: [String: Any]) -> String {
        func intVal(_ key: String) -> Int? {
            if let n = item[key] as? Int, n > 0 { return n }
            if let n = item[key] as? Double, n > 0 { return Int(n) }
            return nil
        }
        let nativeMax = advertisedMax(
            nativeContextLength: intVal("native_context_length") ?? intVal("nativeContextLength"),
            maxContextLength: intVal("max_context_length") ?? intVal("maxContextLength"),
            contextLength: nil,
            extra: [intVal("max_model_len"), intVal("maxModelLen")])
        let loaded = loadedWindow(
            nativeContextLength: nativeMax,
            maxContextLength: intVal("max_context_length") ?? intVal("maxContextLength"),
            contextLength: intVal("context_length") ?? intVal("contextLength"))
        return honestyLabel(nativeMax: nativeMax ?? loaded, loaded: loaded)
    }
}
