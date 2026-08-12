//
//  ModelContextLengthResolver.swift
//
//  Normalizes context-length fields from OpenAI-compatible `/v1/models`
//  responses and supplies known defaults for IDs that omit metadata.
//

import Foundation

public enum ModelContextLengthResolver {

    /// Extract context length from a `/v1/models` item (OMLX/LM Studio P0 path).
    public static func fromAPIItem(_ item: [String: Any]) -> Int? {
        let directKeys = ["context_length", "max_model_len", "contextLength",
                          "max_context_length", "maxContextLength"]
        for key in directKeys {
            if let n = item[key] as? Int, n > 0 { return n }
            if let n = item[key] as? Double, n > 0 { return Int(n) }
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