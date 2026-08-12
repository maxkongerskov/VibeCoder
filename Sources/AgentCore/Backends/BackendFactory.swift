//
//  BackendFactory.swift
//
//  Single place that maps `AppSettings.backend` to a constructed
//  `InferenceBackend`. The view models and the LocalAPIServer both go
//  through this — no scattered "which backend?" switches.
//

import Foundation

public enum BackendFactory {

    public static func make(from settings: AppSettings) -> any InferenceBackend {
        switch settings.backend {
        case .lmStudio:
            return LMStudioBackend(
                host: settings.lmStudioHost,
                port: settings.lmStudioPort,
                apiKey: settings.lmStudioAPIKey.isEmpty ? nil : settings.lmStudioAPIKey)
        case .exo:
            // EXO's /v1/models returns the entire catalog (often 100+
            // models) rather than the loaded one. We pin to whatever
            // model ID the user typed in Settings → Connection → EXO
            // so the chat picker shows exactly one option — matching
            // EXO's "one model at a time" runtime.
            return EXOBackend(host: settings.exoHost,
                              port: settings.exoPort,
                              pinnedModelID: settings.exoModelID)
        case .mlx:
            // The MLX *unavailable* stub. The real one is provided by
            // the MLXBackend target; consumers that link it should
            // construct `MLXBackend()` directly. Returning the stub
            // here keeps AgentCore self-contained.
            return MLXBackendUnavailable()
        case .omlx:
            return OMLXBackend(host: settings.omlxHost, port: settings.omlxPort,
                               apiKey: settings.omlxAPIKey.isEmpty ? nil : settings.omlxAPIKey)
        case .ollama:
            return OllamaBackend(host: settings.ollamaHost, port: settings.ollamaPort)
        case .unslothStudio:
            return UnslothStudioBackend(
                host: settings.unslothHost,
                port: settings.unslothPort,
                apiKey: settings.unslothAPIKey.isEmpty ? nil : settings.unslothAPIKey)
        case .xai:
            return XAIBackend(apiKey: settings.xaiAPIKey)
        case .custom:
            let baseURL = normalizeCustomEndpoint(settings.customEndpoint)
                ?? URL(string: "http://127.0.0.1:1234/v1")!
            return OpenAICompatibleBackend(baseURL: baseURL,
                                           apiKey: settings.customAPIKey.isEmpty ? nil : settings.customAPIKey)
        }
    }

    /// Accepts full URLs and common shorthand (`127.0.0.1:8080`, `host:port/v1`).
    public static func normalizeCustomEndpoint(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = "http://" + s
        }
        if var components = URLComponents(string: s),
           let host = components.host, !host.isEmpty {
            if components.path.isEmpty || components.path == "/" {
                components.path = "/v1"
            }
            return components.url
        }
        guard var url = URL(string: s), url.host != nil else { return nil }
        if url.path.isEmpty || url.path == "/" {
            url = url.appendingPathComponent("v1")
        }
        return url
    }
}
