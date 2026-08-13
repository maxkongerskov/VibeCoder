//
//  Governor.swift
//
//  Bounded-loop hard-fail detector. Ported from rexyMCP's
//  `executor/src/governor/hard_fail.rs` (github.com/ryanczak/rexyMCP),
//  adapted to AgentOS's single-`swift build` judge.
//
//  WHY THIS EXISTS
//  The bounded oracle loop (AgentLoop, raw mode) feeds a failed build's
//  compiler errors back to the worker and retries. The original version
//  stopped on ATTEMPT COUNT alone — which scored 5/10: the loop would burn
//  every attempt thrashing on a build that wasn't getting better. The
//  governor adds the missing signal: stop when the worker is NOT making
//  progress (error count flat or rising), not merely when it has retried N
//  times. A loop whose errors shrink 5→3→1 is allowed to continue; one stuck
//  at 4→4→4 is cut off honestly.
//
//  It is a PURE function over recent history — no state, no I/O — so it is
//  trivially unit-tested and has zero dependency on the rest of the loop.
//

import Foundation

/// The reason the governor decided to stop the bounded loop.
public enum HardFailSignal: Equatable, Sendable {
    /// The same tool call (name + arguments) repeated `count` times in a
    /// row — the worker is spinning on one broken edit.
    case identicalToolCallRepetition(tool: String, count: Int)
    /// The build has failed with a non-shrinking error count for `count`
    /// consecutive attempts — the worker is not making progress.
    case verifierFailurePersistent(count: Int)
    /// A single tool produced more than the byte limit — runaway output.
    case runawayOutput(tool: String, bytes: Int)

    /// A short, user-safe description (no iteration counts in user copy).
    public var describe: String {
        switch self {
        case let .identicalToolCallRepetition(tool, count):
            return "identical \(tool) call repeated \(count) times"
        case let .verifierFailurePersistent(count):
            return "the build failed without improving for \(count) attempts"
        case let .runawayOutput(tool, bytes):
            return "tool \(tool) produced \(bytes) bytes (over threshold)"
        }
    }
}

/// Tunable thresholds. Defaults match rexyMCP's shipped values.
public struct GovernorConfig: Sendable {
    public var identicalCallThreshold: Int
    public var verifierPersistenceThreshold: Int
    public var runawayOutputBytes: Int

    public init(identicalCallThreshold: Int = 6,
                verifierPersistenceThreshold: Int = 3,
                runawayOutputBytes: Int = 100 * 1024) {
        self.identicalCallThreshold = identicalCallThreshold
        self.verifierPersistenceThreshold = verifierPersistenceThreshold
        self.runawayOutputBytes = runawayOutputBytes
    }
}

/// A minimal snapshot of one tool call, used only for repetition detection.
public struct ToolCallSnapshot: Equatable, Sendable {
    public let tool: String
    /// Serialized arguments — canonicalized JSON key order so equivalent
    /// calls match. Different values still count as different calls.
    public let arguments: String
    public init(tool: String, arguments: String) {
        self.tool = tool
        self.arguments = ChatLoop.canonicalJSONArguments(arguments)
    }
}

public enum Governor {
    /// The single decision function. Returns the first tripped signal in
    /// priority order (repetition → verifier persistence → runaway), or
    /// `nil` to mean "keep going".
    public static func evaluate(
        recentToolCalls: [ToolCallSnapshot],
        recentErrorCounts: [Int],
        lastToolOutput: (tool: String, bytes: Int)?,
        config: GovernorConfig = .init()
    ) -> HardFailSignal? {
        if let s = checkIdenticalRepetition(recentToolCalls,
                                            threshold: config.identicalCallThreshold) {
            return s
        }
        if let s = checkVerifierPersistence(recentErrorCounts,
                                            threshold: config.verifierPersistenceThreshold) {
            return s
        }
        if let s = checkRunawayOutput(lastToolOutput,
                                      limit: config.runawayOutputBytes) {
            return s
        }
        return nil
    }

    /// Last `threshold` tool calls are byte-identical in BOTH name and
    /// arguments. Patching six different files does not trip this.
    static func checkIdenticalRepetition(_ recent: [ToolCallSnapshot],
                                         threshold: Int) -> HardFailSignal? {
        guard threshold > 0, recent.count >= threshold else { return nil }
        let lastN = recent.suffix(threshold)
        guard let first = lastN.first else { return nil }
        let allIdentical = lastN.allSatisfy {
            $0.tool == first.tool && $0.arguments == first.arguments
        }
        guard allIdentical else { return nil }
        return .identicalToolCallRepetition(tool: first.tool, count: threshold)
    }

    /// Last `threshold` build attempts ALL had >0 errors AND the count was
    /// non-decreasing (oldest→newest). THE KEY RULE: a shrinking sequence
    /// (5→3→1) is progress and does NOT trip — only flat/rising does.
    static func checkVerifierPersistence(_ counts: [Int],
                                         threshold: Int) -> HardFailSignal? {
        guard threshold > 0, counts.count >= threshold else { return nil }
        let lastN = Array(counts.suffix(threshold))
        if lastN.contains(0) { return nil }            // a clean build is not a failure
        for i in 1..<lastN.count where lastN[i - 1] > lastN[i] {
            return nil                                 // errors dropped → progress → keep going
        }
        return .verifierFailurePersistent(count: threshold)
    }

    /// The most recent tool output exceeded the byte limit.
    static func checkRunawayOutput(_ output: (tool: String, bytes: Int)?,
                                   limit: Int) -> HardFailSignal? {
        guard let output, output.bytes > limit else { return nil }
        return .runawayOutput(tool: output.tool, bytes: output.bytes)
    }

    /// Count compiler errors in a raw `swift build` log. Swift prints each
    /// error as a line containing " error:". Turns BuildGuard's opaque log
    /// into the numeric progress signal the verifier-persistence check uses.
    public static func errorCount(inBuildLog log: String) -> Int {
        log.split(separator: "\n").reduce(into: 0) { acc, line in
            if isCompilerErrorLine(line) { acc += 1 }
        }
    }

    /// Swift (`file:12:5: error:`), cargo (`error:` / `error[E0425]:`),
    /// and tsc (`error TS2304:` / `file.ts:1:1 - error TS2304:`).
    private static func isCompilerErrorLine(_ line: Substring) -> Bool {
        if line.contains(" error:") { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("error:") { return true }
        if trimmed.hasPrefix("error[") { return true }
        if trimmed.hasPrefix("error TS") { return true }
        if line.contains(" error TS") { return true }
        return false
    }
}
