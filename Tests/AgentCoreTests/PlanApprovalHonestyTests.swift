//
//  PlanApprovalHonestyTests.swift
//
//  Mira QA: ExitPlanModeTool waits when ToolContext.planApprovalReviewer
//  is set. Approve is the gate; Stay in Plan declines (false → stay,
//  no persist). Nil / default loop / omitted bootstrap still auto-approves.
//  Headless must leave the reviewer nil.
//

import XCTest
@testable import AgentCore

final class PlanApprovalHonestyTests: XCTestCase {

    private func ctx(
        projectRoot: URL? = nil,
        conversationID: UUID = UUID(),
        sessionPlanFileURL: URL? = nil,
        reviewer: PlanApprovalReviewer? = nil
    ) -> ToolContext {
        ToolContext(
            projectRoot: projectRoot,
            planApprovalReviewer: reviewer,
            conversationID: conversationID,
            sessionPlanFileURL: sessionPlanFileURL
        )
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-honesty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testNilReviewerAutoApprovesWithoutWaiting() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let convo = UUID()
        let planURL = ToolAuthorization.sessionPlanURL(
            workingDirectory: root, conversationID: convo)
        let plan = "Auto path."

        let result = try await ExitPlanModeTool().execute(
            arguments: ToolArguments(dictionary: ["plan": plan]),
            context: ctx(
                projectRoot: root,
                conversationID: convo,
                sessionPlanFileURL: planURL,
                reviewer: nil
            )
        )

        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.extras[PlanModeToolExtras.planApproved], "true")
        XCTAssertEqual(result.extras[PlanModeToolExtras.requestExecutionMode], "build")
        let stored = await PlanStore.shared.plan(for: convo, workingDirectory: root)
        XCTAssertEqual(stored?.goal, plan)
    }

    func testDefaultLoopConfigAndBootstrapLeaveReviewerNil() throws {
        let loop = AgentLoop.Configuration()
        XCTAssertNil(
            loop.planApprovalReviewer,
            "default Configuration auto-approves when host omits a reviewer")

        var appSettings = AppSettings()
        appSettings.xcodeMCPEnabled = false
        let built = AgentRunBootstrap.buildLoopConfiguration(
            modelSettings: ModelSettings(
                modelId: "test",
                loadSettings: .init(
                    contextLength: ModelSettings.defaultContextLength,
                    gpuOffloadLayers: ModelSettings.defaultGPUOffloadLayers,
                    flashAttention: ModelSettings.defaultFlashAttention,
                    kvCacheType: ModelSettings.defaultKVCacheType),
                inferenceSettings: .init(
                    temperature: 0.7, topP: 0.9, topK: 40, repeatPenalty: 1.0),
                savedAt: Date()),
            workerModel: ModelDescriptor(id: "test", displayName: "Test", backend: .lmStudio),
            settings: appSettings,
            xcodeMCPLive: false,
            headless: false,
            safeMode: nil,
            patchReviewer: nil,
            orchestratorBrief: nil).config
        XCTAssertNil(
            built.planApprovalReviewer,
            "omitting planApprovalReviewer must stay nil so exit_plan_mode auto-approves")
    }

    func testStayInPlanDeclinesWithoutPersist() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let convo = UUID()
        let planURL = ToolAuthorization.sessionPlanURL(
            workingDirectory: root, conversationID: convo)
        let plan = "Stay in Plan declines the waiting exit_plan_mode."
        let reviewer = PlanApprovalReviewer { incoming in
            XCTAssertEqual(incoming, plan)
            return false
        }

        let result = try await ExitPlanModeTool().execute(
            arguments: ToolArguments(dictionary: ["plan": plan]),
            context: ctx(
                projectRoot: root,
                conversationID: convo,
                sessionPlanFileURL: planURL,
                reviewer: reviewer
            )
        )

        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.extras.isEmpty)
        XCTAssertNil(result.extras[PlanModeToolExtras.planApproved])
        XCTAssertNil(result.extras[PlanModeToolExtras.requestExecutionMode])
        XCTAssertTrue(result.content.contains("Stay in plan mode"))
        let stored = await PlanStore.shared.plan(for: convo, workingDirectory: root)
        XCTAssertNil(stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: planURL.path))
    }

    func testApproveGateAwaitsReviewerBeforePersist() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let convo = UUID()
        let planURL = ToolAuthorization.sessionPlanURL(
            workingDirectory: root, conversationID: convo)
        let plan = "Approve resumes waiting exit_plan_mode."
        let latch = ReviewerLatch()
        let reviewer = PlanApprovalReviewer { incoming in
            XCTAssertEqual(incoming, plan)
            return await latch.markEnteredAndWait()
        }

        let task = Task {
            try await ExitPlanModeTool().execute(
                arguments: ToolArguments(dictionary: ["plan": plan]),
                context: self.ctx(
                    projectRoot: root,
                    conversationID: convo,
                    sessionPlanFileURL: planURL,
                    reviewer: reviewer
                )
            )
        }

        await latch.waitUntilEntered()
        let mid = await PlanStore.shared.plan(for: convo, workingDirectory: root)
        XCTAssertNil(mid, "must not persist until reviewer.approve returns")
        XCTAssertFalse(FileManager.default.fileExists(atPath: planURL.path))

        await latch.resume(true)
        let result = try await task.value
        XCTAssertEqual(result.extras[PlanModeToolExtras.planApproved], "true")
        XCTAssertEqual(result.extras[PlanModeToolExtras.requestExecutionMode], "build")
        let stored = await PlanStore.shared.plan(for: convo, workingDirectory: root)
        XCTAssertEqual(stored?.goal, plan)
    }
}

/// Test double: pause ExitPlanModeTool inside PlanApprovalReviewer.approve.
private actor ReviewerLatch {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var decisionWaiter: CheckedContinuation<Bool, Never>?
    private var pendingDecision: Bool?

    func markEnteredAndWait() async -> Bool {
        await withCheckedContinuation { continuation in
            if let pending = pendingDecision {
                pendingDecision = nil
                continuation.resume(returning: pending)
                entered = true
                flushEntered()
                return
            }
            decisionWaiter = continuation
            entered = true
            flushEntered()
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func resume(_ value: Bool) {
        if let waiter = decisionWaiter {
            decisionWaiter = nil
            waiter.resume(returning: value)
        } else {
            pendingDecision = value
        }
    }

    private func flushEntered() {
        let pending = enteredWaiters
        enteredWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
