//
//  UnslothStudioBackend.swift
//
//  OpenAI-compatible client for Unsloth Studio (default localhost:8888).
//  Lists downloaded + loaded models via GET /v1/models (with `loaded` flag),
//  loads via POST /v1/load, unloads via POST /v1/unload, and streams chat
//  through /v1/chat/completions.
//

import Foundation

public actor UnslothStudioBackend: InferenceBackend {
    public let identifier: BackendIdentifier = .unslothStudio
    private let client: OpenAICompatibleClient
    private let host: String
    private let port: Int
    private let bearerToken: String?
    private let session: URLSession
    private let v1BaseURL: URL

    private let loadPollTimeout: TimeInterval = 600
    private let loadPollInterval: TimeInterval = 1.0

    public init(
        host: String = "127.0.0.1",
        port: Int = 8888,
        apiKey: String? = nil,
        requestTimeout: TimeInterval = 600,
        session: URLSession? = nil
    ) {
        var cleanHost = host.trimmingCharacters(in: .whitespaces)
        for scheme in ["http://", "https://"] where cleanHost.lowercased().hasPrefix(scheme) {
            cleanHost = String(cleanHost.dropFirst(scheme.count))
            break
        }
        cleanHost = cleanHost.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if cleanHost.isEmpty { cleanHost = "127.0.0.1" }
        let urlHost = (cleanHost.contains(":") && !cleanHost.hasPrefix("["))
            ? "[\(cleanHost)]" : cleanHost
        self.host = urlHost
        self.port = port

        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = (trimmedKey?.isEmpty == false) ? trimmedKey : nil
        // Fall back to Unsloth's local agent key file when Settings has no key
        // (Studio requires Bearer auth on /v1/*).
        self.bearerToken = explicit ?? Self.readLocalAgentAPIKey()

        let url = URL(string: "http://\(urlHost):\(port)/v1")
            ?? URL(string: "http://127.0.0.1:\(port)/v1")!
        self.v1BaseURL = url

        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = requestTimeout
            cfg.timeoutIntervalForResource = requestTimeout
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
        self.client = OpenAICompatibleClient(
            config: .init(
                baseURL: url,
                bearerToken: bearerToken,
                requestTimeout: requestTimeout
            ),
            session: self.session)
    }

    // MARK: - InferenceBackend

    public func listModels() async throws -> [ModelDescriptor] {
        // Prefer native OpenAI-compat list — includes downloaded models +
        // `loaded` flag (not only what's resident).
        if let native = try? await modelsViaV1(), !native.isEmpty {
            return native
        }
        // Merge local models-folder inventory when /v1/models is empty/down.
        if let local = try? await modelsViaLocalFolder(), !local.isEmpty {
            return local
        }
        let bare = try await client.listModels()
        return bare.map {
            ModelDescriptor(
                id: $0.id,
                displayName: $0.id,
                backend: .unslothStudio,
                supportsTools: true,
                contextLength: $0.contextLength,
                parameterCountB: nil,
                isLoaded: nil)
        }
    }

    public func warmUp(model: ModelDescriptor) async throws {
        if let loaded = model.isLoaded, loaded { return }
        if await isModelLoaded(modelID: model.id) { return }
        try await loadModel(modelPath: model.id, maxSeqLength: model.contextLength ?? 0)
    }

    public func unload(model: ModelDescriptor) async throws {
        try await unloadModel(modelPath: model.id)
    }

    public nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    try await self.warmUp(model: request.model)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                let body = await self.encode(request: request)
                let stream = await client.streamChatCompletion(
                    streamID: request.streamID, body: body)
                do {
                    for try await chunk in stream { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable reason in
                pump.cancel()
                if case .cancelled = reason {
                    Task { await self.cancel(streamID: request.streamID) }
                }
            }
        }
    }

    public func cancel(streamID: UUID) async {
        await client.cancel(streamID: streamID)
    }

    // MARK: - Load / unload

    /// POST /v1/load  body: { "model_path": "…", "max_seq_length": N }
    public func loadModel(modelPath: String, maxSeqLength: Int = 0) async throws {
        let url = v1BaseURL.appendingPathComponent("load")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = loadPollTimeout
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = ["model_path": modelPath]
        if maxSeqLength > 0 {
            body["max_seq_length"] = maxSeqLength
        }
        // GGUF path is auto-detected by Studio; leave load_in_4bit default.
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("Non-HTTP response from Unsloth Studio load")
        }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw BackendError.http(
                status: http.statusCode,
                body: "Unsloth Studio failed to load \(modelPath): \(text)")
        }

        // Poll until loaded (or timeout).
        let deadline = Date().addingTimeInterval(loadPollTimeout)
        while Date() < deadline {
            if Task.isCancelled {
                throw BackendError.http(
                    status: 0, body: "Model load cancelled for '\(modelPath)'")
            }
            if await isModelLoaded(modelID: modelPath) { return }
            try await Task.sleep(nanoseconds: UInt64(loadPollInterval * 1_000_000_000))
        }
        throw BackendError.http(
            status: 0,
            body: "Timed out waiting for Unsloth Studio to load '\(modelPath)'")
    }

    /// POST /v1/unload  body: { "model_path": "…" }
    public func unloadModel(modelPath: String, forceCancelActive: Bool = false) async throws {
        let url = v1BaseURL.appendingPathComponent("unload")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model_path": modelPath,
            "force_cancel_active": forceCancelActive,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("Non-HTTP response from Unsloth Studio unload")
        }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw BackendError.http(
                status: http.statusCode,
                body: "Unsloth Studio failed to unload \(modelPath): \(text)")
        }
    }

    // MARK: - Listing helpers

    private func modelsViaV1() async throws -> [ModelDescriptor]? {
        let url = v1BaseURL.appendingPathComponent("models")
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }

        struct V1Response: Decodable { let data: [V1Model] }
        struct V1Model: Decodable {
            let id: String
            let object: String?
            let owned_by: String?
            let quant: String?
            let context_length: Int?
            let max_context_length: Int?
            let native_context_length: Int?
            let loaded: Bool?
            let type: String?

            var resolvedContext: Int? {
                ModelContextLengthResolver.advertisedMax(
                    nativeContextLength: native_context_length,
                    maxContextLength: max_context_length,
                    contextLength: context_length)
            }
        }

        guard let decoded = try? JSONDecoder().decode(V1Response.self, from: data) else {
            return nil
        }

        // Chat picker only needs generative models — drop pure embeddings.
        let chat = decoded.data.filter { !Self.isEmbeddingModel($0.id, type: $0.type) }

        var rows = chat.map { m -> ModelDescriptor in
            let ctx = ModelContextLengthResolver.resolve(
                modelId: m.id, apiValue: m.resolvedContext)
            let display: String = {
                if let q = m.quant, !q.isEmpty {
                    let base = m.id.components(separatedBy: "/").last ?? m.id
                    return "\(base) (\(q))"
                }
                return m.id.components(separatedBy: "/").last ?? m.id
            }()
            return ModelDescriptor(
                id: m.id,
                displayName: display,
                backend: .unslothStudio,
                supportsTools: true,
                contextLength: ctx,
                parameterCountB: nil,
                isLoaded: m.loaded)
        }

        // Loaded first, then alpha by display name.
        rows.sort { a, b in
            let al = a.isLoaded == true
            let bl = b.isLoaded == true
            if al != bl { return al && !bl }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName)
                == .orderedAscending
        }
        return rows
    }

    /// GET /api/models/local — models folder + HF cache + LM Studio dirs.
    private func modelsViaLocalFolder() async throws -> [ModelDescriptor]? {
        guard let url = URL(string: "http://\(host):\(port)/api/models/local") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }

        struct LocalResponse: Decodable {
            let models: [LocalModel]?
        }
        struct LocalModel: Decodable {
            let id: String?
            let display_name: String?
            let model_id: String?
            let model_format: String?
            let partial: Bool?
        }

        guard let decoded = try? JSONDecoder().decode(LocalResponse.self, from: data),
              let models = decoded.models, !models.isEmpty else {
            return nil
        }

        return models.compactMap { m -> ModelDescriptor? in
            // Prefer clean model_id (org/name) for load; fall back to id.
            let rawID = (m.model_id?.isEmpty == false ? m.model_id : m.id) ?? ""
            guard !rawID.isEmpty else { return nil }
            if m.partial == true { return nil }
            if Self.isEmbeddingModel(rawID, type: m.model_format) { return nil }
            let name = m.display_name ?? (rawID.components(separatedBy: "/").last ?? rawID)
            return ModelDescriptor(
                id: rawID,
                displayName: name,
                backend: .unslothStudio,
                supportsTools: true,
                contextLength: ModelContextLengthResolver.resolve(modelId: rawID, apiValue: nil),
                parameterCountB: nil,
                isLoaded: false)
        }
    }

    private func isModelLoaded(modelID: String) async -> Bool {
        if let models = try? await modelsViaV1() {
            if let hit = models.first(where: { $0.id == modelID }) {
                return hit.isLoaded == true
            }
        }
        // Fallback: /v1/status active model.
        guard let url = URL(string: "http://\(host):\(port)/v1/status") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let active = (root["model_identifier"] as? String)
            ?? (root["active_model"] as? String)
        return active == modelID
    }

    // MARK: - Encoding

    private func encode(request: ChatRequest) -> ChatCompletionRequestBody {
        let wireMessages: [ChatCompletionRequestBody.WireMessage] = request.messages.map {
            ChatCompletionRequestBody.WireMessage.from($0, emptyTextAsEmptyString: false)
        }
        let wireTools: [ChatCompletionRequestBody.WireTool]? =
            request.tools.isEmpty ? nil : request.tools.map {
                .init(function: .init(
                    name: $0.name, description: $0.description, parameters: $0.parameters))
            }
        var body = ChatCompletionRequestBody(
            model: request.model.id,
            messages: wireMessages,
            tools: wireTools,
            sampling: request.sampling,
            stream: true
        )
        if let thinking = request.thinking {
            ThinkingModelScanner.applyThinking(
                to: &body.extraBody,
                capability: thinking.capability,
                effort: thinking.effort
            )
        }
        return body
    }

    // MARK: - Helpers

    nonisolated private static func isEmbeddingModel(_ id: String, type: String?) -> Bool {
        let l = id.lowercased()
        if l.contains("embedding") || l.contains("embed-") || l.contains("-embed") {
            return true
        }
        if let t = type?.lowercased(), t.contains("embed") {
            return true
        }
        return false
    }

    /// Read the first minted agent key from Unsloth Studio's local auth file.
    nonisolated private static func readLocalAgentAPIKey() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home
            .appendingPathComponent(".unsloth/studio/auth/agent_api_key.json")
            .path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["servers"] as? [String: Any] else {
            return nil
        }
        // Prefer any server entry with minted keys (usually 127.0.0.1:8888).
        for (_, value) in servers {
            guard let entry = value as? [String: Any] else { continue }
            if let minted = entry["minted"] as? [String],
               let key = minted.first, !key.isEmpty {
                return key
            }
            if let saved = entry["saved"] as? [String],
               let key = saved.first, !key.isEmpty {
                return key
            }
        }
        return nil
    }
}
