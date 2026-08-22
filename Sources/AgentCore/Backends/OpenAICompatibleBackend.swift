//
//  OpenAICompatibleBackend.swift
//
//  Generic OpenAI-compatible API backend. Used for the custom endpoint
//  setting — any server that speaks the OpenAI `/v1/chat/completions`
//  and `/v1/models` surfaces (OpenRouter, Groq, Together, vLLM,
//  llama.cpp server, text-generation-webui, etc.) can be plugged in
//  without a dedicated target.
//
//  Unlike LMStudioBackend this does NOT attempt the LM Studio-specific
//  `/api/v0/models` endpoint — it falls back to the OpenAI-compatible
//  models listing and then to the curated catalog.
//
import Foundation

public actor OpenAICompatibleBackend: InferenceBackend {
    public let identifier: BackendIdentifier = .custom
    private let client: OpenAICompatibleClient
    private let host: String
    private let port: Int

    public init(baseURL: URL, apiKey: String? = nil,
                session: URLSession? = nil,
                requestTimeout: TimeInterval = 600) {
        self.host = baseURL.host ?? "127.0.0.1"
        self.port = baseURL.port ?? 1234
        self.client = OpenAICompatibleClient(
            config: .init(
                baseURL: baseURL,
                bearerToken: apiKey,
                requestTimeout: requestTimeout
            ),
            session: session
        )
    }

    public func listModels() async throws -> [ModelDescriptor] {
        // Try the OpenAI-compatible /v1/models first.
        // Remap provenance to `.custom` — the shared client used to stamp
        // `.lmStudio` (and now stamps `.custom`); always re-tag here so
        // multi-backend UI / settings never mis-attribute models.
        let bare = try? await client.listModels()
        if let bare, !bare.isEmpty {
            return bare.map {
                ModelDescriptor(
                    id: $0.id,
                    displayName: $0.displayName,
                    backend: .custom,
                    supportsTools: $0.supportsTools,
                    contextLength: $0.contextLength,
                    parameterCountB: $0.parameterCountB)
            }
        }

        // Empty list when unreachable — the user can type a model id or
        // fix the endpoint. Do not invent phantom catalog entries.
        return []
    }

    public nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        let streamID = request.streamID
        let body = Self.encode(request: request)
        return AsyncThrowingStream<ChatChunk, Error> { (continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation) in
            let pump = Task {
                do {
                    for try await chunk in await client.streamChatCompletion(
                        streamID: streamID,
                        body: body
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            Self.registry.set(pump, for: streamID)
            continuation.onTermination = { @Sendable reason in
                pump.cancel()
                // Also cancel the shared client's inflight HTTP task so the
                // upstream server stops generating (was pump-only before).
                if case .cancelled = reason {
                    Task { await self.cancel(streamID: streamID) }
                }
            }
        }
    }

    private static func encode(request: ChatRequest) -> ChatCompletionRequestBody {
        // Match LM Studio / Ollama / EXO encode: empty tool_calls / tools
        // must be omitted (nil), not sent as [] — some servers 400 on empty
        // arrays or treat them as "no function calling support".
        let wireMessages = ChatCompletionRequestBody.assembledWireMessages(
            from: request.messages, emptyTextAsEmptyString: false)

        let wireTools: [ChatCompletionRequestBody.WireTool]? = request.tools.isEmpty
            ? nil
            : request.tools.map { tool in
                ChatCompletionRequestBody.WireTool(
                    function: .init(name: tool.name, description: tool.description, parameters: tool.parameters)
                )
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

    // MARK: - Cancellation tracking
    //
    // Stream cancellation is tracked in a lock-protected registry held in a
    // `static let`. The `@unchecked Sendable` is sound: every access goes
    // through `NSLock`, so the mutable dictionary is externally synchronized.
    // (Pre-Swift-6 this was a `static var` + separate lock; consolidating it
    // into a Sendable container makes the thread-safety provable and clears
    // the Swift 6 "nonisolated global mutable state" warning.)

    private final class TaskRegistry: @unchecked Sendable {
        private var tasks: [UUID: Task<Void, Never>] = [:]
        private let lock = NSLock()

        func set(_ task: Task<Void, Never>, for id: UUID) {
            lock.withLock { tasks[id] = task }
        }

        func cancelAndRemove(for id: UUID) {
            lock.withLock { tasks.removeValue(forKey: id)?.cancel() }
        }
    }

    private static let registry = TaskRegistry()

    public func cancel(streamID: UUID) async {
        Self.registry.cancelAndRemove(for: streamID)
        await client.cancel(streamID: streamID)
    }
}