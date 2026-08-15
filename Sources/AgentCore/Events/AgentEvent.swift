//
//  AgentEvent.swift
//
//  Granular event stream for the agent turn loop. Replaces the coarse
//  LoopEvent enum with fine-grained events that let the UI render each
//  sub-step independently — matching BuildCode's HarnessEvent pattern:
//    textDelta, thinkingDelta, toolStarted/Updated/Finished (separate),
//    and phase completion events.
//
//  This enum is designed to be consumed by ChatViewModel.consume(event:)
//  and mapped into UI state updates for: streaming content, reasoning
//  blocks, activity lines ("Verb · Status"), and tool call banners.
//

import Foundation

/// Granular events emitted during a single agent turn. Designed to give
/// the UI fine control over rendering without requiring knowledge of the
/// underlying agent loop internals.
public enum AgentEvent: Sendable {

    // MARK: - Turn lifecycle

    /// The turn is starting — UI can show "Starting…" or a spinner.
    case turnStarted

    /// The loop is beginning iteration `n` of maxIterations. Drives
    /// the status line ("Iteration 2…").
    case iterationStarted(iteration: Int)

    /// ZCode parity: a logical "step" is starting. Each iteration of
    /// the agent loop is one step — a model round-trip that may invoke
    /// tools. This event lets the UI render a step-start marker
    /// ("Step N") in the transcript, matching ZCode's per-step display.
    /// Emitted alongside `.iterationStarted` so existing status-line
    /// behavior is unchanged; new UI can opt into step markers.
    case stepStarted(iteration: Int)

    /// ZCode parity: a logical "step" has finished. Carries an
    /// optional one-line summary (e.g. "Edited 3 files" or the finish
    /// reason). Emitted at the end of each iteration, before the next
    /// `.stepStarted` or `.finished`. Lets the UI close out a step
    /// marker with a completion state.
    case stepFinished(iteration: Int, summary: String?)

    /// The user message has been wrapped in a ChatMessage and appended.
    /// UI can render the user bubble immediately (same instance as in
    /// the returned conversation).
    case userMessage(ChatMessage)

    // MARK: - Model output streaming

    /// A chunk of assistant prose text. Accumulates into the streaming
    /// content buffer. Replaces `.contentDelta` from LoopEvent for
    /// clarity (same semantics, clearer naming).
    case textDelta(String)

    /// A chunk of reasoning/thinking tokens. Accumulates into the
    /// streaming reasoning buffer. Replaces `.reasoningDelta` from
    /// LoopEvent with clearer naming.
    case thinkingDelta(String)

    /// The assistant has emitted a complete message (prose + tool calls).
    /// This is the coarse-grained completion of model output — when
    /// received, the UI should finalize the streaming bubble and persist
    /// the message. Carries invocations that seed tool call banners.
    case assistantMessage(ChatMessage)

    // MARK: - Tool execution (granular)

    /// A tool is about to execute. Drives the activity line ("Verb ·
    /// Status") and seeds a pending tool call banner.
    case toolStarted(id: String, name: String, label: String)

    /// A running tool call has received an intermediate update (e.g.,
    /// partial output, progress indication). Used for live updates in
    /// the artifact rail.
    case toolUpdated(id: String, outputSnippet: String)

    /// A tool has finished executing — flips the UI from running to
    /// settled for that specific call. Paired with `.toolStarted`.
    case toolFinished(id: String, name: String, label: String, isError: Bool)

    /// A tool result has been recorded in the conversation history.
    /// Carries both the invocation (for lookup) and the result content.
    case toolResult(invocation: ToolCallInvocation, result: ToolResult)

    // MARK: - BuildGuard / verification

    /// The post-edit build guard passed — drives "Build ✓" status + transcript.
    case buildPassed

    /// The post-edit build guard failed — drives "Build ✗" status and
    /// triggers a retry; log is truncated for UI.
    case buildFailed(log: String)

    /// BuildGuard ran but found no buildable project (docs-only folder, etc.).
    /// Not a success — do not claim the project compiled.
    case buildSkipped(reason: String)

    // MARK: - Loop control

    /// The loop detected the agent is stalled (same tool call repeated).
    case stalled(repeatedSignature: String)

    /// The iteration cap has been reached. Drives "Hit iteration cap (N)".
    case iterationCapHit(cap: Int)

    /// The turn has finished normally. Carries a human-readable reason
    /// ("no more tools", "model said done", etc.).
    case finished(reason: String)

