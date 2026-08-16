//
//  RapidRefillBreaker.swift
//
//  Hard-stops compact→retry→compact loops. ZCode: 3 consecutive
//  auto/reactive compacts with fewer than 3 tool turns between each pair.
//

import Foundation

/// Value-type state machine. The loop owns one instance per turn.
public struct RapidRefillBreaker: Sendable, Equatable {

    /// Consecutive rapid compacts that trip `shouldHardStop()`.
    public static let consecutiveCompactLimit = 3

    /// Tool-result turns that reset the rapid streak.
    public static let minToolTurnsToReset = 3

    public private(set) var consecutiveRapidCompacts: Int
    public private(set) var toolTurnsSinceCompact: Int

    public init(
        consecutiveRapidCompacts: Int = 0,
        toolTurnsSinceCompact: Int = 0
    ) {
        self.consecutiveRapidCompacts = max(0, consecutiveRapidCompacts)
        self.toolTurnsSinceCompact = max(0, toolTurnsSinceCompact)
    }

    /// Record that a compact (auto or reactive) just ran.
    public mutating func recordCompact() {
        if toolTurnsSinceCompact < Self.minToolTurnsToReset {
            consecutiveRapidCompacts += 1
        } else {
            consecutiveRapidCompacts = 0
        }
        toolTurnsSinceCompact = 0
    }

    /// Record one completed real tool-result batch / tool turn.
    public mutating func recordToolTurn() {
        toolTurnsSinceCompact += 1
        if toolTurnsSinceCompact >= Self.minToolTurnsToReset {
            consecutiveRapidCompacts = 0
        }
    }

    /// True when the next compact would be the 3rd consecutive rapid one,
    /// or the breaker already tripped.
    public func shouldHardStop() -> Bool {
        if consecutiveRapidCompacts >= Self.consecutiveCompactLimit {
            return true
        }
        let nextStreak: Int
        if toolTurnsSinceCompact < Self.minToolTurnsToReset {
            nextStreak = consecutiveRapidCompacts + 1
        } else {
            nextStreak = 0
        }
        return nextStreak >= Self.consecutiveCompactLimit
    }
}
