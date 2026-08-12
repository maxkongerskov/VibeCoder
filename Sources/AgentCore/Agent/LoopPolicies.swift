//
//  LoopPolicies.swift
//
//  Concrete reliability policies and named profiles. The difference between
//  interactive, headless, and raw runs is which profile the loop is built
//  with — not a tangle of mode checks scattered through the loop body.
//

import Foundation

// MARK: - Hard stops

public struct IterationCapPolicy: TurnPolicy {
    public init() {}
    public func evaluate(_ s: TurnSnapshot) -> PolicyDirective {
        // Cap means "do not start another model iteration after N".
        // When iteration == maxIterations the Nth model response is still
        // in flight — allow tools / natural finish. Halt only when we have
        // already exceeded the configured budget (should not happen under
        // the normal while iteration < max loop).
        s.iteration > s.maxIterations
            ? .halt(reason: "reached the \(s.maxIterations)-iteration limit for this turn")
            : .proceed
    }
}

public struct GovernorPolicy: TurnPolicy {
    public let config: GovernorConfig
    public init(config: GovernorConfig = .init()) { self.config = config }
    public func evaluate(_ s: TurnSnapshot) -> PolicyDirective {
        let output: (tool: String, bytes: Int)? = {
            guard let last = s.lastToolOutput,
                  !s.readOnlyToolNames.contains(last.tool) else { return nil }
            return (tool: last.tool, bytes: last.bytes)
        }()
        if let signal = Governor.evaluate(recentToolCalls: s.recentToolCalls,
                                          recentErrorCounts: s.recentErrorCounts,
                                          lastToolOutput: output,
                                          config: config) {
            return .halt(reason: signal.describe)
        }
        return .proceed
    }
}

public struct StallPolicy: TurnPolicy {
    public init() {}
    public func evaluate(_ s: TurnSnapshot) -> PolicyDirective {
        if let reason = ChatLoop.detectStuckPattern(
            s.recentToolSignatures,
            repetitionThreshold: s.stallWindow) {
            return .halt(reason: "stalled — \(reason)")
        }
        return .proceed
    }
}

// MARK: - Verify-before-finish

public struct GroundingPolicy: TurnPolicy {
    private let maxForces = 2
    public init() {}
    public func evaluate(_ s: TurnSnapshot) -> PolicyDirective {
        guard s.modelWantsToFinish else { return .proceed }
        guard s.groundingForceCount < maxForces else { return .proceed }
        guard ChatLoop.shouldVerifyBeforeFinish(recentToolErrorFlags: s.recentErrorFlags,
                                                finalAssistantContent: s.lastAssistantContent)
        else { return .proceed }
        let nudge = s.groundingForceCount > 0
            ? ChatLoop.groundingNudgeEscalated
            : ChatLoop.groundingNudge
        return .forceContinue(nudge: nudge, reason: PolicyForceReason.grounding)
    }
}

public struct EditVerifyPolicy: TurnPolicy {
    private let maxForces = 2
    public init() {}
    public func evaluate(_ s: TurnSnapshot) -> PolicyDirective {
        guard s.modelWantsToFinish else { return .proceed }
        guard s.editVerifyForceCount < maxForces else { return .proceed }
        guard ChatLoop.shouldVerifyEdits(messages: s.messages,
                                         turnStartIndex: s.turnStartIndex,
                                         mutatingToolNames: s.mutatingToolNames,
                                         verificationToolNames: s.verificationToolNames,
                                         alreadyVerified: false)
        else { return .proceed }
        let nudge = s.editVerifyForceCount > 0
            ? ChatLoop.verifyEditsNudgeEscalated
            : ChatLoop.verifyEditsNudge
        return .forceContinue(nudge: nudge, reason: PolicyForceReason.editVerify)
    }
}

// MARK: - Soft nudges

public struct ReflectionPolicy: TurnPolicy {
    public init() {}
    public func evaluate(_ s: TurnSnapshot) -> PolicyDirective {
        guard s.allowReflectionNudge else { return .proceed }
        guard !s.reflectionAlreadyNudged,
              ChatLoop.shouldNudgeReflection(recentToolErrorFlags: s.recentErrorFlags)
        else { return .proceed }
        return .nudge(ChatLoop.reflectionNudge)
    }
}

public struct DecisionLogPolicy: TurnPolicy {
    public init() {}
    public func evaluate(_ s: TurnSnapshot) -> PolicyDirective {
        guard !s.decisionAlreadyNudged,
              ChatLoop.shouldNudgeDecisionLogging(iterations: s.iteration, messages: s.messages)
        else { return .proceed }
        return .nudge(ChatLoop.decisionLoggingNudge)
    }
}

// MARK: - Profiles

public enum PolicyProfile {
    public static let common: [any TurnPolicy] = [
        IterationCapPolicy(),
        StallPolicy(),
        GovernorPolicy(),
    ]

    public static func interactive() -> PolicyEngine {
        PolicyEngine(common + [GroundingPolicy(), EditVerifyPolicy()])
    }

    public static func headless() -> PolicyEngine {
        PolicyEngine(common + [
            GroundingPolicy(),
            EditVerifyPolicy(),
            ReflectionPolicy(),
            DecisionLogPolicy(),
        ])
    }

    /// Chat mode (legacy “raw”): iteration cap only — no stall, governor, or nudges.
    public static func raw() -> PolicyEngine {
        PolicyEngine([IterationCapPolicy()])
    }

    /// Alias for chat-mode policy profile.
    public static func chat() -> PolicyEngine { raw() }

    public static func engine(headless isHeadless: Bool, raw isRaw: Bool) -> PolicyEngine {
        if isRaw { return raw() }
        if isHeadless { return headless() }
        return interactive()
    }
}