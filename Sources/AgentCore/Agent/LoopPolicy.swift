//
//  LoopPolicy.swift
//
//  Reliability policies as pure value-type functions over an immutable
//  snapshot. A policy never mutates the conversation, never emits events,
//  and never suspends — it reads a `TurnSnapshot` and returns a
//  `PolicyDirective`. The loop owns all side effects.
//

import Foundation

/// A single tool output's size, for the governor's runaway check.
public struct ToolOutputInfo: Sendable, Equatable {
    public let tool: String
    public let bytes: Int
    public init(tool: String, bytes: Int) { self.tool = tool; self.bytes = bytes }
}

/// An immutable view of the turn so far. The loop builds one each iteration.
public struct TurnSnapshot: Sendable {
    public let iteration: Int
    public let maxIterations: Int
    public let modelWantsToFinish: Bool
    public let lastAssistantContent: String
    public let messages: [ChatMessage]
    public let turnStartIndex: Int
    public let recentToolSignatures: [String]
    public let recentErrorFlags: [Bool]
    public let recentToolCalls: [ToolCallSnapshot]
    public let recentErrorCounts: [Int]
    public let lastToolOutput: ToolOutputInfo?
    public let groundingForceCount: Int
    public let editVerifyForceCount: Int
    public let reflectionAlreadyNudged: Bool
    public let decisionAlreadyNudged: Bool
    /// When false, reflection nudges are rate-limited by the loop.
    public let allowReflectionNudge: Bool
    public let mutatingToolNames: Set<String>
    public let verificationToolNames: Set<String>
    /// Registered read-only tools — governor runaway check skips these.
    public let readOnlyToolNames: Set<String>
    /// Identical-signature repetition count before StallPolicy halts.
    public let stallWindow: Int

    public init(iteration: Int,
                maxIterations: Int,
                modelWantsToFinish: Bool,
                lastAssistantContent: String,
                messages: [ChatMessage],
                turnStartIndex: Int,
                recentToolSignatures: [String] = [],
                recentErrorFlags: [Bool] = [],
                recentToolCalls: [ToolCallSnapshot] = [],
                recentErrorCounts: [Int] = [],
                lastToolOutput: ToolOutputInfo? = nil,
                groundingForceCount: Int = 0,
                editVerifyForceCount: Int = 0,
                reflectionAlreadyNudged: Bool = false,
                decisionAlreadyNudged: Bool = false,
                allowReflectionNudge: Bool = true,
                mutatingToolNames: Set<String> = [],
                verificationToolNames: Set<String> = [],
                readOnlyToolNames: Set<String> = [],
                stallWindow: Int = 3) {
        self.iteration = iteration
        self.maxIterations = maxIterations
        self.modelWantsToFinish = modelWantsToFinish
        self.lastAssistantContent = lastAssistantContent
        self.messages = messages
        self.turnStartIndex = turnStartIndex
        self.recentToolSignatures = recentToolSignatures
        self.recentErrorFlags = recentErrorFlags
        self.recentToolCalls = recentToolCalls
        self.recentErrorCounts = recentErrorCounts
        self.lastToolOutput = lastToolOutput
        self.groundingForceCount = groundingForceCount
        self.editVerifyForceCount = editVerifyForceCount
        self.reflectionAlreadyNudged = reflectionAlreadyNudged
        self.decisionAlreadyNudged = decisionAlreadyNudged
        self.allowReflectionNudge = allowReflectionNudge
        self.mutatingToolNames = mutatingToolNames
        self.verificationToolNames = verificationToolNames
        self.readOnlyToolNames = readOnlyToolNames
        self.stallWindow = stallWindow
    }
}

/// Stable reason strings returned by policies — loop increments counters
/// from `PolicyDecision.forceReasons` without re-evaluating predicates.
public enum PolicyForceReason {
    public static let grounding = "claimed success after a failed tool call"
    public static let editVerify = "edited files without verifying them"
}

/// What one policy asks the loop to do.
public enum PolicyDirective: Sendable, Equatable {
    case proceed
    case nudge(String)
    case forceContinue(nudge: String?, reason: String)
    case halt(reason: String)
    case requireVerification
}

/// Resolved outcome after folding every policy's directive.
public struct PolicyDecision: Sendable, Equatable {
    public var halt: String?
    public var forceContinue: Bool
    public var forceReasons: [String]
    public var nudges: [String]
    public var requireVerification: Bool

    public init(halt: String? = nil, forceContinue: Bool = false,
                forceReasons: [String] = [], nudges: [String] = [],
                requireVerification: Bool = false) {
        self.halt = halt
        self.forceContinue = forceContinue
        self.forceReasons = forceReasons
        self.nudges = nudges
        self.requireVerification = requireVerification
    }
}

public protocol TurnPolicy: Sendable {
    func evaluate(_ snapshot: TurnSnapshot) -> PolicyDirective
}

/// Folds an ordered list of policies into one decision.
public struct PolicyEngine: Sendable {
    public let policies: [any TurnPolicy]

    public init(_ policies: [any TurnPolicy]) {
        self.policies = policies
    }

    public func decide(_ snapshot: TurnSnapshot) -> PolicyDecision {
        var decision = PolicyDecision()
        for policy in policies {
            switch policy.evaluate(snapshot) {
            case .proceed:
                break
            case .nudge(let n):
                decision.nudges.append(n)
            case let .forceContinue(nudge, reason):
                decision.forceContinue = true
                decision.forceReasons.append(reason)
                if let nudge { decision.nudges.append(nudge) }
            case .halt(let reason):
                if decision.halt == nil { decision.halt = reason }
            case .requireVerification:
                decision.requireVerification = true
            }
        }
        return decision
    }
}