//
//  MemoryConsolidator.swift
//  D3 — optional LLM (or inject) dream consolidation; extractive remains default.
//
//  Honesty:
//  - Default path is **extractive** (no model call).
//  - LLM consolidator is **opt-in** via AgentLoop.Configuration.dreamLLMEnabled
//    or an injected `dreamConsolidator`. Fail-open to extractive on error/empty.
//  - Still **no embeddings** / vector store.
//

import Foundation

/// Consolidates session-log blob (+ optional existing MEMORY) into durable notes.
public protocol MemoryConsolidating: Sendable {
    /// Return markdown notes to append to workspace MEMORY.md.
    /// Return empty or a string containing `NO_REPLY` to skip append
    /// (caller may still fall back to extractive).
    func consolidate(sessionBlob: String) async throws -> String
}

/// Deterministic extractive consolidator (same body as `MemoryDream.extractiveConsolidate`).
public struct ExtractiveMemoryConsolidator: MemoryConsolidating {
    public init() {}

    public func consolidate(sessionBlob: String) async throws -> String {
        MemoryDream.extractiveConsolidate(sessionBlob)
    }
}

/// Test / host injection of a pure function consolidator.
public struct ClosureMemoryConsolidator: MemoryConsolidating {
    private let body: @Sendable (String) -> String

    public init(_ body: @escaping @Sendable (String) -> String) {
        self.body = body
    }

    public func consolidate(sessionBlob: String) async throws -> String {
        body(sessionBlob)
    }
}

/// Optional production consolidator: one short no-tools chat completion.
///
/// Failures throw so `MemoryBackend.dreamIfNeeded` can fall back to extractive.
public struct LLMMemoryConsolidator: MemoryConsolidating {
    private let backend: any InferenceBackend
    private let model: ModelDescriptor
    private let sampling: SamplingParams
    private let maxInputChars: Int

    public static let systemPrompt = """
    You consolidate project agent session notes into durable MEMORY.
    Output ONLY concise markdown: decisions, constraints, open todos, files that matter.
    No preamble. No tool calls. If nothing durable, reply exactly: NO_REPLY
    """

    public init(
        backend: any InferenceBackend,
        model: ModelDescriptor,
        sampling: SamplingParams = SamplingParams(temperature: 0.2, maxTokens: 600),
        maxInputChars: Int = 24_000
    ) {
        self.backend = backend
        self.model = model
        self.sampling = sampling
        self.maxInputChars = maxInputChars
    }

    public func consolidate(sessionBlob: String) async throws -> String {
        let clipped = String(sessionBlob.prefix(maxInputChars))
        let request = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: .system, content: Self.systemPrompt),
                ChatMessage(role: .user, content: clipped),
            ],
            tools: [],
            sampling: sampling
        )
        var text = ""
        for try await chunk in backend.stream(request: request) {
            switch chunk {
            case .contentDelta(let d):
                text += d
            case .done:
                break
            case .reasoningDelta, .toolCallDelta, .usage:
                continue
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Resolve consolidator for a dream pass (host inject > LLM flag > nil = extractive).
public enum MemoryConsolidatorResolver {
    /// - Parameters:
    ///   - injected: Explicit consolidator (tests / custom host).
    ///   - llmEnabled: When true and no inject, build `LLMMemoryConsolidator`.
    ///   - backend / model: Required when `llmEnabled` is true.
    public static func resolve(
        injected: (any MemoryConsolidating)?,
        llmEnabled: Bool,
        backend: (any InferenceBackend)?,
        model: ModelDescriptor?
    ) -> (any MemoryConsolidating)? {
        if let injected { return injected }
        guard llmEnabled, let backend, let model else { return nil }
        return LLMMemoryConsolidator(backend: backend, model: model)
    }
}
