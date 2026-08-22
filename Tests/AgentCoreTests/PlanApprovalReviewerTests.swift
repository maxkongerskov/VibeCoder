//
//  PlanApprovalReviewerTests.swift
//
//  Optional host gate for `exit_plan_mode`.
//

import XCTest
@testable import AgentCore

final class PlanApprovalReviewerTests: XCTestCase {

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
            .appendingPathComponent("plan-approval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testNilReviewerAutoApprovesAndPersists() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let convo = UUID()
        let planURL = ToolAuthorization.sessionPlanURL(
            workingDirectory: root, conversationID: convo)
        let plan = "1. Read. 2. Implement."

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
        XCTAssertEqual(result.extras[PlanModeToolExtras.requestExecutionMode], "build")
        XCTAssertEqual(result.extras[PlanModeToolExtras.planApproved], "true")
        XCTAssertTrue(result.content.contains("The plan was recorded. Start implementing."))

        let stored = await PlanStore.shared.plan(for: convo, workingDirectory: root)
        XCTAssertEqual(stored?.goal, plan)
        XCTAssertEqual(try String(contentsOf: planURL, encoding: .utf8), plan)
    }

    func testReviewerTrueApprovesLikeNil() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let convo = UUID()
        let planURL = ToolAuthorization.sessionPlanURL(
            workingDirectory: root, conversationID: convo)
        let plan = "Ship JWT middleware."
        let reviewer = PlanApprovalReviewer { incoming in
            XCTAssertEqual(incoming, plan)
            return true
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
        XCTAssertEqual(result.extras[PlanModeToolExtras.requestExecutionMode], "build")
        XCTAssertEqual(result.extras[PlanModeToolExtras.planApproved], "true")

        let stored = await PlanStore.shared.plan(for: convo, workingDirectory: root)
        XCTAssertEqual(stored?.goal, plan)
        XCTAssertEqual(try String(contentsOf: planURL, encoding: .utf8), plan)
    }

    func testReviewerFalseStaysInPlanModeWithoutPersist() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let convo = UUID()
        let planURL = ToolAuthorization.sessionPlanURL(
            workingDirectory: root, conversationID: convo)
        let plan = "Do not ship this yet."
        let reviewer = PlanApprovalReviewer { _ in false }

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
        XCTAssertNil(result.extras[PlanModeToolExtras.requestExecutionMode])
        XCTAssertNil(result.extras[PlanModeToolExtras.planApproved])
        XCTAssertTrue(result.content.contains("Stay in plan mode"))

        let stored = await PlanStore.shared.plan(for: convo, workingDirectory: root)
        XCTAssertNil(stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: planURL.path))
    }
}
