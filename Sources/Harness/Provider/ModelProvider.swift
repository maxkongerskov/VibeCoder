//
//  ModelProvider.swift  (Harness)
//
//  The provider boundary. One protocol every model surface conforms to, so
//  the loop engine is backend-agnostic. Deliberately minimal for the rewrite:
//  a provider streams a request and can be cancelled. Model discovery,
//  warm-up, and unload are provider-specific concerns that live on the
//  concrete adapters (and a richer catalog protocol later) — they are NOT on
//  the hot path the loop depends on, so they stay out of this contract.
//

import Foundation

/// Identifies a model to run. Clean-slate version of AgentCore's
/// `ModelDescriptor`, trimmed to what the loop actually needs: an id to send
/// on the wire, plus the two hints that drive sampling-preset selection and
/// context budgeting. `supportsTools` is advisory — the normalizer recovers
/// inline tool calls regardless, so a wrong `false` here never loses a call.
public struct ModelRef: Sendable, Hashable, Codable {
    public let id: String
    public let displayName: String
    public let supportsTools: Bool
    public let contextLength: Int?
    public let parameterCountB: Double?

    public init(id: String,
                displayName: String? = nil,
                supportsTools: Bool = true,
                contextLength: Int? = nil,
                parameterCountB: Double? = nil) {
        self.id = id
        self.displayName = displayName ?? id
        self.supportsTools = supportsTools
        self.contextLength = contextLength
        self.parameterCountB = parameterCountB
    }

    /// Sampling preset implied by the model's size (falls back to `.medium`
    /// when the parameter count is unknown).
    public var samplingPreset: SamplingParams {
        SamplingParams.preset(forParameterCountB: parameterCountB ?? 0)
    }
}

/// One tool offered to the model, in OpenAI function-schema shape. The tool
/// layer produces these from each `Tool`'s schema; the provider serializes
/// them into the request body. `parametersJSON` is a JSON Schema *object*
/// encoded as a string so this type stays a simple value with no JSON-value
/// modelling of its own.
public struct ToolSpec: Sendable, Equatable, Codable {
    public let name: String
    public let description: String
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// One inference request. `streamID` is the cancellation handle: the loop
/// passes the same id to `cancel(streamID:)` to tear down an in-flight
/// generation (essential because `Task.isCancelled` is only observed between
/// awaits, so a long generation keeps running until the provider stream is
/// actually torn down).
public struct ChatRequest: Sendable {
    public let model: ModelRef
    public let messages: [ChatMessage]
    public let tools: [ToolSpec]
    public let sampling: SamplingParams
    public let streamID: UUID

    public init(model: ModelRef,
                messages: [ChatMessage],
                tools: [ToolSpec] = [],
                sampling: SamplingParams = .init(),
                streamID: UUID = UUID()) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.sampling = sampling
        self.streamID = streamID
    }
}

/// Errors a provider can surface through its stream.
public enum ProviderError: Error, Sendable, Equatable {
    case transport(String)        // HTTP/socket/subprocess failure
    case decoding(String)         // malformed SSE / unexpected payload
    case cancelled
    case unsupported(String)      // e.g. MLX not yet wired
}

public protocol ModelProvider: Sendable {
    /// Stable identifier for the backend (for logging / role resolution).
    var id: String { get }

    /// Stream a turn. The returned stream yields `RawEvent`s and finishes
    /// after a `.done` event, or throws a `ProviderError` on failure. The
    /// implementation MUST tear down the underlying connection in the
    /// stream's `onTermination` so cancellation propagates.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<RawEvent, Error>

    /// Tear down the in-flight generation for `streamID`, if any.
    func cancel(streamID: UUID) async
}
