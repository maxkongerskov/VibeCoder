//
//  XAIBackend.swift
//
//  xAI Grok cloud API — OpenAI-compatible surface at https://api.x.ai/v1
//  (chat completions + models). Used so VibeCoder's agent harness can run
//  frontier Grok models (e.g. grok-4 / grok-4.5) against the same tool loop
//  as local backends.
//

import Foundation

public actor XAIBackend: InferenceBackend {
    public let identifier: BackendIdentifier = .xai
    private let client: OpenAICompatibleClient

    /// Production API root (includes `/v1`).
    public static let defaultBaseURL = URL(string: "https://api.x.ai/v1")!

    /// Fallback catalog when `/v1/models` is unreachable or the key is empty.
    /// IDs match xAI's public model list; the live list wins when available.
    public static let fallbackModels: [(id: String, name: String, context: Int)] = [
        ("grok-4", "Grok 4", 256_000),
        ("grok-4-0709", "Grok 4 (0709)", 256_000),
        ("grok-4-1-fast-reasoning", "Grok 4.1 Fast Reasoning", 256_000),
        ("grok-4-1-fast-non-reasoning", "Grok 4.1 Fast", 256_000),
        ("grok-3", "Grok 3", 131_072),
        ("grok-3-mini", "Grok 3 Mini", 131_072),
        ("grok-2-latest", "Grok 2", 131_072),
    ]

    public init(apiKey: String, baseURL: URL = XAIBackend.defaultBaseURL, session: URLSession? = nil) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.client = OpenAICompatibleClient(
            config: .init(
                baseURL: baseURL,
                bearerToken: key.isEmpty ? nil : key
            ),
            session: session
        )
    }

    public func listModels() async throws -> [ModelDescriptor] {
        if let bare = try? await client.listModels(), !bare.isEmpty {
            return bare.map { m in
                let catalogCtx = Self.fallbackModels.first(where: { $0.id == m.id })?.context
                let ctx = ModelContextLengthResolver.resolve(
                    modelId: m.id,
                    apiValue: m.contextLength)
                    ?? catalogCtx
                return ModelDescriptor(
                    id: m.id,
                    displayName: prettyName(m.id),
                    backend: .xai,
                    supportsTools: true,
                    contextLength: ctx ?? 256_000,
                    parameterCountB: nil
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        // No key / network — still expose known IDs so the picker is usable.
        return Self.fallbackModels.map {
            ModelDescriptor(
                id: $0.id,
                displayName: $0.name,
                backend: .xai,
                supportsTools: true,
                contextLength: $0.context,
                parameterCountB: nil
            )
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

    private func prettyName(_ id: String) -> String {
        if let hit = Self.fallbackModels.first(where: { $0.id == id }) {
            return hit.name
        }
        return id
    }
}
