//
//  GoalAssessment.swift
//
//  Heuristic goal-completion assessment for AgentLoop. Replaces the prior
//  bug of always passing `achieved: true` into GoalOrchestrator.
//

import Foundation

public enum GoalAssessment: Sendable {

    public struct Result: Sendable, Equatable {
        public let achieved: Bool
        public let gaps: [String]

        public init(achieved: Bool, gaps: [String]) {
            self.achieved = achieved
            self.gaps = gaps
        }
    }

    /// Optional soft-completion evidence when the model never authored a plan.
    public struct SoftSignals: Sendable, Equatable {
        /// BuildGuard reported a green build this turn (or earlier in the turn).
        public var buildVerified: Bool
        /// Successful tool rounds (non-error tool batches) this turn.
        public var successfulToolRounds: Int
        /// At least one successful file mutation this turn.
        public var hadSuccessfulMutation: Bool

        public init(
            buildVerified: Bool = false,
            successfulToolRounds: Int = 0,
            hadSuccessfulMutation: Bool = false
        ) {
            self.buildVerified = buildVerified
            self.successfulToolRounds = successfulToolRounds
            self.hadSuccessfulMutation = hadSuccessfulMutation
        }
    }

    /// Decide whether the active goal is actually complete.
    ///
    /// Rules (conservative — prefer continue over false complete):
    /// 1. Recent tool errors always block achievement (even with a “complete” plan).
    /// 2. Structured plan with failed todos → not achieved; failed items
    ///    stay in gaps alongside pending / in_progress (do not collapse).
    /// 3. Structured plan with only skipped todos (no real done) → not achieved.
    /// 4. Structured plan with every todo done/skipped and ≥1 done → achieved.
    /// 5. Structured plan with open todos → not achieved; gaps = open items.
    /// 6. No plan: soft-achieve only when build verified + no recent errors
    ///    (+ productive tool work). Otherwise not achieved with actionable gaps.
    public static func assess(
        goalDescription: String,
        plan: Plan?,
        recentErrorFlags: [Bool],
        soft: SoftSignals = SoftSignals()
    ) -> Result {
        let recentFailures = recentErrorFlags.suffix(4).contains(true)

        if let plan, !plan.todos.isEmpty {
            if recentFailures {
                return Result(
                    achieved: false,
                    gaps: ["Recent tool failures are unresolved for goal: \(shortGoal(goalDescription))"])
            }
            // Failed todos block achievement, but must stay in the same
            // open-item gap list as pending / in_progress so stall
            // fingerprints still move when other work progresses.
            if plan.isComplete {
                let anyDone = plan.todos.contains { $0.status == .done }
                if !anyDone {
                    // All skipped is not real goal completion (self-certify / abandon).
                    return Result(
                        achieved: false,
                        gaps: ["Plan has no completed steps (all skipped) for goal: \(shortGoal(goalDescription))"])
                }
                return Result(achieved: true, gaps: [])
            }
            // Open = pending / in_progress / failed (not done/skipped).
            let open = plan.todos.filter {
                $0.status != .done && $0.status != .skipped
            }
            let gaps = open.map { todo in
                let status = todo.status.rawValue
                if let result = todo.result, !result.isEmpty {
                    return "\(todo.id): \(todo.text) [\(status)] — \(result)"
                }
                return "\(todo.id): \(todo.text) [\(status)]"
            }
            return Result(achieved: false, gaps: gaps.isEmpty
                ? ["Plan incomplete"]
                : gaps)
        }

        if recentFailures {
            return Result(
                achieved: false,
                gaps: ["Recent tool failures are unresolved for goal: \(shortGoal(goalDescription))"])
        }

        // Soft complete without a structured plan: build verified + tool work.
        if soft.buildVerified,
           soft.successfulToolRounds >= 1,
           (soft.hadSuccessfulMutation || soft.successfulToolRounds >= 2) {
            return Result(achieved: true, gaps: [])
        }

        // No verified plan completion — actionable gaps (vary by evidence so
        // GoalOrchestrator stall fingerprints can progress when work improves).
        var gaps: [String] = [
            "Goal not verified complete: \(shortGoal(goalDescription))"
        ]
        if !soft.buildVerified {
            gaps.append("No verified green build yet — finish work and let BuildGuard pass, or call create_plan and mark todos done")
        } else if soft.successfulToolRounds == 0 {
            gaps.append("No successful tool work recorded this turn")
        } else if !soft.hadSuccessfulMutation {
            gaps.append("No successful file mutations yet — implement the change or create_plan with todos")
        }
        return Result(achieved: false, gaps: gaps)
    }

    /// Continuation directive when the model tried to finish but the goal
    /// is still open (distinct from StopDetector bail patterns).
    public static func continuationNudge(goalDescription: String, gaps: [String]) -> String {
        var lines = [
            "# Course-correction (goal still open)",
            "",
            "You appear ready to stop, but the active goal is NOT complete:",
            shortGoal(goalDescription),
            "",
            "Open gaps:",
        ]
        if gaps.isEmpty {
            lines.append("- (unspecified — re-read the goal and continue)")
        } else {
            for g in gaps.prefix(8) {
                lines.append("- \(g)")
            }
        }
        lines.append(contentsOf: [
            "",
            "Continue working with tools until the goal is achieved or you hit a",
            "genuine external blocker. Do not hand off or declare done yet.",
        ])
        return lines.joined(separator: "\n")
    }

    private static func shortGoal(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 240 ? String(t.prefix(240)) + "…" : t
    }
}
