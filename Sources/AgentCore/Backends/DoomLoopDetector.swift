//
//  DoomLoopDetector.swift
//
//  Client-side doom-loop detection for the streaming layer, ported from
//  Grok Build's `xai-grok-sampler/src/doom_loop.rs` + the agent-level
//  reflection nudge already in ChatLoop.
//
//  TWO SIGNAL SOURCES:
//
//  1. SERVER-REPORTED (Grok Build parity): cloud APIs can emit a custom
//     SSE event `response.doom_loop_check` with triggers like
//     `tail_repetition:4@thinking`. This is the server saying "the model
//     has repeated itself N times in its reasoning". We absorb these,
//     dedupe by raw label, and surface an abort when the confidence
//     threshold is met. Local backends (llama.cpp, LM Studio) don't emit
//     this — it's a cloud-API feature — but the absorption is harmless.
//
//  2. CLIENT-SIDE TOOL-CALL REPETITION (VibeCoder extension): even
//     without server signals, the agent can get stuck calling the same
//     tool with identical arguments 3+ times in a row. This is the
//     transport-level equivalent of ChatLoop's `shouldNudgeReflection`,
//     detected here at the streaming layer so we can inject a recovery
//     backoff without waiting for the full turn to complete.
//
//  RECOVERY POLICY: when triggered, we inject a short backoff
//  (0–250ms) and append a `course-correction` system message. This
//  matches Grok Build's `doom_loop_backoff` (near-immediate resample
//  because loops are stochastic at sampling temperature) rather than
//  the long transport-retry backoff (2–30s).
//

import Foundation

// MARK: - DoomLoopSignal

/// A single doom-loop trigger as reported by the server or detected
/// client-side. Mirrors Grok Build's `DoomLoopSignal` shape.
public struct DoomLoopSignal: Sendable, Equatable {
    /// The raw label (e.g. `tail_repetition:4@thinking`). Stable
    /// identity for deduplication — servers re-send cumulative sets.
    public let raw: String
    /// Categorized kind. `tailRepetition(N)` means the model repeated
    /// its last N outputs; `lowLogprob` means token confidence crashed.
    public let kind: DoomLoopSignalKind

    public init(raw: String, kind: DoomLoopSignalKind) {
        self.raw = raw
        self.kind = kind
    }
}

/// The category of a doom-loop signal.
public enum DoomLoopSignalKind: Sendable, Equatable {
    /// Model is repeating its last N outputs (tail repetition).
    case tailRepetition(Int)
    /// Token log-probability dropped below the confidence floor.
    case lowLogprob
    /// Unclassified / server-specific trigger we don't have a model for.
    case other(String)

    /// Human-readable label for logging/diagnostics.
    public var label: String {
        switch self {
        case .tailRepetition(let n): return "tail_repetition:\(n)"
        case .lowLogprob: return "low_logprob"
        case .other(let s): return s
        }
    }
}

// MARK: - DoomLoopDetector

/// Accumulates doom-loop signals across one streaming attempt and decides
/// when to abort. Created fresh per attempt so signals from a failed
/// attempt can never leak into the next (matching Grok Build's per-attempt
/// `DoomLoopSignalCollector`).
///
/// Thread-safe via an internal mutex (actor would add hop latency on the
/// hot SSE path; a lock is correct and simpler here).
public final class DoomLoopDetector: @unchecked Sendable {

    /// Recovery policy: how many confident triggers before we abort?
    public struct Policy: Sendable {
        /// Number of confident signals required to trigger an abort.
        /// Grok Build default: 1 (any single high-confidence signal).
        public let triggerThreshold: Int
        /// Max retries after a doom-loop abort before we give up.
        public let maxRetries: Int

        public init(triggerThreshold: Int = 1, maxRetries: Int = 2) {
            self.triggerThreshold = triggerThreshold
            self.maxRetries = maxRetries
        }
    }

    private let lock = NSLock()
    private var signals: [DoomLoopSignal] = []
    private var malformedLogged = false
    private let policy: Policy
    private var abortDisarmed = false

    public init(policy: Policy = .init()) {
        self.policy = policy
    }

    // MARK: - Signal absorption

    /// Inspect a raw SSE frame's event name + data for doom-loop signals.
    ///
    /// The server-sent `response.doom_loop_check` event carries triggers
    /// in its payload. We parse the JSON, extract trigger labels, and
    /// record them. Returns `true` if this frame should be swallowed
    /// (the check event is non-standard and would fail typed deserialization
    /// if forwarded to the chunk mapper).
    ///
    /// For local backends that never send this event, this is a no-op —
    /// the parsing is cheap (one JSON decode) and harmless.
    public func absorb(eventName: String, data: String) -> Bool {
        let isCheckEvent = eventName == "response.doom_loop_check"
            || data.contains("\"doom_loop_check\"")

        // No doom-loop content → not a check event; let the caller
        // forward it to the chunk mapper as normal.
        guard isCheckEvent else { return false }

        // Parse the payload for triggers. We're tolerant: malformed JSON,
        // missing fields, or unexpected types are all swallowed (logged
        // once per attempt) so a bad server can't crash the stream.
        guard let jsonData = data.data(using: .utf8),
              let parsed = parseDoomLoopPayload(jsonData) else {
            logMalformedOnce()
            return isCheckEvent   // swallow even if unparseable
        }

        if parsed.isEmpty {
            logMalformedOnce()
        } else {
            record(parsed)
        }
        return isCheckEvent
    }

