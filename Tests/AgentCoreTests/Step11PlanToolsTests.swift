//
//  Step11PlanToolsTests.swift
//
//  Guards the structured-planning port (2026-06-16):
//   • Plan pure helpers (make / updatingTodo / revising / renderedChecklist)
//   • lenient TodoStatus parsing
//   • PlanStore per-conversation state
//   • create_plan / update_todo / revise_plan execute paths + errors
//   • registration availability + SOP mention
//

import XCTest
@testable import AgentCore

final class Step11PlanToolsTests: XCTestCase {

    // MARK: - Plan pure helpers

    func testMakeAssignsSequentialIDs() {
        let plan = Plan.make(goal: "Ship it", todoTexts: ["a", "b", "c"])
        XCTAssertEqual(plan.goal, "Ship it")
        XCTAssertEqual(plan.todos.map(\.id), ["1", "2", "3"])
        XCTAssertTrue(plan.todos.allSatisfy { $0.status == .pending })
    }

    func testUpdatingTodoChangesStatusAndResult() {
        let plan = Plan.make(goal: "G", todoTexts: ["a", "b"])
        let updated = plan.updatingTodo(id: "2", status: .done, result: "built clean")
        XCTAssertEqual(updated?.todos[1].status, .done)
        XCTAssertEqual(updated?.todos[1].result, "built clean")
        XCTAssertEqual(updated?.todos[0].status, .pending, "other todos untouched")
    }

    func testUpdatingTodoUnknownIDReturnsNil() {
        let plan = Plan.make(goal: "G", todoTexts: ["a"])
        XCTAssertNil(plan.updatingTodo(id: "99", status: .done, result: nil))
    }

    func testRevisingAppendsWithContinuingIDsAndKeepsStatuses() {
        var plan = Plan.make(goal: "G", todoTexts: ["a", "b"])
        plan = plan.updatingTodo(id: "1", status: .done, result: nil)!
        let revised = plan.revising(addingTexts: ["c"], removingIDs: [], goal: nil)
        XCTAssertEqual(revised.todos.map(\.id), ["1", "2", "3"], "new id continues past the max")
        XCTAssertEqual(revised.todos[2].text, "c")
        XCTAssertEqual(revised.todos[0].status, .done, "finished steps keep their status across a revision")
    }

    func testRevisingRemovesByIDAndRestatesGoal() {
        let plan = Plan.make(goal: "old", todoTexts: ["a", "b", "c"])
        let revised = plan.revising(addingTexts: [], removingIDs: ["2"], goal: "new")
        XCTAssertEqual(revised.goal, "new")
        XCTAssertEqual(revised.todos.map(\.id), ["1", "3"], "step 2 dropped, others keep their ids")
    }

    func testRenderedChecklistShowsMarkersAndProgress() {
        var plan = Plan.make(goal: "Goal", todoTexts: ["first", "second"])
        plan = plan.updatingTodo(id: "1", status: .done, result: nil)!
        let text = plan.renderedChecklist()
        XCTAssertTrue(text.contains("Plan — Goal"))
        XCTAssertTrue(text.contains("1. [x] first"))
        XCTAssertTrue(text.contains("2. [ ] second"))
        XCTAssertTrue(text.contains("Progress: 1/2 complete"))
    }

    func testLenientStatusParsing() {
        XCTAssertEqual(TodoStatus(lenient: "in progress"), .inProgress)
        XCTAssertEqual(TodoStatus(lenient: "Completed"), .done)
        XCTAssertEqual(TodoStatus(lenient: "DONE"), .done)
        XCTAssertEqual(TodoStatus(lenient: "blocked"), .failed)
        XCTAssertNil(TodoStatus(lenient: "banana"))
    }

    // MARK: - PlanStore

    func testPlanStoreRoundTripsAndIsolatesConversations() async {
        let store = PlanStore()
        let a = UUID(), b = UUID()
        await store.setPlan(Plan.make(goal: "A", todoTexts: ["x"]), for: a)
        let pa = await store.plan(for: a)
        XCTAssertEqual(pa?.goal, "A")
        let pb = await store.plan(for: b)
        XCTAssertNil(pb, "a different conversation has no plan")
    }

    func testPlanStoreUpdateAndReviseNilWhenNoPlan() async {
        let store = PlanStore()
        let convo = UUID()
        let noUpdate = await store.updateTodo(id: "1", status: .done, result: nil, for: convo)
        XCTAssertNil(noUpdate)
        let noRevise = await store.revise(for: convo, addingTexts: ["z"], removingIDs: [], goal: nil)
        XCTAssertNil(noRevise)
    }

