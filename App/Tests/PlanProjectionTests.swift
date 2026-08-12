//
//  PlanProjectionTests.swift
//
//  create_plan emits todos as a string array — the UI projection must
//  surface every step (not an empty "Plan complete" shell).
//

import Testing
import Foundation
@testable import VibeCoderApp
import AgentCore

@Suite("Plan projection")
struct PlanProjectionTests {

    @Test("create_plan string-array todos appear as checklist steps")
    func stringArrayTodos() {
        let args = """
        {"goal":"Ship login flow","todos":["Add User model","Wire login UI","Write tests"]}
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
                    output: "Created plan.\nPlan — Ship login flow\n1. [ ] Add User model\n2. [ ] Wire login UI\n3. [ ] Write tests\nProgress: 0/3 complete"
                )
            ]
        ]

        let plan = CodeSessionBuilder.currentPlan(conversation: convo, toolStates: states)
        #expect(plan != nil)
        #expect(plan?.goal == "Ship login flow")
        #expect(plan?.todos.count == 3)
        #expect(plan?.todos.map(\.text) == ["Add User model", "Wire login UI", "Write tests"])
        #expect(plan?.isComplete == false)
        #expect(plan?.todos.allSatisfy { $0.status == .pending } == true)
    }

    @Test("update_todo marks a step done with green-check status")
    func updateTodoMarksDone() {
        let create = """
        {"goal":"Refactor","todos":["Extract helper","Call sites"]}
        """
        let update = #"{"id":"1","status":"done","result":"Helper extracted"}"#
        let m1 = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [ToolCallInvocation(id: "c1", name: "create_plan", arguments: create)]
        )
        let m2 = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [ToolCallInvocation(id: "u1", name: "update_todo", arguments: update)]
        )
        let convo = Conversation(messages: [m1, m2])
        let states: [UUID: [ToolCallUIState]] = [
            m1.id: [ToolCallUIState(id: "c1", toolName: "create_plan", status: .success,
                                    input: create, output: "")],
            m2.id: [ToolCallUIState(id: "u1", toolName: "update_todo", status: .success,
                                    input: update, output: "")]
        ]

        let plan = CodeSessionBuilder.currentPlan(conversation: convo, toolStates: states)
        #expect(plan?.todos.count == 2)
        #expect(plan?.todos[0].status == .done)
        #expect(plan?.todos[0].result == "Helper extracted")
        #expect(plan?.todos[1].status == .pending)
        #expect(plan?.isComplete == false)
    }

    @Test("empty plan is not complete")
    func emptyPlanNotComplete() {
        let plan = Plan(goal: "Create a plan", todos: [])
        #expect(plan.isComplete == false)
    }
}