    /// An error occurred during the turn. Flattened to a description
    /// for Sendable compliance; the full error is re-thrown from run().
    case error(description: String)

    /// The loop has suspended and is waiting for human input. Drives
    /// "Waiting for your answer…" status line and surfaces the question card.
    case pendingQuestion(AgentQuestion)

    /// Context compaction ran for the wire history. UI should surface
    /// a short notice (not silent).
    case contextCompacted(summaryPreview: String, droppedMessages: Int)

    /// Actual token usage reported by the model server for the request that
    /// just completed. The UI uses this to calibrate the context meter to
    /// real usage instead of the chars/4 estimate. Never emitted by servers
    /// that don't report usage, so the meter falls back to the estimate.
    case usage(promptTokens: Int, completionTokens: Int)

    /// A file mutation hunk was recorded (hunk tracker).
    case hunkRecorded(hunkID: UUID, path: String)

    /// Informational status — e.g. "Premature stop detected",
    /// "Goal paused: backoff". Shown in the status line without ending
    /// or altering the turn. Lighter-weight than `.error` (fault) or
    /// `.finished` (turn end).
    case info(String)

    /// A background shell or subagent job reached a terminal status
    /// (completed / failed / killed / timedOut). PC4 auto-wake surface —
    /// UI can refresh job rows and show a status notice without ending the
    /// current turn. `taskId` matches get_task_output / wait_tasks / kill_task.
    case backgroundJobCompleted(
        taskId: UUID,
        kind: String,
        status: String,
        summary: String,
        conversationID: UUID?
    )

    /// Custom agent / subagent tool allowlist scrub removed unknown or banned
    /// tools (P8). Parent can show a status line without failing the spawn.
    case toolAllowlistStripped(
        context: String,
        summary: String,
        strippedUnknown: [String],
        strippedBanned: [String]
    )

    // MARK: - LoopEvent → AgentEvent conversion

    /// Convert a coarse-grained `LoopEvent` into one or more granular
    /// `AgentEvent`s. Most LoopEvents map to a single AgentEvent; some
    /// (like `.toolCompleted`) may emit multiple events for finer control.
    static func from(_ event: LoopEvent) -> [AgentEvent] {
        switch event {
        case .iterationStarted(let i):
            return [
                .iterationStarted(iteration: i),
                .stepStarted(iteration: i)
            ]

        case .userMessage(let msg):
            return [.userMessage(msg)]

        case .contentDelta(let s):
            return [.textDelta(s)]

        case .reasoningDelta(let s):
            return [.thinkingDelta(s)]

        case .assistantMessage(let msg):
            // Emit the complete message — UI will finalize streaming and
            // seed tool call banners from msg.toolCalls.
            return [.assistantMessage(msg)]

        case .toolStarted(let id, let name, let label):
            return [
                .toolStarted(id: id, name: name, label: label)
            ]

        case .toolCompleted(let id, let name, let label, let isError):
            // toolCompleted fires AFTER toolResult — it's the final
            // status flip. Map to toolFinished for consistency with
            // the granular pattern. Preserve tool_call id (C2).
            return [.toolFinished(id: id, name: name, label: label, isError: isError)]

        case .toolResult(let inv, let result):
            return [
                .toolResult(invocation: inv, result: result)
            ]

        case .buildPassed:
            return [.buildPassed]

        case .buildFailed(let log):
            return [.buildFailed(log: log)]

        case .buildSkipped(let reason):
            return [.buildSkipped(reason: reason)]

        case .stalled(let sig):
            return [.stalled(repeatedSignature: sig)]

        case .iterationCapHit(let cap):
            return [.iterationCapHit(cap: cap)]

        case .finished(let reason):
            return [
                .stepFinished(iteration: 0, summary: reason),
                .finished(reason: reason)
            ]

        case .error(let desc):
            return [.error(description: desc)]

        case .pendingQuestion(let question):
            return [.pendingQuestion(question)]

        case .info(let msg):
            return [.info(msg)]

        case .stepStarted(let i):
            return [.stepStarted(iteration: i)]

        case .stepFinished(let i, let summary):
            return [.stepFinished(iteration: i, summary: summary)]

        case .contextCompacted(let preview, let dropped):
            return [.contextCompacted(summaryPreview: preview, droppedMessages: dropped)]

        case .usage(let promptTokens, let completionTokens):
            return [.usage(promptTokens: promptTokens, completionTokens: completionTokens)]

        }
    }
}
