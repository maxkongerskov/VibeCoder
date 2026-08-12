//
//  PlanApprovalContractTests.swift
//  Product S2 — contracts for plan approve → build mode.
//

import XCTest
@testable import AgentCore

final class PlanApprovalContractTests: XCTestCase {

    func testApproveModeIsBuildAskNotReadOnly() {
        // ChatViewModel.approvePlanAndContinue sets ExecutionMode.build.
        XCTAssertEqual(ExecutionMode.build.shortLabel, "Ask")
        XCTAssertFalse(ExecutionMode.build.isReadOnly)
        XCTAssertTrue(ExecutionMode.build.enablesPatchReview)
        XCTAssertTrue(ExecutionMode.plan.isReadOnly)
    }

    func testPlanStoreChecklistForReviewRoundTrip() async {
        let store = PlanStore()
        let id = UUID()
        var plan = Plan.make(goal: "Ship S2", todoTexts: ["Checklist", "Approve", "Run"])
        await store.setPlan(plan, for: id)
        // Simulate user review toggle: mark first step reviewed.
        plan = plan.updatingTodo(id: "1", status: .done, result: "Reviewed")!
        await store.setPlan(plan, for: id)
        let loaded = await store.plan(for: id)
        XCTAssertEqual(loaded?.todos[0].status, .done)
        XCTAssertEqual(loaded?.todos[1].status, .pending)
        XCTAssertFalse(loaded?.isComplete ?? true)
    }

    func testHydrateFromTranscriptFeedsChecklist() async {
        let store = PlanStore()
        let id = UUID()
        let args = #"{"goal":"From transcript","todos":["A","B"]}"#
        let msg = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [ToolCallInvocation(id: "1", name: "create_plan", arguments: args)]
        )
        let plan = await store.hydrateIfNeeded(
            for: id, messages: [msg], workingDirectory: nil)
        XCTAssertEqual(plan?.goal, "From transcript")
        XCTAssertEqual(plan?.todos.count, 2)
    }
}
