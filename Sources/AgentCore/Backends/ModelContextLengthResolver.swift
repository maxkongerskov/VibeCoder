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

    /// API value first; then known defaults for common MLX/OMLX model IDs.
    public static func resolve(modelId: String, apiValue: Int?) -> Int? {
        if let apiValue, apiValue > 0 { return apiValue }
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
        return nil
    }
}
