//
//  PlanApprovalCoordinator.swift
//
//  Bridges AgentCore's `PlanApprovalReviewer` to the Approve control.
//  When pending, Approve / Stay resume the waiting exit_plan_mode call.
//  Does not fetch; it only unblocks the in-flight tool.
//

import Foundation
import SwiftUI
import AgentCore

@MainActor
final class PlanApprovalCoordinator: ObservableObject {

    /// Plan text the user is asked to Approve (nil when nothing is waiting).
    @Published var pendingPlan: String?

    private var continuation: CheckedContinuation<Bool, Never>?

    func waitForApproval(plan: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            if let existing = continuation {
                existing.resume(returning: false)
            }
            continuation = cont
            pendingPlan = plan
        }
    }

    func resolve(approved: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        pendingPlan = nil
        cont.resume(returning: approved)
    }

    nonisolated func makeReviewer() -> PlanApprovalReviewer {
        PlanApprovalReviewer { [weak self] plan in
            guard let self else { return false }
            return await self.waitForApproval(plan: plan)
        }
    }
}
