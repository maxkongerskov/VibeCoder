//
//  PlanApprovalFlowTests.swift
//  Product S2 — plan checklist approval → build mode continue.
//

import Testing
import Foundation
@testable import VibeCoderApp
import AgentCore

@Suite("Plan approval flow (S2)")
struct PlanApprovalFlowTests {

    @Test("PlanStore plan is preferred surface for checklist identity")
    func planStoreRoundTripForApproval() async {
        let store = PlanStore()
        let convo = UUID()
        let plan = Plan.make(
            goal: "Ship checklist",
            todoTexts: ["Design", "Implement", "Verify"]
        )
        await store.setPlan(plan, for: convo)
        let loaded = await store.plan(for: convo)
        #expect(loaded?.todos.count == 3)
        #expect(loaded?.goal == "Ship checklist")
        #expect(loaded?.isComplete == false)
        #expect(loaded?.todos.allSatisfy { $0.status == .pending } == true)
    }

    @Test("Approve maps to build (Ask) execution mode raw value")
    func approveTargetsBuildMode() {
        // Contract: approvePlanAndContinue sets ExecutionMode.build ("Ask").
        #expect(ExecutionMode.build.shortLabel == "Ask")
        #expect(ExecutionMode.build.isReadOnly == false)
        #expect(ExecutionMode.plan.isReadOnly == true)
        #expect(ExecutionMode.build.enablesPatchReview == true)
    }

    @Test("Reject/stay keeps plan mode read-only contract")
    func stayKeepsPlanReadOnly() {
        #expect(ExecutionMode.plan.isReadOnly == true)
        #expect(ExecutionMode.plan.enablesPatchReview == false)
    }

    @Test("Transcript projection still yields checklist when store is empty")
    func transcriptFallbackChecklist() {
        let args = """
        {"goal":"Approve path","todos":["Step A","Step B"]}
        """
        let msg = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                ToolCallInvocation(id: "tc1", name: "create_plan", arguments: args)
            ]
        )
        let convo = Conversation(messages: [msg])
        let states: [UUID: [ToolCallUIState]] = [
            msg.id: [
                ToolCallUIState(
                    id: "tc1",
                    toolName: "create_plan",
                    status: .success,
                    input: args,
                    output: ""
                )
            ]
        ]
        let plan = CodeSessionBuilder.currentPlan(conversation: convo, toolStates: states)
        #expect(plan?.todos.count == 2)
        #expect(plan?.todos.map(\.text) == ["Step A", "Step B"])
    }
}
