//
//  MLXBackend.swift  (real implementation)
//
//  Apple-Silicon-native MLX inference, in-process. Replaces the
//  flattening anti-echo hack in the original AgentOS with structured
//  tool messages (Route B from the original docs).
//
//  This file is a P0 stub — it declares the type and conforms to
//  InferenceBackend so the CLI and app link against the real symbol,
//  but the actual model load + stream is gated behind a TODO until
//  mlx-swift is wired up as a dependency in Package.swift (P2).
//
//  When mlx-swift is enabled, the implementation roughly looks like:
//
//      import MLX
//      import MLXLLM         // from mlx-swift-examples or mlx-swift-lm
//
//      let container = try await LLMModelFactory.shared.loadContainer(
//          configuration: ModelConfiguration(id: model.id)
//      )
//      let session = ChatSession(container: container, tools: tools)
//      for await delta in session.streamDetails(messages: structuredMessages) {
//          continuation.yield(.contentDelta(delta.text ?? ""))
//          if let tc = delta.toolCall { continuation.yield(.toolCallDelta(...)) }
//      }
//
//  Until that's in place the backend reports unsupported so the agent
//  loop fails loudly rather than silently.
//

import Foundation
import AgentCore

public actor MLXBackend: InferenceBackend {
    public let identifier: BackendIdentifier = .mlx

    public init() {}

    public func listModels() async throws -> [ModelDescriptor] {
        // P0: return locally downloaded MLX models from HF cache.
        let hfCache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: hfCache, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { url -> ModelDescriptor? in
            let name = url.lastPathComponent
            // HF cache layout: models--<org>--<repo>
            guard name.hasPrefix("models--") else { return nil }
            // HF cache: models--<org>--<repo> (split on "--", not "-").
            // Single-segment: models--gpt2 → gpt2.
            let rest = String(name.dropFirst("models--".count))
            let parts = rest.components(separatedBy: "--").filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            let repoId = parts.joined(separator: "/")
            return ModelDescriptor(id: repoId, displayName: repoId, backend: .mlx, supportsTools: true)
        }
    }

    public func warmUp(model: ModelDescriptor) async throws {
        throw BackendError.unsupported("MLX backend pending mlx-swift dependency (Phase P2). See Sources/MLXBackend/MLXBackend.swift.")
    }

    public nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: BackendError.unsupported("MLX backend pending — use LM Studio or llama.cpp for P0."))
        }
    }

    public func cancel(streamID: UUID) async {}
}