    /// Record client-side tool-call repetition (the VibeCoder extension).
    ///
    /// Called by the agent loop when it detects that the model has called
    /// the same tool with identical arguments N times in a row. This is
    /// the transport-level signal that complements ChatLoop's reflection nudge.
    public func recordClientRepetition(_ count: Int) {
        let signal = DoomLoopSignal(
            raw: "tool_repetition:\(count)",
            kind: .tailRepetition(count)
        )
        record([signal])
    }

    // MARK: - Decision

    /// While armed: the raw labels of confident signals recorded so far
    /// (non-draining), or `nil` when there's nothing to act on.
    ///
    /// Once `disarmAbort()` is called (after the recovery budget is spent),
    /// this returns nil so the final attempt completes and can be accepted.
    public func abortTriggers() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        guard !abortDisarmed else { return nil }

        // Filter to "confident" signals: tail_repetition >= 4, or any
        // lowLogprob. This matches Grok Build's `policy.confident_triggers`.
        let confident = signals.filter { signal in
            switch signal.kind {
            case .tailRepetition(let n) where n >= 4: return true
            case .lowLogprob: return true
            default: return false
            }
        }

        guard confident.count >= policy.triggerThreshold else { return nil }
        return confident.map(\.raw)
    }

    /// Stop the mid-stream abort for this attempt; signals keep recording
    /// but won't trigger further aborts. Called by the retry loop once
    /// the recovery budget is spent so the final attempt completes.
    public func disarmAbort() {
        lock.lock()
        abortDisarmed = true
        lock.unlock()
    }

    /// Drain all recorded signals (for diagnostics / logging).
    public func take() -> [DoomLoopSignal] {
        lock.lock()
        defer { lock.unlock() }
        return signals
    }

    // MARK: - Internal

    private func record(_ newSignals: [DoomLoopSignal]) {
        lock.lock()
        defer { lock.unlock() }
        // Dedup by raw label — servers re-send cumulative sets as they grow.
        for signal in newSignals {
            if !signals.contains(where: { $0.raw == signal.raw }) {
                signals.append(signal)
            }
        }
    }

    private func logMalformedOnce() {
        lock.lock()
        defer { lock.unlock() }
        if !malformedLogged {
            malformedLogged = true
            #if DEBUG
            print("[DoomLoopDetector] malformed check payload; ignoring")
            #endif
        }
    }

    /// Parse a `doom_loop_check` JSON payload into signals.
    ///
    /// Expected shape: `{"type":"response.doom_loop_check","doom_loop_check":{"triggers":["tail_repetition:4@thinking"]}}`
    /// We extract the `triggers` array and parse each label into a
    /// `DoomLoopSignal`. Tolerant: any field can be missing or malformed.
    private func parseDoomLoopPayload(_ data: Data) -> [DoomLoopSignal]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // The triggers live under `doom_loop_check.triggers` OR at top level.
        let checkDict = json["doom_loop_check"] as? [String: Any] ?? json
        guard let triggers = checkDict["triggers"] as? [Any] else { return [] }

        return triggers.compactMap { trigger -> DoomLoopSignal? in
            guard let label = trigger as? String else { return nil }
            return parseTriggerLabel(label)
        }
    }

    /// Parse a trigger label string into a `DoomLoopSignal`.
    ///
    /// Known formats (from Grok Build's `xai_grok_sampling_types`):
    ///   - `tail_repetition:N@context` — model repeated its last N outputs
    ///   - `low_logprob@response` — token confidence dropped
    ///   - Other labels are recorded as `.other` for forward-compat.
    private func parseTriggerLabel(_ label: String) -> DoomLoopSignal {
        if label.hasPrefix("tail_repetition:") {
            // Extract the count: "tail_repetition:4@thinking" → 4
            let rest = String(label.dropFirst("tail_repetition:".count))
            let countStr = rest.split(separator: "@").first.map(String.init) ?? rest
            let n = Int(countStr) ?? 0
            return DoomLoopSignal(raw: label, kind: .tailRepetition(n))
        }
        if label.contains("low_logprob") {
            return DoomLoopSignal(raw: label, kind: .lowLogprob)
        }
        return DoomLoopSignal(raw: label, kind: .other(label))
    }
}

// MARK: - Recovery action

/// The action to take when a doom-loop is detected. Returned by the
/// detector so the streaming layer can decide how to respond.
public enum DoomLoopAction: Sendable {
    /// No action — keep streaming normally.
    case proceed
    /// Abort this attempt and retry with a fresh sample. The backoff
    /// is short (0–250ms) because loops are stochastic at sampling
    /// temperature; a fresh sample is the remedy.
    case abortAndResample(delay: TimeInterval)
}