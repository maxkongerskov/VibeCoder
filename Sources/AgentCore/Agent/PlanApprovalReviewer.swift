//
//  PlanApprovalReviewer.swift
//
//  Optional host gate for `exit_plan_mode` — pause the loop so the user
//  can Approve or decline a plan. When the reviewer is nil, the tool
//  auto-approves (current default).
//

import Foundation

public struct PlanApprovalReviewer: Sendable {
    public let approve: @Sendable (String) async -> Bool

    public init(approve: @escaping @Sendable (String) async -> Bool) {
        self.approve = approve
    }
}
