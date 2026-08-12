//
//  EventStreamProvider.swift
//
//  Abstraction over the agent turn's event stream. Provides a protocol
//  that produces `AgentEvent` sequences — granular events matching
//  BuildCode's HarnessEvent pattern (textDelta, thinkingDelta, toolStarted/
//  Updated/Finished, phase completion).
//
//  The default implementation (`LoopEventStreamProvider`) wraps the existing
//  `AgentLoop` and converts its coarse `LoopEvent`s into fine-grained
//  `AgentEvent`s via `AgentEvent.from(_:)`. Future implementations can
//  produce events natively (e.g., OMLXBackend streaming directly into
//  AgentEvent without the LoopEvent intermediate).

import Foundation

/// Protocol for producing granular agent events during a single turn.
/// Callers invoke `runTurn` with the user message and conversation state;
/// the provider yields an AsyncStream of AgentEvents that the UI consumes.
public protocol EventStreamProvider: Sendable {

    /// Configuration for this turn (iteration cap, safety settings, etc.).
    associatedtype ConfigType: Sendable

    /// Run one turn and yield granular events.
    /// - Parameters:
    ///   - userMessage: The composed user message (text + attachments).
    ///   - conversation: The conversation state at turn start.
    ///   - config: Turn configuration (safety, budget, tools).
    ///   - events: Callback invoked for each granular AgentEvent.
    /// - Returns: The final conversation state after the turn completes.
    func runTurn(
        userMessage: String,
        conversation: Conversation,
        config: ConfigType,
        events: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws -> Conversation
}

// MARK: - Default implementation (wraps AgentLoop)

/// EventStreamProvider backed by the existing `AgentLoop`. Converts
/// LoopEvent → AgentEvent via `AgentEvent.from(_:)` for each event.
public final class LoopEventStreamProvider: EventStreamProvider, @unchecked Sendable {

    private let backend: any InferenceBackend
    private let model: ModelDescriptor
    private let config: AgentLoop.Configuration

    public init(
        backend: any InferenceBackend,
        model: ModelDescriptor,
        config: AgentLoop.Configuration
    ) {
        self.backend = backend
        self.model = model
        self.config = config
    }

    public func runTurn(
        userMessage: String,
        conversation: Conversation,
        config: AgentLoop.Configuration,
        events: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws -> Conversation {
        // Wrap the LoopEvent callback to convert each event into AgentEvent.
        let agentEvents: @Sendable (LoopEvent) async -> Void = { loopEvent in
            let agentEvents = AgentEvent.from(loopEvent)
            for event in agentEvents {
                await events(event)
            }
        }

        let loop = AgentLoop(backend: backend, model: model, config: self.config)
        return try await loop.run(
            userMessage: userMessage,
            conversation: conversation,
            sampling: nil, // TODO: pass sampling from caller via ConfigType
            events: agentEvents
        )
    }
}

// MARK: - OMLX-native provider (future)

/// Placeholder for an OMLX-specific EventStreamProvider that would
/// stream directly from the MLX inference server into AgentEvent
/// without going through the LoopEvent intermediate. This allows
/// the UI to receive events with lower latency when using oMLX.
// public final class OMLXEventStreamProvider: EventStreamProvider {
//     public typealias ConfigType = OMLXRunConfig
//
//     // ... implementation would stream directly from oMLX API
// }
