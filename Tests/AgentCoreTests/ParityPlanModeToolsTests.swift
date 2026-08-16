//
//  ParityPlanModeToolsTests.swift
//
//  Wave-1 planmode: enter_plan_mode / exit_plan_mode extras contract,
//  required plan param, and read-only enter content.
//

import XCTest
@testable import AgentCore

final class ParityPlanModeToolsTests: XCTestCase {

    private func ctx(
        projectRoot: URL? = nil,
        conversationID: UUID = UUID(),
        sessionPlanFileURL: URL? = nil
    ) -> ToolContext {
        ToolContext(
            projectRoot: projectRoot,
            conversationID: conversationID,
            sessionPlanFileURL: sessionPlanFileURL
        )
    }

    // MARK: - Extras

    func testEnterPlanModeRequestsPlanExecutionMode() async throws {
        let result = try await EnterPlanModeTool().execute(
            arguments: ToolArguments(dictionary: [:]),
            context: ctx()
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.extras[PlanModeToolExtras.requestExecutionMode], "plan")
        XCTAssertNil(result.extras[PlanModeToolExtras.planApproved])
        XCTAssertTrue(result.mutatedPaths.isEmpty)
        XCTAssertEqual(EnterPlanModeTool.permission, .readOnly)
    }

    func testExitPlanModeRequestsBuildAndMarksApproved() async throws {
        let plan = "1. Read auth. 2. Add JWT middleware."
        let result = try await ExitPlanModeTool().execute(
            arguments: ToolArguments(dictionary: ["plan": plan]),
            context: ctx()
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.extras[PlanModeToolExtras.requestExecutionMode], "build")
        XCTAssertEqual(result.extras[PlanModeToolExtras.planApproved], "true")
        XCTAssertTrue(result.mutatedPaths.isEmpty)
        XCTAssertEqual(ExitPlanModeTool.permission, .readOnly)
        XCTAssertTrue(result.content.contains("The plan was recorded. Start implementing."))
        XCTAssertTrue(result.content.contains(plan))
    }

    // MARK: - Required plan param

    func testExitPlanModeRequiresPlanParam() async throws {
        XCTAssertEqual(ExitPlanModeTool.schema.parameters.required, ["plan"])
        XCTAssertNotNil(ExitPlanModeTool.schema.parameters.properties["plan"])

        let missing = try await ExitPlanModeTool().execute(
            arguments: ToolArguments(dictionary: [:]),
            context: ctx()
        )
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.content.contains("`plan` is required"))
        XCTAssertTrue(missing.extras.isEmpty)

        let blank = try await ExitPlanModeTool().execute(
            arguments: ToolArguments(dictionary: ["plan": "   \n  "]),
            context: ctx()
        )
        XCTAssertTrue(blank.isError)
        XCTAssertTrue(blank.extras.isEmpty)
    }

    // MARK: - Enter content

    func testEnterPlanModeContentMentionsReadOnly() async throws {
        let result = try await EnterPlanModeTool().execute(
            arguments: ToolArguments(dictionary: [:]),
            context: ctx()
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(
            result.content.lowercased().contains("read-only"),
            "enter content should mention read-only: \(result.content)"
        )
        XCTAssertTrue(result.content.contains("exit_plan_mode"))
    }

    // MARK: - Persist (best-effort)

    func testExitPlanModePersistsViaPlanStoreAndPlanFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("planmode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let convo = UUID()
        let planURL = ToolAuthorization.sessionPlanURL(
            workingDirectory: root, conversationID: convo)
        let planText = "# Ship auth\n\nUse JWT and existing middleware."
        let result = try await ExitPlanModeTool().execute(
            arguments: ToolArguments(dictionary: ["plan": planText]),
            context: ctx(
                projectRoot: root,
                conversationID: convo,
                sessionPlanFileURL: planURL
            )
        )
        XCTAssertFalse(result.isError, result.content)

        let stored = await PlanStore.shared.plan(for: convo, workingDirectory: root)
        XCTAssertEqual(stored?.goal, planText)

        let onDisk = try String(contentsOf: planURL, encoding: .utf8)
        XCTAssertEqual(onDisk, planText)
    }
}