    // MARK: - Tools

    private func ctx() -> ToolContext { ToolContext(projectRoot: nil, conversationID: UUID()) }

    func testCreatePlanToolCreatesAndRenders() async throws {
        let context = ctx()
        let result = try await CreatePlanTool().execute(
            arguments: try ToolArguments(json: #"{"goal":"Make a calc","todos":["scaffold","build"]}"#),
            context: context)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("Plan — Make a calc"))
        XCTAssertTrue(result.content.contains("1. [ ] scaffold"))
        XCTAssertTrue(result.mutatedPaths.isEmpty, "planning never reports file mutations (won't trip BuildGuard)")
        let stored = await PlanStore.shared.plan(for: context.conversationID)
        XCTAssertEqual(stored?.todos.count, 2)
    }

    func testCreatePlanToolRejectsEmptyTodos() async throws {
        let result = try await CreatePlanTool().execute(
            arguments: try ToolArguments(json: #"{"goal":"G","todos":[]}"#),
            context: ctx())
        XCTAssertTrue(result.isError)
    }

    func testUpdateTodoToolMarksDone() async throws {
        let context = ctx()
        _ = try await CreatePlanTool().execute(
            arguments: try ToolArguments(json: #"{"goal":"G","todos":["a","b"]}"#), context: context)
        let result = try await UpdateTodoTool().execute(
            arguments: try ToolArguments(json: #"{"id":"1","status":"done","result":"ok"}"#), context: context)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("1. [x] a → ok"))
        XCTAssertTrue(result.content.contains("Progress: 1/2 complete"))
    }

    func testUpdateTodoToolErrorsWithoutPlan() async throws {
        let result = try await UpdateTodoTool().execute(
            arguments: try ToolArguments(json: #"{"id":"1","status":"done"}"#), context: ctx())
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("no plan"))
    }

    func testUpdateTodoToolErrorsOnUnknownIDAndBadStatus() async throws {
        let context = ctx()
        _ = try await CreatePlanTool().execute(
            arguments: try ToolArguments(json: #"{"goal":"G","todos":["a"]}"#), context: context)

        let badID = try await UpdateTodoTool().execute(
            arguments: try ToolArguments(json: #"{"id":"9","status":"done"}"#), context: context)
        XCTAssertTrue(badID.isError)
        XCTAssertTrue(badID.content.contains("no step with id '9'"))

        let badStatus = try await UpdateTodoTool().execute(
            arguments: try ToolArguments(json: #"{"id":"1","status":"banana"}"#), context: context)
        XCTAssertTrue(badStatus.isError)
        XCTAssertTrue(badStatus.content.contains("unknown status"))
    }

    func testRevisePlanToolAppendsAndErrorsWhenEmptyOrNoPlan() async throws {
        // No plan yet.
        let noPlan = try await RevisePlanTool().execute(
            arguments: try ToolArguments(json: #"{"add":["x"]}"#), context: ctx())
        XCTAssertTrue(noPlan.isError)

        // With a plan: append a step.
        let context = ctx()
        _ = try await CreatePlanTool().execute(
            arguments: try ToolArguments(json: #"{"goal":"G","todos":["a"]}"#), context: context)
        let revised = try await RevisePlanTool().execute(
            arguments: try ToolArguments(json: #"{"add":["b"]}"#), context: context)
        XCTAssertFalse(revised.isError, revised.content)
        XCTAssertTrue(revised.content.contains("2. [ ] b"))

        // Nothing to do.
        let empty = try await RevisePlanTool().execute(
            arguments: try ToolArguments(json: #"{}"#), context: context)
        XCTAssertTrue(empty.isError)
    }

    // MARK: - Registration + prompt wiring

    func testPlanToolsRegisteredWithExpectedAvailability() async {
        await ToolRegistry.shared.registerBuiltins()
        let core = Set(await ToolRegistry.shared.schemas().map(\.name))
        let all = Set(await ToolRegistry.shared.schemas(activeNames: nil, includeDeferred: true).map(\.name))
        XCTAssertTrue(core.contains("create_plan"), "create_plan is core")
        XCTAssertTrue(core.contains("update_todo"), "update_todo is core")
        XCTAssertFalse(core.contains("revise_plan"), "revise_plan is deferred")
        XCTAssertTrue(all.contains("revise_plan"), "revise_plan reachable via tool_search")
    }

    func testPlanAuthoringToolsIncludePlanPrimitives() {
        XCTAssertTrue(ChatLoop.planAuthoringTools.contains("create_plan"))
        XCTAssertTrue(ChatLoop.planAuthoringTools.contains("update_todo"))
    }
}
