//
//  OllamaBackend.swift
//
//  OpenAI-compatible client for a local Ollama server
//  (default http://127.0.0.1:11434/v1). Extra redundancy path alongside
//  LM Studio, llama.cpp, oMLX, and EXO.
//

import Foundation

public actor OllamaBackend: InferenceBackend {
    public let identifier: BackendIdentifier = .ollama
    private let client: OpenAICompatibleClient
    private let host: String
    private let port: Int

    public init(
        host: String = "127.0.0.1",
        port: Int = 11434,
        requestTimeout: TimeInterval = 600
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
        let url = URL(string: "http://\(urlHost):\(port)/v1")
            ?? URL(string: "http://127.0.0.1:\(port)/v1")!
        self.client = OpenAICompatibleClient(
            config: .init(baseURL: url, requestTimeout: requestTimeout))
    }

    public func listModels() async throws -> [ModelDescriptor] {
        // Prefer currently-loaded models via Ollama's native GET /api/ps so
        // the picker matches LM Studio's "loaded only" behavior. Fall back
        // to OpenAI /v1/models (all tags) when /api/ps is empty or down.
        if let loaded = try? await loadedModelsViaAPIPs(), !loaded.isEmpty {
            return loaded
        }
        let bare = try await client.listModels()
        return bare.map {
            let ctx = ModelContextLengthResolver.resolve(
                modelId: $0.id,
                apiValue: $0.contextLength)
            return ModelDescriptor(
                id: $0.id,
                displayName: $0.id,
                backend: .ollama,
                supportsTools: true,
                contextLength: ctx,
                parameterCountB: nil
            )
        }
    }

    /// Ollama `GET /api/ps` → models currently resident in memory.
    /// Wire shape: `{ "models": [ { "name": "…", "model": "…", … } ] }`.
    private func loadedModelsViaAPIPs() async throws -> [ModelDescriptor]? {
        guard let url = URL(string: "http://\(host):\(port)/api/ps") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        struct PSResponse: Decodable {
            let models: [PSModel]?
        }
        struct PSModel: Decodable {
            let name: String?
            let model: String?
            var resolvedID: String? { name ?? model }
        }

        guard let decoded = try? JSONDecoder().decode(PSResponse.self, from: data),
              let models = decoded.models, !models.isEmpty else { return nil }

        return models.compactMap { m -> ModelDescriptor? in
            guard let id = m.resolvedID, !id.isEmpty else { return nil }
            let ctx = ModelContextLengthResolver.resolve(modelId: id, apiValue: nil)
            return ModelDescriptor(
                id: id,
                displayName: id,
                backend: .ollama,
                supportsTools: true,
                contextLength: ctx,
                parameterCountB: nil)
        }
    }

    public nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
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

    private func encode(request: ChatRequest) -> ChatCompletionRequestBody {
        let wireMessages: [ChatCompletionRequestBody.WireMessage] = request.messages.map {
            ChatCompletionRequestBody.WireMessage.from($0, emptyTextAsEmptyString: false)
        }
        let wireTools: [ChatCompletionRequestBody.WireTool]? = request.tools.isEmpty
            ? nil
            : request.tools.map {
                .init(function: .init(
                    name: $0.name,
                    description: $0.description,
                    parameters: $0.parameters
                ))
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
}
