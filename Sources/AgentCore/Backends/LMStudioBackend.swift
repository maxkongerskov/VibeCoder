//
//  LMStudioBackend.swift
//
//  Thin wrapper over OpenAICompatibleClient targeting LM Studio's
//  default `localhost:1234`. Lists models via LM Studio's native REST
//  API (downloaded + loaded) and streams chat through OpenAI-compat `/v1`.
//

import Foundation

public actor LMStudioBackend: InferenceBackend {
    public let identifier: BackendIdentifier = .lmStudio
    private let client: OpenAICompatibleClient
    // Retained so listModels()/warmUp can hit LM Studio's native
    // `/api/v0` and `/api/v1` endpoints (OpenAICompatibleClient only
    // knows the `/v1` base URL).
    private let host: String
    private let port: Int
    /// Same bearer as /v1 — also sent on native REST when LM Studio auth is on.
    private let bearerToken: String?
    /// Shared session for native REST (list/load). Injectable for tests.
    private let session: URLSession

    public init(
        host: String = "127.0.0.1",
        port: Int = 1234,
        apiKey: String? = nil,
        requestTimeout: TimeInterval = 600,
        session: URLSession? = nil
    ) {
        // Defensive: a caller (or a corrupted persisted setting) may pass a
        // host that already includes a scheme like "http://" or a trailing
        // slash. Strip those so we don't build "http://http://...:port/v1",
        // which makes URL(string:) return nil and previously CRASHED on the
        // force-unwrap. Never force-unwrap a constructed URL.
        //
        // Strip the scheme as a LEADING PREFIX only — a global replace would
        // mangle a host that legitimately contains the substring.
        var cleanHost = host.trimmingCharacters(in: .whitespaces)
        for scheme in ["http://", "https://"] where cleanHost.lowercased().hasPrefix(scheme) {
            cleanHost = String(cleanHost.dropFirst(scheme.count))
            break
        }
        cleanHost = cleanHost.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if cleanHost.isEmpty { cleanHost = "127.0.0.1" }
        // Bracket a bare IPv6 literal so `URL(string:)` can parse host:port
        // (e.g. "::1" → "[::1]"). A literal containing a colon that isn't
        // already bracketed is IPv6; a normal "host:port" never reaches here
        // because `port` is a separate parameter.
        let urlHost = (cleanHost.contains(":") && !cleanHost.hasPrefix("["))
            ? "[\(cleanHost)]" : cleanHost
        // Store the URL-safe (bracketed) form — `host` is used only to build
        // URLs (the /v1 base below + native /api calls in listModels/warmUp).
        self.host = urlHost
        self.port = port
        let url = URL(string: "http://\(urlHost):\(port)/v1")
            ?? URL(string: "http://127.0.0.1:\(port)/v1")!
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bearer = (trimmedKey?.isEmpty == false) ? trimmedKey : nil
        self.bearerToken = bearer
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = requestTimeout
            cfg.timeoutIntervalForResource = requestTimeout
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
        // Prefer the same session as native REST so tests can inject one
        // MockURLProtocol for both list/load and OpenAI-compat fallbacks.
        self.client = OpenAICompatibleClient(
            config: .init(
                baseURL: url,
                bearerToken: bearer,
                requestTimeout: requestTimeout
            ),
            session: self.session)
    }

    public func listModels() async throws -> [ModelDescriptor] {
        // LM Studio 0.4+ native REST lists *all downloaded* models
        // (`/api/v1/models`), including those not currently loaded.
        // OpenAI-compat `/v1/models` and legacy `/api/v0/models` only
        // return loaded models when Just-In-Time loading is off — which
        // made the chat picker and Orchestrator/Worker menus empty even
        // though the user had models on disk and the server was up.
        if let native = try? await modelsViaNativeV1(), !native.isEmpty {
            return native
        }
        // Legacy path: filter v0 to state == "loaded".
        if let loaded = try? await loadedModelsViaV0(), !loaded.isEmpty {
            return loaded
        }
        // Final fallback: OpenAI-compat `/v1/models` (loaded-only on modern LMS).
        let bare = try await client.listModels()
        return bare.map {
            ModelDescriptor(id: $0.id, displayName: $0.id, backend: .lmStudio,
                            supportsTools: true,
                            contextLength: $0.contextLength,
                            parameterCountB: nil)
        }
    }

    /// Preload via native REST so selecting an unloaded model works without
    /// requiring JIT or a manual load in LM Studio's UI first.
    public func warmUp(model: ModelDescriptor) async throws {
        if await isModelLoaded(modelID: model.id) { return }

        guard let url = URL(string: "http://\(host):\(port)/api/v1/models/load") else {
            throw BackendError.transport("Could not build LM Studio load URL for \(host):\(port)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Large MLX loads can take many minutes.
        req.timeoutInterval = 600
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = ["model": model.id]
        if let ctx = model.contextLength, ctx > 0 {
            body["context_length"] = ctx
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("Non-HTTP response from LM Studio load")
        }
        if http.statusCode == 200 || http.statusCode == 201 {
            return
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        // Older LMS without /api/v1/models/load — leave warm-up as no-op
        // so chat can still try (user may have loaded manually / JIT on).
        if http.statusCode == 404 { return }
        throw BackendError.transport(
            "LM Studio failed to load \(model.id) (HTTP \(http.statusCode)): \(text)")
    }

    // MARK: - Native list helpers

    /// `GET /api/v1/models` — all downloaded models (LLM + embedding).
    /// Returns nil when the endpoint is missing/unreachable so callers fall back.
    private func modelsViaNativeV1() async throws -> [ModelDescriptor]? {
        guard let url = URL(string: "http://\(host):\(port)/api/v1/models") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        struct V1Response: Decodable { let models: [V1Model] }
        struct V1Model: Decodable {
            let type: String?
            let key: String
            let display_name: String?
            let max_context_length: Int?
            let params_string: String?
            let loaded_instances: [LoadedInstance]?
            let capabilities: Caps?

            struct LoadedInstance: Decodable {
                // Presence alone means the model has at least one loaded instance.
                // Fields vary across LMS versions — keep flexible.
                let id: String?
                let instance_id: String?
            }
            struct Caps: Decodable {
                let trained_for_tool_use: Bool?
                let vision: Bool?
            }
        }

        guard let decoded = try? JSONDecoder().decode(V1Response.self, from: data) else {
            return nil
        }

        // Chat picker / agent loop only need LLMs. Embedding models cannot
        // serve /v1/chat/completions.
        let llms = decoded.models.filter { model in
            let t = (model.type ?? "llm").lowercased()
            return t == "llm" || t == "vlm"
        }

        var descriptors = llms.map { m -> (loaded: Bool, desc: ModelDescriptor) in
            let loaded = !(m.loaded_instances ?? []).isEmpty
            let tools = m.capabilities?.trained_for_tool_use ?? true
            let paramsB = Self.parseParamsB(m.params_string)
            let ctx = ModelContextLengthResolver.resolve(
                modelId: m.key,
                apiValue: m.max_context_length)
            let desc = ModelDescriptor(
                id: m.key,
                displayName: m.display_name ?? m.key,
                backend: .lmStudio,
                supportsTools: tools,
                contextLength: ctx,
                parameterCountB: paramsB,
                isLoaded: loaded)
            return (loaded, desc)
        }

        // Loaded models first so the active server surface is obvious,
        // then alphabetical by display name within each group.
        descriptors.sort { a, b in
            if a.loaded != b.loaded { return a.loaded && !b.loaded }
            return a.desc.displayName.localizedCaseInsensitiveCompare(b.desc.displayName)
                == .orderedAscending
        }
        return descriptors.map(\.desc)
    }

    /// Fetch LM Studio's legacy model list (`/api/v0/models`) and return only
    /// the models whose `state == "loaded"`. Returns nil if the endpoint or
    /// host is unreachable / unparseable, so the caller can fall back.
    private func loadedModelsViaV0() async throws -> [ModelDescriptor]? {
        guard let url = URL(string: "http://\(host):\(port)/api/v0/models") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        struct V0Response: Decodable { let data: [V0Model] }
        struct V0Model: Decodable {
            let id: String
            let state: String?
            let max_context_length: Int?
            let context_length: Int?
            let type: String?

            var resolvedContextLength: Int? {
                max_context_length ?? context_length
            }
        }

        guard let decoded = try? JSONDecoder().decode(V0Response.self, from: data) else { return nil }
        let loaded = decoded.data.filter { model in
            let state = (model.state ?? "").lowercased()
            // Accept common casings / synonyms LMS has used across versions.
            let isLoaded = state == "loaded" || state == "ready" || state == "idle"
            let t = (model.type ?? "llm").lowercased()
            let isChat = t == "llm" || t == "vlm" || t.isEmpty
            return isLoaded && isChat
        }
        return loaded.map {
            let ctx = ModelContextLengthResolver.resolve(
                modelId: $0.id,
                apiValue: $0.resolvedContextLength)
            return ModelDescriptor(id: $0.id, displayName: $0.id, backend: .lmStudio,
                                   supportsTools: true,
                                   contextLength: ctx,
                                   parameterCountB: nil,
                                   isLoaded: true)
        }
    }

    public func unload(model: ModelDescriptor) async throws {
        // Prefer native REST unload. Instance id preferred when present.
        if let instanceID = await firstLoadedInstanceID(modelID: model.id) {
            try await unloadViaNative(instanceID: instanceID, modelKey: model.id)
            return
        }
        // Fall back to model-key unload body (newer LMS).
        try await unloadViaNative(instanceID: nil, modelKey: model.id)
    }

    private func unloadViaNative(instanceID: String?, modelKey: String) async throws {
        guard let url = URL(string: "http://\(host):\(port)/api/v1/models/unload") else {
            throw BackendError.transport("Could not build LM Studio unload URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = ["model": modelKey]
        if let instanceID { body["instance_id"] = instanceID }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("Non-HTTP response from LM Studio unload")
        }
        // 404: endpoint missing or already unloaded — treat as success.
        if http.statusCode == 404 { return }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw BackendError.http(
                status: http.statusCode,
                body: "LM Studio failed to unload \(modelKey): \(text)")
        }
    }

    private func firstLoadedInstanceID(modelID: String) async -> String? {
        guard let url = URL(string: "http://\(host):\(port)/api/v1/models") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            return nil
        }
        for m in models {
            guard let key = m["key"] as? String, key == modelID else { continue }
            guard let instances = m["loaded_instances"] as? [[String: Any]],
                  let first = instances.first else { return nil }
            if let id = first["id"] as? String, !id.isEmpty { return id }
            if let id = first["instance_id"] as? String, !id.isEmpty { return id }
            return nil
        }
        return nil
    }

    private func isModelLoaded(modelID: String) async -> Bool {
        // Prefer native v1 loaded_instances when available.
        guard let url = URL(string: "http://\(host):\(port)/api/v1/models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        if let t = bearerToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            if let loaded = try? await loadedModelsViaV0() {
                return loaded.contains(where: { $0.id == modelID })
            }
            return false
        }
        for m in models {
            guard let key = m["key"] as? String, key == modelID else { continue }
            if let instances = m["loaded_instances"] as? [Any], !instances.isEmpty {
                return true
            }
            return false
        }
        return false
    }

    /// Parse "31B" / "0.6B" style strings to a Double parameter count.
    nonisolated private static func parseParamsB(_ raw: String?) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        s = s.uppercased()
        if s.hasSuffix("B") { s.removeLast() }
        return Double(s)
    }

    public nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                // Ensure the selected model is loaded before chat — same
                // idea as oMLX warmUp, so picker selection of an unloaded
                // model works without JIT.
                do {
                    try await self.warmUp(model: request.model)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let body = await self.encode(request: request)
                let stream = await client.streamChatCompletion(streamID: request.streamID, body: body)
                do {
                    for try await chunk in stream { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Propagate consumer-side cancellation: if the caller drops the
            // stream (e.g. the agent loop is cancelled), tear down the pump
            // AND cancel the underlying HTTP request so it doesn't keep
            // generating to completion in the background. Only the
            // `.cancelled` reason needs the HTTP cancel — `.finished` means
            // the request already completed.
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

    // MARK: - Encoding

    private func encode(request: ChatRequest) -> ChatCompletionRequestBody {
        let wireMessages = ChatCompletionRequestBody.assembledWireMessages(
            from: request.messages, emptyTextAsEmptyString: false)
        let wireTools: [ChatCompletionRequestBody.WireTool]? = request.tools.isEmpty ? nil : request.tools.map {
            .init(function: .init(name: $0.name, description: $0.description, parameters: $0.parameters))
        }
        var body = ChatCompletionRequestBody(
            model: request.model.id,
            messages: wireMessages,
            tools: wireTools,
            sampling: request.sampling,
            stream: true
        )
        // Inject thinking effort into the request body if the model supports it.
        if let thinking = request.thinking {
            ThinkingModelScanner.applyThinking(
                to: &body.extraBody,
                capability: thinking.capability,
                effort: thinking.effort
            )
        }
        return body
    }
}
