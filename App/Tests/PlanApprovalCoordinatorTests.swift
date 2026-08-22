//
//  PlanApprovalCoordinatorTests.swift
//
//  Approve is a real gate: waitForApproval resumes only on resolve.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

@MainActor
final class PlanApprovalCoordinatorTests: XCTestCase {

    func testApproveResumesTrue() async {
        let coord = PlanApprovalCoordinator()
        async let result = coord.waitForApproval(plan: "Ship JWT")
        await Task.yield()
        XCTAssertEqual(coord.pendingPlan, "Ship JWT")
        coord.resolve(approved: true)
        let ok = await result
        XCTAssertTrue(ok)
        XCTAssertNil(coord.pendingPlan)
    }

    func testStayResumesFalse() async {
        let coord = PlanApprovalCoordinator()
        async let result = coord.waitForApproval(plan: "Stay put")
        await Task.yield()
        coord.resolve(approved: false)
        let ok = await result
        XCTAssertFalse(ok)
        XCTAssertNil(coord.pendingPlan)
    }

    func testReviewerMatchesCoordinator() async {
        let coord = PlanApprovalCoordinator()
        let reviewer = coord.makeReviewer()
        async let result = reviewer.approve("Plan body")
        await Task.yield()
        XCTAssertEqual(coord.pendingPlan, "Plan body")
        coord.resolve(approved: true)
        let ok = await result
        XCTAssertTrue(ok)
    }
}
