//
//  OMLXBackend.swift
//
//  Thin wrapper over OpenAICompatibleClient targeting the oMLX server's
//  default `localhost:8080`. oMLX exposes an OpenAI-compatible API
//  (`/v1/chat/completions`, `/v1/models`) so we reuse the same HTTP
//  client as LM Studio — the only differences are the default port
//  (8080) and an optional bearer token read from the OMLX_API_KEY
//  environment variable.
//

import Foundation

public actor OMLXBackend: InferenceBackend {
    public let identifier: BackendIdentifier = .omlx
    private let client: OpenAICompatibleClient
    private let host: String
    private let port: Int
    private let modelManager: OMLXModelManager

    public init(host: String = "127.0.0.1", port: Int = 8080, apiKey: String? = nil,
                session: URLSession? = nil) {
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
        let resolvedKey = apiKey ?? ProcessInfo.processInfo.environment["OMLX_API_KEY"]
        self.client = OpenAICompatibleClient(
            config: .init(baseURL: url, bearerToken: resolvedKey),
            session: session)
        self.modelManager = OMLXModelManager(
            baseURL: url, bearerToken: resolvedKey, session: session)
    }

    public nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                // Hard preflight: the user-selected model must load.
                // Never fall through to chat on the server's pinned default.
                do {
                    _ = try await self.modelManager.ensureModelLoaded(request.model.id)
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

    /// Preload the model into oMLX's memory. Called by the app on
    /// startup or when the user selects a model, so the first chat
    /// request doesn't wait for a multi-GB load.
    public func warmUp(model: ModelDescriptor) async throws {
        _ = try await modelManager.ensureModelLoaded(model.id)
    }

    public func unload(model: ModelDescriptor) async throws {
        try await modelManager.unloadModel(model.id)
    }

    public func listModels() async throws -> [ModelDescriptor] {
        // Prefer status endpoint so the picker shows loaded vs not-loaded.
        if let status = try? await modelManager.fetchStatus(), !status.models.isEmpty {
            let bare = (try? await client.listModels()) ?? []
            // Duplicate /v1/models ids (same base + profile) must not trap.
            let byID = Dictionary(bare.map { ($0.id, $0) }, uniquingKeysWith: { first, second in
                second.contextLength != nil ? second : first
            })
            var seen = Set<String>()
            var out: [ModelDescriptor] = []
            for entry in status.models {
                seen.insert(entry.id)
                let ctx = byID[entry.id]?.contextLength
                    ?? ModelContextLengthResolver.resolve(modelId: entry.id, apiValue: nil)
                out.append(ModelDescriptor(
                    id: entry.id,
                    displayName: entry.id,
                    backend: .omlx,
                    supportsTools: true,
                    contextLength: ctx,
                    parameterCountB: nil,
                    isLoaded: entry.loaded))
            }
            // Include any /v1/models ids missing from status (profiles, etc.).
            for item in bare where !seen.contains(item.id) {
                let engine = OMLXModelManager.engineModelID(item.id)
                let loaded = status.models.contains {
                    OMLXModelManager.engineModelID($0.id) == engine && $0.loaded
                }
                out.append(ModelDescriptor(
                    id: item.id,
                    displayName: item.id,
                    backend: .omlx,
                    supportsTools: true,
                    contextLength: item.contextLength,
                    parameterCountB: nil,
                    isLoaded: loaded))
            }
            out.sort { a, b in
                let al = a.isLoaded == true
                let bl = b.isLoaded == true
                if al != bl { return al && !bl }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName)
                    == .orderedAscending
            }
            return out
        }
        let bare = try await client.listModels()
        return bare.map {
            ModelDescriptor(id: $0.id, displayName: $0.id, backend: .omlx,
                            supportsTools: true,
                            contextLength: $0.contextLength,
                            parameterCountB: nil,
                            isLoaded: nil)
        }
    }

    // MARK: - Encoding

    private func encode(request: ChatRequest) -> ChatCompletionRequestBody {
        // oMLX: empty text as "" (not null) for non-tool assistant turns.
        // Vision messages use multimodal parts regardless.
        let mapped: [ChatCompletionRequestBody.WireMessage] = request.messages.map { msg in
            let isAssistantWithTools = msg.role == .assistant && !msg.toolCalls.isEmpty
            // Tool-call assistants: prefer null text when empty (OpenAI convention).
            let emptyAsString = !isAssistantWithTools
            return ChatCompletionRequestBody.WireMessage.from(
                msg,
                emptyTextAsEmptyString: emptyAsString
            )
        }
        let wireMessages = ChatCompletionRequestBody.collapsingTrailingAssistants(mapped)
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