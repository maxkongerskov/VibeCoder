//
//  GoalOrchestrator.swift
//
//  Goal-driven loop orchestration: a simplified port of Grok Build's
//  `goal_tracker.rs` state machine + stall detection.
//
//  Grok Build's full system is ~15,000 lines (goal_tracker + classifier
//  + strategist + planner + summarizer). VibeCoder doesn't need all of it
//  (we don't spawn N adversarial skeptic subagents for verification — the
//  model verifies its own work). What we DO need:
//
//    1. GoalStatus state machine: Active → (Complete | Blocked | NoProgress |
//       BackOffPaused | UserPaused). This replaces VibeCoder's current
//       binary "done/not done" with the same statuses Grok Build tracks.
//
//    2. Stall detection: when the model fails to make progress N times in
//       a row with the SAME gap fingerprint, we pause the goal instead of
//       letting it loop forever. This is `record_classifier_stall` in Grok.
//
//    3. Premature-stop defeat: when StopDetector catches the model bailing
//       out, we inject a continuation nudge to keep the goal running (Grok's
//       `GOAL_CONTINUATION_BAIL_PREFACE` behavior).
//
//  WHAT WE DON'T PORT (intentionally, for now):
//    - Multi-agent verifier panel (N skeptic subagents). VibeCoder's model
//      verifies its own work; we don't need a panel.
//    - Strategist (structural remediation after N stalls). Can be added
//      later if stall detection proves insufficient.
//    - Token budget enforcement (`BudgetLimited` status). VibeCoder has
//      its own context-budget system; we don't duplicate it here.
//    - Infra-pause (infrastructure failures). Local backends don't have
//      the same failure modes as cloud APIs.
//

import Foundation

// MARK: - GoalStatus

/// The lifecycle status of a goal-driven turn. Mirrors Grok Build's
/// `GoalStatus` enum, simplified to the statuses VibeCoder uses.
///
/// Transitions:
///   Active → Complete          (goal achieved, verifier confirmed)
///   Active → Blocked           (model can't make progress: unresolvable blocker)
///   Active → NoProgressPaused  (same gap fingerprint N attempts in a row — stall)
///   Active → BackOffPaused     (max retries hit — back off and surface to user)
///   Active → UserPaused        (user cancelled or paused via /goal pause)
///
/// From any state: the user can resume (→ Active) or abandon (→ Complete
/// with a "failed" note). The orchestrator only auto-pauses; it never
/// auto-resumes.
public enum GoalStatus: String, Sendable, Codable, Equatable {
    /// Actively working on the goal. The agent loop continues driving turns.
    case active
    /// Goal achieved — verified by the model. The orchestrator stops.
    case complete
    /// Model hit an unresolvable blocker (e.g. missing dependency, external
    /// API down). Pauses so the user can decide whether to abandon or wait.
    case blocked
    /// No progress detected: same gap fingerprint N attempts in a row.
    /// The goal is stalled — pausing prevents infinite loops (the doom-loop
    /// scenario from Phase B's transport layer, but at the agent level).
    case noProgressPaused
    /// Max retries hit. The model has tried N times and failed each; further
    /// attempts are likely to repeat. Back off and surface to the user.
    case backOffPaused
    /// User explicitly paused (Ctrl+C, /goal pause). Never auto-resumed.
    case userPaused

    /// Is the goal in an active state (should the loop continue driving turns)?
    public var isActive: Bool { self == .active }

    /// Is the goal in a terminal state (loop should stop)?
    public var isTerminal: Bool {
        switch self {
        case .complete, .userPaused: return true
        default: return false
        }
    }

    /// Human-readable label for UI / diagnostics.
    public var label: String {
        switch self {
        case .active:           return "Active"
        case .complete:         return "Complete"
        case .blocked:          return "Blocked (unresolvable)"
        case .noProgressPaused: return "Stalled (no progress)"
        case .backOffPaused:    return "Backed off (max retries)"
        case .userPaused:       return "User-paused"
        }
    }
}

// MARK: - GoalPauseReason

/// Why a goal was paused. Used for telemetry / the `GoalPaused` event.
public enum GoalPauseReason: String, Sendable, Codable {
    case user           // User cancelled or /goal pause
    case backOff        // Max retries hit
    case noProgress     // Stall detected (same gap N times)
    case verification   // Verification failed irrecoverably

    public var label: String {
        switch self {
        case .user:         return "User paused"
        case .backOff:      return "Back-off (max retries exceeded)"
        case .noProgress:   return "No progress (stall detected)"
        case .verification: return "Verification failed"
        }
    }
}

