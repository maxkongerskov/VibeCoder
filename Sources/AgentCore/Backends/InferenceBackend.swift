//
//  InferenceBackend.swift
//
//  The one protocol every model surface conforms to. The agent loop sees
//  only this; backend-specific code never leaks upward.
//
//  Original AgentOS had two parallel interfaces — an HTTP-ish surface
//  for LM Studio / EXO / llama.cpp and an in-process surface for MLX —
//  and `ChatViewModel` was the place where the two converged via a
//  computed `lmService` property. That works but bakes the divergence
//  into the call site. NEW DAY unifies them under one async-stream
//  shape so the loop is genuinely backend-agnostic.
//

import Foundation

public enum BackendIdentifier: String, Sendable, Codable {
    case lmStudio
    case exo
    case mlx
    case omlx
    /// Local Ollama server (OpenAI-compatible API, default port 11434).
    case ollama
    /// Unsloth Studio local server (OpenAI-compatible + native load/unload, default port 8888).
    case unslothStudio
    /// xAI Grok cloud API (https://api.x.ai/v1).
    case xai
    case custom

    /// Legacy raw value for the removed bundled-llama.cpp product.
    /// Still accepted on decode so old settings plists do not crash.
    public static let legacyLlamaCppRawValue = "llamaCpp"

    /// Map a stored raw backend string to a current case.
    /// `"llamaCpp"` → `.ollama` (recommended replacement for local models).
    public static func migrating(fromRaw raw: String) -> BackendIdentifier {
        if raw == legacyLlamaCppRawValue { return .ollama }
        // Accept a few common aliases for Unsloth Studio.
        switch raw {
        case "unsloth", "unsloth-studio", "unsloth_studio": return .unslothStudio
        default: break
        }
        return BackendIdentifier(rawValue: raw) ?? .ollama
    }

    /// Whether this backend exposes explicit load/unload in the model picker.
    public var supportsLoadUnload: Bool {
        switch self {
        case .unslothStudio, .lmStudio, .omlx: return true
        case .exo, .mlx, .ollama, .xai, .custom: return false
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = BackendIdentifier.migrating(fromRaw: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct ModelDescriptor: Sendable, Hashable, Codable {
    /// Stable identifier the rest of the app routes on. For HTTP backends
    /// this is whatever the server's `/v1/models` returns. For MLX it's
    /// the HF repo path (e.g. "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit").
    public let id: String
    public let displayName: String
    public let backend: BackendIdentifier
    /// Whether the model declares native tool/function calling.
    public let supportsTools: Bool
    /// Best-effort context window in tokens. nil = unknown.
    public let contextLength: Int?
    /// Best-effort parameter count in billions, for preset selection.
    public let parameterCountB: Double?
    /// Whether the model is currently resident in server memory.
    /// `nil` = backend does not report load state (treat as unknown).
    public let isLoaded: Bool?

    public init(id: String, displayName: String, backend: BackendIdentifier,
                supportsTools: Bool = false, contextLength: Int? = nil,
                parameterCountB: Double? = nil,
                isLoaded: Bool? = nil) {
        self.id = id
        self.displayName = displayName
        self.backend = backend
        self.supportsTools = supportsTools
        self.contextLength = contextLength
        self.parameterCountB = parameterCountB
        self.isLoaded = isLoaded
    }
}

public struct ChatRequest: Sendable {
    public let model: ModelDescriptor
    public let messages: [ChatMessage]
    public let tools: [ToolSchema]
    public let sampling: SamplingParams
    /// Cancellation handle. The loop generates one UUID per turn and
    /// passes it down; UI cancel propagates by calling `cancel(streamID:)`.
    public let streamID: UUID
    /// Optional thinking/reasoning effort for models that support it.
    /// The backend's encode step injects this into the HTTP body in the
    /// format each model family expects (OpenAI reasoning_effort, GLM
    /// thinking:{type}, Anthropic budget_tokens). nil = no thinking
    /// configuration (model default or unsupported).
    public let thinking: ThinkingRequestConfig?

    public init(model: ModelDescriptor, messages: [ChatMessage],
                tools: [ToolSchema], sampling: SamplingParams,
                streamID: UUID = UUID(),
                thinking: ThinkingRequestConfig? = nil) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.sampling = sampling
        self.streamID = streamID
        self.thinking = thinking
    }
}

/// Carries the thinking capability + user-chosen effort from the UI
/// down through the agent loop to the backend's request encoder.
public struct ThinkingRequestConfig: Sendable {
    public let capability: ThinkingCapability
    public let effort: ThinkingEffort

    public init(capability: ThinkingCapability, effort: ThinkingEffort) {
        self.capability = capability
        self.effort = effort
    }
}

public enum ChatChunk: Sendable {
    /// Incremental model reasoning / thinking tokens (reasoning_content).
    case reasoningDelta(String)
    /// Incremental assistant content.
    case contentDelta(String)
    /// Incremental tool call. Multiple `toolCallDelta` chunks with the
    /// same `index` should be concatenated by the consumer.
    ///
    /// **Critical:** OpenAI-compatible backends (llama.cpp, LM Studio) send
    /// `id` ONLY on the first chunk per call — subsequent fragments carry
    /// `id = nil` and identify themselves by `index`. So consumers MUST
    /// bucket by `index`, not by `id`. The first non-nil `id` per index
    /// is the canonical id for the merged invocation.
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsAppend: String?)
    /// Usage stats, often delivered as a final chunk.
    case usage(promptTokens: Int, completionTokens: Int)
    /// Stream terminator. `finishReason` is "stop", "tool_calls",
    /// "length", "cancelled", or backend-specific.
    case done(finishReason: String)
}

public protocol InferenceBackend: Sendable {
    var identifier: BackendIdentifier { get }
    /// List of models the backend will currently accept. For HTTP
    /// backends this calls `/v1/models`. For MLX this is the curated
    /// catalog filtered by what's locally downloaded.
    func listModels() async throws -> [ModelDescriptor]
    /// Optional priming. HTTP backends are usually no-ops; MLX uses
    /// this to preload weights into Metal memory.
    func warmUp(model: ModelDescriptor) async throws
    /// The core streaming surface. The consumer iterates the stream
    /// until `.done(...)` arrives.
    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error>
    /// Cancel an in-flight stream by ID. Idempotent.
    func cancel(streamID: UUID) async
    /// Optional weights release. MLX uses this to drop containers.
    func unload(model: ModelDescriptor) async throws
}

// Default implementations for backends that don't need warm-up or unload.
public extension InferenceBackend {
    func warmUp(model: ModelDescriptor) async throws {}
    func unload(model: ModelDescriptor) async throws {}
}
