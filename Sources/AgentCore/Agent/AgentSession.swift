//
//  AgentSession.swift
//
//  Turn-loop actor that wraps `AgentLoop.run` and emits granular
//  `AgentEvent`s. Mirrors BuildCode's `SessionActor` pattern: a dedicated
//  async actor that drives one user turn end-to-end, emitting events for
//  the UI to consume.
//
//  This extraction separates "run one turn" from "manage view state",
//  making both easier to test independently. It also centralizes:
//    - Tool execution tracking (which tools ran, their status)
//    - Context compaction stats (how many tokens were elided)
//    - Turn duration and iteration metrics

import Foundation

/// A single-turn agent session. Created by `ChatViewModel.send()`,
/// driven to completion via `execute(userMessage:conversation:)`, and
/// emits granular events through the callback for UI updates.
public actor AgentSession {

    /// The agent definition — backend, model, tools, config.
    private let definition: AgentDefinition

    /// The tool registry — shared across sessions but scoped per turn.
    private let toolRegistry: ToolRegistry

    /// Turn metrics — populated after execute() completes.
    private var _metrics: TurnMetrics?

    /// Initialize a session from an agent definition.
    public init(definition: AgentDefinition, toolRegistry: ToolRegistry = .shared) {
        self.definition = definition
        self.toolRegistry = toolRegistry
    }

    /// Metrics collected during the last executed turn.
    public var metrics: TurnMetrics? { _metrics }

    /// Internal state holder for turn metrics — actor-isolated to avoid
    /// Sendable closure capture warnings.
    private struct TurnState: Sendable {
        let start: Date
        var iterationCount = 0
        var toolCallCount = 0
        var compactionCount = 0
    }

    private var turnState: TurnState?

    /// Record a LoopEvent for metrics tracking — called from the Sendable
    /// event callback, forwards to actor context for mutation safety.
    private func recordEvent(_ event: LoopEvent) {
        switch event {
        case .iterationStarted: turnState?.iterationCount += 1
        case .toolStarted:      turnState?.toolCallCount += 1
        case .contextCompacted: turnState?.compactionCount += 1
        default: break
        }
    }

    /// Execute one turn: drive the agent loop to completion and emit
    /// granular events for each sub-step. Returns the updated conversation
    /// (with all messages, tool calls, and results appended).
    ///
    /// - Parameters:
    ///   - userMessage: The raw text the user sent.
    ///   - conversation: The current conversation state (messages, model ID).
    ///   - onEvent: Callback for each granular `AgentEvent`. Called on the
    ///              caller's executor — the caller must dispatch to MainActor
    ///              if UI updates are needed.
    /// - Returns: The updated conversation after the turn completes (graceful
    ///            on cancellation — open tool calls are closed with synthetic results).
    public func execute(
        userMessage: String,
        conversation: Conversation,
        images: [ChatImagePayload] = [],
        /// Stable id for an optimistic user bubble already shown in the UI.
        userMessageId: UUID? = nil,
        onEvent: @escaping (@Sendable (AgentEvent) async -> Void)
    ) async throws -> Conversation {

        turnState = TurnState(start: Date())

        // Emit turn start. The user message is wrapped, appended, and
        // emitted by `AgentLoop.run()` below — doing it here too would
        // add the message twice (once in this layer, once inside
        // loop.run), which surfaces to the user as a duplicated chat
        // bubble and to the model as two copies of the same prompt.
        // The pre-AgentSession version called loop.run() directly, so
        // the loop has always owned this responsibility.
        await onEvent(.turnStarted)

        // Build the AgentLoop and run it.
        let loop = AgentLoop(
            backend: definition.backend,
            model: definition.model,
            registry: toolRegistry,
            config: definition.loopConfig
        )

        let finalConvo = try await loop.run(
            userMessage: userMessage,
            conversation: conversation,
            sampling: definition.sampling,
            images: images,
            userMessageId: userMessageId,
            events: { loopEvent in
                // Track metrics via actor-isolated method.
                await self.recordEvent(loopEvent)

                // Convert and forward.
                for event in AgentEvent.from(loopEvent) {
                    await onEvent(event)
                }
            }
        )

        // Capture turn metrics.
        if let state = turnState {
            _metrics = TurnMetrics(
                duration: Date().timeIntervalSince(state.start),
                iterations: state.iterationCount,
                toolCalls: state.toolCallCount,
                compactions: state.compactionCount,
                maxIterations: definition.loopConfig.maxIterations
            )
        }

        return finalConvo
    }
}

/// Metrics collected during a single agent turn.
public struct TurnMetrics: Sendable {
    /// Wall-clock duration of the turn in seconds.
    public let duration: TimeInterval

    /// Number of agent iterations (model calls) in this turn.
    public let iterations: Int

    /// Total tool calls executed across all iterations.
    public let toolCalls: Int

    /// Number of context compactions performed (tokens elided).
    public let compactions: Int

    /// Configured max iterations for this turn (for cap detection).
    public let maxIterations: Int

    public init(
        duration: TimeInterval,
        iterations: Int,
        toolCalls: Int,
        compactions: Int,
        maxIterations: Int = 30
    ) {
        self.duration = duration
        self.iterations = iterations
        self.toolCalls = toolCalls
        self.compactions = compactions
        self.maxIterations = maxIterations
    }

    /// Whether the turn hit its iteration cap.
    public var hitIterationCap: Bool {
        iterations >= maxIterations
    }

    /// Human-readable summary (e.g., "2.3s · 5 iterations · 12 tool calls").
    public var summary: String {
        let seconds = String(format: "%.1f", duration)
        return "\(seconds)s · \(iterations) iterations · \(toolCalls) tool calls"
    }
}
