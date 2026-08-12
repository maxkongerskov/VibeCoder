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
        throw BackendError.unsupported("MLX backend not linked in this build. Run `swift build` with the MLXBackend target enabled.")
    }
    public nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: BackendError.unsupported("MLX backend not linked."))
        }
    }
    public func cancel(streamID: UUID) async {}
}