// MARK: - GapFingerprint

/// A stable hash of the "gaps" (unmet criteria) reported in a NotAchieved
/// verification. Used for stall detection: if the same fingerprint repeats
/// N times in a row, the goal is stalled (the model keeps failing the same
/// way) and we pause instead of looping forever.
///
/// Ported from Grok Build's `gap_fingerprint` in `goal_classifier.rs`.
public struct GapFingerprint: Hashable, Sendable {
    public let value: String

    /// Create a fingerprint from the model's reported gaps.
    ///
    /// We normalize by sorting + lowercasing + joining, so two gap lists
    /// with the same items in different orders produce the same fingerprint.
    /// This prevents the model from "defeating" stall detection by
    /// reordering its reported gaps.
    public init(gaps: [String]) {
        let normalized = gaps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
        self.value = normalized.joined(separator: " | ")
    }

    /// Restore a previously persisted fingerprint string (Wave C multi-turn).
    public init(rawValue: String) {
        self.value = rawValue
    }

    /// Empty fingerprint (for goals with no gaps — e.g. Achieved).
    public static let empty = GapFingerprint(gaps: [])
}

// MARK: - GoalOrchestrator

/// Drives a goal-driven turn loop. Stateful (actor-isolated) — the agent
/// loop calls `evaluateTurnEnd()` after each model turn to decide whether
/// to continue, pause, or stop.
///
/// **Stall detection**: tracks the last `gapFingerprint` and a counter for
/// consecutive NotAchieved results with the same fingerprint. When the
/// counter hits `stallThreshold` (default 2, matching Grok Build's
/// `GOAL_CLASSIFIER_STALL_THRESHOLD`), the goal auto-pauses as
/// `.noProgressPaused`.
///
/// **Cap enforcement**: tracks `attemptCount`. When it hits `maxAttempts`
/// (default 5, configurable per goal), the goal auto-pauses as
/// `.backOffPaused` and surfaces to the user.
public actor GoalOrchestrator {

    // Configuration
    public struct Config: Sendable {
        /// Max attempts before backing off. Default 5 (VibeCoder is more
        /// aggressive than Grok Build's ~10 because local backends are
        /// faster to retry — the user sees failures sooner).
        public let maxAttempts: Int
        /// Same gap fingerprint N times in a row → stalled. Default 2,
        /// matching Grok Build's `GOAL_CLASSIFIER_STALL_THRESHOLD`.
        public let stallThreshold: Int

        public init(maxAttempts: Int = 5, stallThreshold: Int = 2) {
            self.maxAttempts = maxAttempts
            self.stallThreshold = stallThreshold
        }
    }

    // State (actor-isolated)
    public private(set) var status: GoalStatus = .active
    public private(set) var attemptCount: Int = 0
    public private(set) var lastFingerprint: GapFingerprint?
    public private(set) var consecutiveStallCount: Int = 0
    public private(set) var pauseReason: GoalPauseReason?
    /// The goal description, set when the orchestrator is created.
    public let goalDescription: String
    private let config: Config

    // History (for diagnostics / the GoalPaused event)
    public struct HistoryEntry: Sendable {
        public let timestamp: Date
        public let event: String       // "attempted", "stalled", "paused", etc.
        public let detail: String?
    }
    public private(set) var history: [HistoryEntry] = []

    public init(goalDescription: String, config: Config = .init()) {
        self.goalDescription = goalDescription
        self.config = config
    }

    /// Restore multi-turn progress (Wave C). Seed counters from a prior run
    /// so stall/maxAttempts accumulate across user messages, not only within
    /// a single `AgentLoop.run`.
    public init(
        goalDescription: String,
        config: Config = .init(),
        seedAttemptCount: Int,
        seedLastFingerprint: String?,
        seedConsecutiveStallCount: Int
    ) {
        self.goalDescription = goalDescription
        self.config = config
        self.attemptCount = max(0, seedAttemptCount)
        if let raw = seedLastFingerprint, !raw.isEmpty {
            self.lastFingerprint = GapFingerprint(rawValue: raw)
        }
        self.consecutiveStallCount = max(0, seedConsecutiveStallCount)
    }

    // MARK: - Turn evaluation

    /// Called by the agent loop at turn-end with the model's result.
    ///
    /// - Parameter achieved: Did the model claim (and verify) that the goal
    ///   is complete? If true, status flips to `.complete` and we return
    ///   `.stop` (the loop should end — goal achieved).
    /// - Parameter gaps: The model's reported unmet criteria (for stall
    ///   detection). Empty if achieved. Used to build the gap fingerprint.
    ///
    /// - Returns: The action the agent loop should take:
    ///   `.continue` (keep driving turns), `.stop` (goal complete or user
    ///   paused — end the loop), or `.pause(reason)` (stop driving, surface
    ///   to user).
    public func evaluateTurnEnd(achieved: Bool, gaps: [String]) -> GoalAction {
        guard status == .active else {
            return .stop  // Already paused/complete — shouldn't be driving turns.
        }

        attemptCount += 1
        let now = Date()

        // Goal achieved → complete.
        if achieved {
            status = .complete
            history.append(.init(timestamp: now, event: "achieved", detail: nil))
            return .stop
        }

        // Stall detection: compute fingerprint, compare to last.
        let fingerprint = GapFingerprint(gaps: gaps)
        if let last = lastFingerprint, last == fingerprint {
            consecutiveStallCount += 1
        } else {
            consecutiveStallCount = 0
            lastFingerprint = fingerprint
        }

        // Stall threshold hit → NoProgressPaused.
        if consecutiveStallCount >= config.stallThreshold {
            status = .noProgressPaused
            pauseReason = .noProgress
            history.append(.init(timestamp: now, event: "paused",
                                detail: "Stall detected (gap fingerprint repeated \(consecutiveStallCount)×)"))
            return .pause(reason: .noProgress)
        }

        // Cap hit → BackOffPaused.
        if attemptCount >= config.maxAttempts {
            status = .backOffPaused
            pauseReason = .backOff
            history.append(.init(timestamp: now, event: "paused",
                                detail: "Max attempts (\(config.maxAttempts)) reached"))
            return .pause(reason: .backOff)
        }

        // Not achieved but not stalled or capped — continue driving.
        history.append(.init(timestamp: now, event: "attempted",
                            detail: "\(attemptCount)/\(config.maxAttempts), gaps: \(gaps.count)"))
        return .continue
    }

    /// Mark the goal as blocked (model hit an unresolvable blocker).
    public func markBlocked(reason: String) {
        guard status == .active else { return }
        status = .blocked
        pauseReason = .verification
        history.append(.init(timestamp: Date(), event: "blocked", detail: reason))
    }

    /// User paused the goal (Ctrl+C, /goal pause).
    public func userPause() {
        guard status == .active else { return }
        status = .userPaused
        pauseReason = .user
        history.append(.init(timestamp: Date(), event: "user_paused", detail: nil))
    }

    /// Reset stall tracking (e.g. after a strategist fires and changes
    /// approach). The next attempt starts with a fresh stall counter.
    public func resetStallTracking() {
        consecutiveStallCount = 0
        lastFingerprint = nil
    }

    /// Snapshot the current state for diagnostics / UI.
    public struct Snapshot: Sendable {
        public let status: GoalStatus
        public let attemptCount: Int
        public let maxAttempts: Int
        public let consecutiveStallCount: Int
        public let stallThreshold: Int
        public let pauseReason: GoalPauseReason?
        public let goalDescription: String
        /// Wave C2: multi-turn stall seed (empty when none).
        public let lastFingerprintValue: String?
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            status: status,
            attemptCount: attemptCount,
            maxAttempts: config.maxAttempts,
            consecutiveStallCount: consecutiveStallCount,
            stallThreshold: config.stallThreshold,
            pauseReason: pauseReason,
            goalDescription: goalDescription,
            lastFingerprintValue: lastFingerprint?.value
        )
    }

    /// Machine-readable progress line for UI multi-turn seed (Wave C2).
    public func progressInfoLine() -> String {
        let snap = snapshot()
        let fp = snap.lastFingerprintValue ?? ""
        return "goal-progress attempts=\(snap.attemptCount) stall=\(snap.consecutiveStallCount) "
            + "fp=\(fp) status=\(snap.status.rawValue)"
    }
}

// MARK: - GoalAction

/// What the agent loop should do after evaluating a turn.
public enum GoalAction: Sendable, Equatable {
    /// Keep driving turns — the goal is still active and making progress.
    case `continue`
    /// Stop the loop entirely — goal achieved or user-paused (terminal).
    case stop
    /// Pause the loop and surface to the user. The goal is NOT complete;
    /// we just can't make progress without intervention.
    case pause(reason: GoalPauseReason)
}