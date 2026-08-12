//
//  PlanStoreDurabilityTests.swift
//
//  Wave C W07: durable plan.json + transcript rehydrate for PlanStore.
//

import XCTest
@testable import AgentCore

final class PlanStoreDurabilityTests: XCTestCase {

    func testDurableRoundTripAcrossNewStoreInstance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-dur-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let convo = UUID()
        let plan = Plan.make(goal: "Persist me", todoTexts: ["step one", "step two"])
        let storeA = PlanStore()
        await storeA.setPlan(plan, for: convo, workingDirectory: root)

        let file = PlanStore.durableFileURL(workingDirectory: root, conversation: convo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let storeB = PlanStore() // cold memory
        let loaded = await storeB.plan(for: convo, workingDirectory: root)
        XCTAssertEqual(loaded?.goal, "Persist me")
        XCTAssertEqual(loaded?.todos.count, 2)
    }

    func testUpdateTodoRehydratesFromDiskWhenMemoryCold() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-upd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let convo = UUID()
        let plan = Plan.make(goal: "G", todoTexts: ["a", "b"])
        let writer = PlanStore()
        await writer.setPlan(plan, for: convo, workingDirectory: root)

        let cold = PlanStore()
        let updated = await cold.updateTodo(
            id: "1", status: .done, result: "ok",
            for: convo, workingDirectory: root)
        XCTAssertEqual(updated?.todos.first?.status, .done)
    }

    func testTranscriptReconstruction() {
        let createArgs = #"{"goal":"Auth","todos":["read code","write tests"]}"#
        let updateArgs = #"{"id":"1","status":"done","result":"ok"}"#
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "do auth"),
            ChatMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    .init(id: "c1", name: "create_plan", arguments: createArgs),
                ]),
            ChatMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    .init(id: "u1", name: "update_todo", arguments: updateArgs),
                ]),
        ]
        let plan = PlanTranscript.latestPlan(in: messages)
        XCTAssertEqual(plan?.goal, "Auth")
        XCTAssertEqual(plan?.todos.count, 2)
        XCTAssertEqual(plan?.todos.first?.status, .done)
        XCTAssertEqual(plan?.todos.first?.result, "ok")
    }

    func testHydrateIfNeededFromTranscript() async {
        let convoID = UUID()
        let createArgs = #"{"goal":"Hydrate","todos":["one"]}"#
        let messages: [ChatMessage] = [
            ChatMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    .init(id: "c1", name: "create_plan", arguments: createArgs),
                ]),
        ]
        let store = PlanStore()
        let plan = await store.hydrateIfNeeded(
            for: convoID, messages: messages, workingDirectory: nil)
        XCTAssertEqual(plan?.goal, "Hydrate")
        let again = await store.plan(for: convoID)
        XCTAssertEqual(again?.goal, "Hydrate")
    }
}

final class PlanModeEnforcementWaveCTests: XCTestCase {

    private func planContext(root: URL) -> ToolContext {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ToolContext(
            projectRoot: root,
            conversationID: UUID(),
            executionMode: .plan
        )
    }

    func testPlanModeDeniesApplyPatchExplicitly() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-ap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = planContext(root: root)
        let outcome = ToolAuthorization.evaluate(
            toolName: "apply_patch",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "patch": "--- a/x\n+++ b/x\n@@\n-a\n+b\n"
            ]),
            context: ctx
        )
        guard case .deny(let reason) = outcome else {
            return XCTFail("expected deny, got \(outcome)")
        }
        XCTAssertTrue(reason.lowercased().contains("plan"), reason)
    }

    func testPlanModeDeniesWriteOutsidePlanFile() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-wr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = planContext(root: root)
        let outcome = ToolAuthorization.evaluate(
            toolName: "write_file",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "path": root.appendingPathComponent("src.swift").path,
                "content": "nope",
            ]),
            context: ctx
        )
        guard case .deny = outcome else {
            return XCTFail("expected deny write outside plan.md, got \(outcome)")
        }
    }

    /// Wave C2: omitted / unknown subagent_type must not spawn write-capable agents.
    func testPlanModeDeniesTaskWithoutOrUnknownType() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-task-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = planContext(root: root)

        let missing = ToolAuthorization.evaluate(
            toolName: "task",
            permission: .executes,
            arguments: ToolArguments(dictionary: ["prompt": "hi"]),
            context: ctx
        )
        guard case .deny(let m1) = missing else {
            return XCTFail("missing subagent_type must deny, got \(missing)")
        }
        XCTAssertTrue(m1.lowercased().contains("plan"), m1)

        let unknown = ToolAuthorization.evaluate(
            toolName: "task",
            permission: .executes,
            arguments: ToolArguments(dictionary: [
                "prompt": "hi",
                "subagent_type": "worker-bee",
            ]),
            context: ctx
        )
        guard case .deny(let m2) = unknown else {
            return XCTFail("unknown subagent_type must deny, got \(unknown)")
        }
        XCTAssertTrue(m2.lowercased().contains("unknown") || m2.lowercased().contains("plan"), m2)

        let explore = ToolAuthorization.evaluate(
            toolName: "task",
            permission: .executes,
            arguments: ToolArguments(dictionary: [
                "prompt": "hi",
                "subagent_type": "explore",
            ]),
            context: ctx
        )
        XCTAssertEqual(explore, .allow, "explore must remain allowed in plan mode")
    }
}

final class GoalProgressInfoLineTests: XCTestCase {
    func testProgressInfoLineFormat() async {
        let orch = GoalOrchestrator(
            goalDescription: "ship",
            seedAttemptCount: 2,
            seedLastFingerprint: GapFingerprint(gaps: ["a"]).value,
            seedConsecutiveStallCount: 1)
        let line = await orch.progressInfoLine()
        XCTAssertTrue(line.hasPrefix("goal-progress "), line)
        XCTAssertTrue(line.contains("attempts=2"), line)
        XCTAssertTrue(line.contains("stall=1"), line)
        XCTAssertTrue(line.contains("status=active"), line)
        XCTAssertTrue(line.contains("fp="), line)
    }
}
