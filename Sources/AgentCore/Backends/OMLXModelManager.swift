//
//  OMLXModelManager.swift
//
//  Manages the oMLX model lifecycle (load/unload) via its native API.
//
//  oMLX exposes three key endpoints beyond the OpenAI-compatible surface:
//    GET  /v1/models/status      — shows which models are loaded in memory
//    POST /v1/models/{id}/load   — loads a model into GPU/RAM
//    POST /v1/models/{id}/unload  — unloads a model, freeing memory
//
//  oMLX auto-loads the `is_default: true, is_pinned: true` model on
//  startup (typically the largest model). Other models can't coexist in
//  memory because of the ~500 GB ceiling on a maxed Mac Studio — so
//  switching to a different model requires unloading the current one
//  first, then loading the requested one. This manager orchestrates
//  that sequence and is called before every chat completion request.
//

import Foundation

/// State of a single oMLX model in the status response.
public struct OMLXModelStatus: Sendable, Decodable {
    public let id: String
    public let loaded: Bool
    public let isLoading: Bool
    public let pinned: Bool
    /// Absolute path to the model directory on disk (when provided by oMLX).
    public let modelPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case loaded
        case isLoading = "is_loading"
        case pinned
        case modelPath = "model_path"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        loaded = try c.decodeIfPresent(Bool.self, forKey: .loaded) ?? false
        isLoading = try c.decodeIfPresent(Bool.self, forKey: .isLoading) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath)
    }
}

/// Aggregated status from `/v1/models/status`.
public struct OMLXStatusResponse: Sendable, Decodable {
    public let loadedCount: Int
    public let models: [OMLXModelStatus]

    enum CodingKeys: String, CodingKey {
        case loadedCount = "loaded_count"
        case models
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loadedCount = try c.decodeIfPresent(Int.self, forKey: .loadedCount) ?? 0
        models = try c.decodeIfPresent([OMLXModelStatus].self, forKey: .models) ?? []
    }
}

