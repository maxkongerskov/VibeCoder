//
//  MLXBackendStub.swift
//
//  Stub in AgentCore so the agent loop has a `MLXBackend.descriptor`-
//  shaped seam to route against. The real implementation lives in the
//  `MLXBackend` target (which depends on `mlx-swift`).
//
//  Why a stub in core: it lets us declare the .mlx case in
//  BackendIdentifier and let MLX-aware logic compile without forcing
//  mlx-swift as a dependency of AgentCore. The CLI and app link both
//  AgentCore and MLXBackend; consumers that don't (future Linux build,
//  test runners) get a clean error if they try to use MLX.
//

import Foundation

/// Default no-op MLX backend the agent loop falls back to when the
/// MLX target hasn't been linked. Throws a clear error rather than
/// crashing or silently failing.
public actor MLXBackendUnavailable: InferenceBackend {
    public let identifier: BackendIdentifier = .mlx

    public init() {}
    public func listModels() async throws -> [ModelDescriptor] { [] }
    public func warmUp(model: ModelDescriptor) async throws {
        throw BackendError.unsupported(Self.notShippedMessage)
    }
    public nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: BackendError.unsupported(Self.notShippedMessage))
        }
    }

    /// User-facing: in-process MLX is a stub (mlx-swift not wired). Linking
    /// the MLXBackend target does not enable generation.
    public static let notShippedMessage =
        "In-process MLX generation is not shipped. Use LM Studio, Ollama, oMLX, Unsloth Studio, EXO, or a custom OpenAI-compatible server."

    public func cancel(streamID: UUID) async {}
}