/// Manages model load/unload lifecycle for an oMLX server.
public actor OMLXModelManager {

    private let baseURL: URL
    private let bearerToken: String?
    private let session: URLSession

    private let loadPollTimeout: TimeInterval = 600
    private let loadPollInterval: TimeInterval = 0.75

    public init(baseURL: URL, bearerToken: String? = nil,
                session: URLSession? = nil) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 600
            cfg.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Public API

    /// oMLX profiles appear as `baseModel:profileName` in `/v1/models`, but
    /// load/unload and status "loaded" flags are owned by the **engine**
    /// (the base id). Chat still uses the full id so profile sampling applies.
    public static func engineModelID(_ modelID: String) -> String {
        guard let colon = modelID.lastIndex(of: ":"),
              colon > modelID.startIndex else {
            return modelID
        }
        let suffix = modelID[modelID.index(after: colon)...]
        // Profile suffixes are short tokens (e.g. "speed-quality"), not paths.
        guard !suffix.isEmpty,
              !suffix.contains("/"),
              !suffix.contains(" ") else {
            return modelID
        }
        return String(modelID[..<colon])
    }

    private static func isSameEngine(_ a: String, _ b: String) -> Bool {
        engineModelID(a) == engineModelID(b)
    }

    private static func engineIsLoaded(_ status: OMLXStatusResponse, engineID: String) -> Bool {
        status.models.contains {
            engineModelID($0.id) == engineID && $0.loaded
        }
    }

    private static func engineIsLoading(_ status: OMLXStatusResponse, engineID: String) -> Bool {
        status.models.contains {
            engineModelID($0.id) == engineID && $0.isLoading
        }
    }

    /// Ensures the engine for `modelID` is loaded in oMLX.
    /// Accepts base ids (`Nemotron-3-Ultra-550B-A55B`) or profile aliases
    /// (`Nemotron-3-Ultra-550B-A55B:speed-quality`).
    public func ensureModelLoaded(_ modelID: String) async throws -> Bool {
        let engineID = Self.engineModelID(modelID)

        let status: OMLXStatusResponse
        do {
            status = try await fetchStatus()
        } catch {
            throw BackendError.http(
                status: 0,
                body: "oMLX is not reachable at \(baseURL.absoluteString). Is oMLX running? (\(error.localizedDescription))")
        }

        if Self.engineIsLoaded(status, engineID: engineID) {
            return true
        }

        // Another *engine* is mid-load — don't unload/reload into a busy server.
        if let busy = status.models.first(where: {
            $0.isLoading && !Self.isSameEngine($0.id, engineID)
        }) {
            throw BackendError.http(
                status: 0,
                body: """
                oMLX is busy loading '\(busy.id)'. Wait until that finishes (or cancel it in oMLX), \
                then select your model again. Requested: '\(modelID)' (engine: \(engineID)).
                """)
        }

        // Preflight: incomplete downloads fail with opaque "Missing N parameters".
        if let entry = status.models.first(where: { Self.engineModelID($0.id) == engineID }),
           let path = entry.modelPath {
            if let incomplete = Self.incompleteShardMessage(modelID: engineID, modelPath: path) {
                throw BackendError.http(status: 0, body: incomplete)
            }
        }

        // Unload other engines only (not profile aliases of the same engine).
        var unloaded = Set<String>()
        for entry in status.models where entry.loaded {
            let other = Self.engineModelID(entry.id)
            guard other != engineID, !unloaded.contains(other) else { continue }
            try await unloadModel(other)
            unloaded.insert(other)
        }

        // If the requested engine is already loading, poll instead of re-POSTing load.
        if Self.engineIsLoading(status, engineID: engineID) {
            try await waitUntilLoaded(engineID)
            return true
        }

        // Always load by *engine* id — profile settings are selected via chat `model`.
        try await loadModel(engineID)
        return true
    }

    private func waitUntilLoaded(_ engineID: String) async throws {
        let deadline = Date().addingTimeInterval(loadPollTimeout)
        while Date() < deadline {
            if Task.isCancelled {
                throw BackendError.http(status: 0, body: "Model load cancelled for '\(engineID)'")
            }
            let status = try await fetchStatus()
            if Self.engineIsLoaded(status, engineID: engineID) { return }
            if !Self.engineIsLoading(status, engineID: engineID) {
                // Load aborted without loaded flag — force a new load attempt.
                try await loadModel(engineID)
                return
            }
            try await Task.sleep(nanoseconds: UInt64(loadPollInterval * 1_000_000_000))
        }
        throw BackendError.http(
            status: 0,
            body: "Timed out waiting for model '\(engineID)' to finish loading in oMLX")
    }

    public func fetchStatus() async throws -> OMLXStatusResponse {
        let url = baseURL.appendingPathComponent("models/status")
        var req = URLRequest(url: url)
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BackendError.http(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                body: "oMLX /v1/models/status failed: \(body)")
        }
        return try JSONDecoder().decode(OMLXStatusResponse.self, from: data)
    }

    // MARK: - Internal

    private func modelActionURL(_ modelID: String, action: String) throws -> URL {
        let encoded = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
        guard let url = URL(string: baseURL.absoluteString + "/models/\(encoded)/\(action)") else {
            throw BackendError.http(status: 0, body: "Invalid oMLX model URL for id: \(modelID)")
        }
        return url
    }

    private func loadModel(_ modelID: String) async throws {
        let url = try modelActionURL(modelID, action: "load")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Ask oMLX to retry past a sticky "previous load failure" when possible.
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["force": true])
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BackendError.http(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                body: Self.humanizeLoadFailure(modelID: modelID, raw: body))
        }

        let engineID = Self.engineModelID(modelID)
        let deadline = Date().addingTimeInterval(loadPollTimeout)
        while Date() < deadline {
            if Task.isCancelled {
                throw BackendError.http(status: 0, body: "Model load cancelled for '\(engineID)'")
            }
            let status = try await fetchStatus()
            if Self.engineIsLoaded(status, engineID: engineID) {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(loadPollInterval * 1_000_000_000))
        }
        throw BackendError.http(
            status: 0,
            body: "Timed out waiting for model '\(engineID)' to finish loading in oMLX")
    }

    /// Unload a model (or profile alias) by engine id.
    public func unloadModel(_ modelID: String) async throws {
        let engineID = Self.engineModelID(modelID)
        let url = try modelActionURL(engineID, action: "unload")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Treat 404 as already-unloaded success.
            if http.statusCode == 404 { return }
            throw BackendError.http(
                status: http.statusCode,
                body: "oMLX failed to unload '\(engineID)': \(body)")
        }
    }

    // MARK: - Diagnostics

    /// Returns a user-facing error if the on-disk model is missing weight shards.
    static func incompleteShardMessage(modelID: String, modelPath: String) -> String? {
        let dir = URL(fileURLWithPath: modelPath)
        let indexURL = dir.appendingPathComponent("model.safetensors.index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String] else {
            return nil
        }
        let needed = Set(weightMap.values)
        let missing = needed.filter { name in
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
        }.sorted()
        guard !missing.isEmpty else { return nil }
        let sample = missing.prefix(5).joined(separator: ", ")
        let more = missing.count > 5 ? " (+\(missing.count - 5) more)" : ""
        return """
        Model '\(modelID)' is incomplete on disk — \(missing.count) of \(needed.count) weight \
        shards are missing (\(sample)\(more)). \
        Re-download the model in oMLX (or Hugging Face), then restart oMLX and try again. \
        Path: \(modelPath)
        """
    }

    /// Collapse oMLX JSON walls of text into actionable copy.
    static func humanizeLoadFailure(modelID: String, raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("previous load failure") || lower.contains("unavailable after") {
            return """
            oMLX refuses to load '\(modelID)' after a previous failure. \
            Usually the weights are incomplete or corrupt. \
            Fix/re-download the model, restart oMLX to clear the sticky failure, then select it again. \
            Detail: \(compactJSONMessage(raw))
            """
        }
        if lower.contains("missing") && lower.contains("parameter") {
            return """
            oMLX could not load '\(modelID)' — missing weight parameters (incomplete download). \
            Re-download the model in oMLX, restart oMLX, then try again. \
            Detail: \(compactJSONMessage(raw))
            """
        }
        return "Failed to load model '\(modelID)': \(compactJSONMessage(raw))"
    }

    private static func compactJSONMessage(_ raw: String) -> String {
        // Prefer nested error.message when present.
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String {
                return String(msg.prefix(280))
            }
            if let msg = obj["message"] as? String {
                return String(msg.prefix(280))
            }
        }
        return String(raw.prefix(280))
    }
}
