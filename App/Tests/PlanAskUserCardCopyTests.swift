//
//  PlanAskUserCardCopyTests.swift
//
//  Mira QA: characterize Plan / Ask-user card copy as painted by Sable
//  (28099e0). Do not restyle. Entering/Entered plan mode, Awaiting
//  approval with Approve, Asking/Asked with Continue and Submit.
//  Product is VibeCoder. Looks like ZCode grouping. Not ZCode. Not
//  Electron. Does not stamp 99%. PRODUCT_NAME VibeCoderTests.
//

import XCTest
@testable import AgentCore
@testable import VibeCoderApp

final class PlanAskUserCardCopyTests: XCTestCase {

    func testPlanGuidanceCopyIsEnteringThenEnteredPlanMode() {
        let running = PlanGuidanceCard(index: 0, isRunning: true, planText: "Ship cards")
        XCTAssertEqual(PlanGuidanceCardCopy.verb(running), "Entering plan mode")
        XCTAssertEqual(PlanGuidanceCardCopy.status(running), "Ship cards")
        XCTAssertEqual(running.kindLabel, "Entering plan mode")
        XCTAssertEqual(ToolCallGrouping.planGuidanceKindLabel(isRunning: true), "Entering plan mode")

        let done = PlanGuidanceCard(index: 0, isRunning: false)
        XCTAssertEqual(PlanGuidanceCardCopy.verb(done), "Entered plan mode")
        XCTAssertEqual(PlanGuidanceCardCopy.status(done), "Plan")
        XCTAssertEqual(ToolCallGrouping.planGuidanceKindLabel(isRunning: false), "Entered plan mode")

        XCTAssertFalse(PlanGuidanceCardCopy.verb(running).localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(PlanGuidanceCardCopy.verb(done).localizedCaseInsensitiveContains("99%"))
    }

    func testSwitchModeCopyIsAwaitingApprovalWithApprove() {
        let running = SwitchModeCard(index: 0, isRunning: true)
        XCTAssertEqual(SwitchModeCardCopy.verb(running), "Awaiting approval")
        XCTAssertEqual(SwitchModeCardCopy.status(running), "Implementation plan")
        XCTAssertEqual(SwitchModeCardCopy.approve, "Approve")
        XCTAssertEqual(
            SwitchModeCardCopy.approveDescription,
            "Exit plan mode and start implementation.")
        XCTAssertEqual(ToolCallGrouping.switchModeKindLabel(isRunning: true), "Awaiting approval")
        XCTAssertEqual(ToolCallGrouping.switchModeApproveLabel, "Approve")

        let done = SwitchModeCard(index: 0, isRunning: false, planText: "Do the work")
        XCTAssertEqual(SwitchModeCardCopy.verb(done), "Switched mode")
        XCTAssertEqual(SwitchModeCardCopy.status(done), "Do the work")
        XCTAssertEqual(ToolCallGrouping.switchModeKindLabel(isRunning: false), "Switched mode")

        XCTAssertFalse(SwitchModeCardCopy.approve.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(SwitchModeCardCopy.verb(running).localizedCaseInsensitiveContains("electron"))
    }

    func testAskUserCopyIsAskingThenAskedWithContinueAndSubmit() {
        let running = AskUserQuestionCard(index: 0, isRunning: true, question: "Ship?")
        XCTAssertEqual(AskUserQuestionCardCopy.verb(running), "Asking")
        XCTAssertEqual(AskUserQuestionCardCopy.status(running), "Ship?")
        XCTAssertEqual(AskUserQuestionCardCopy.continueLabel, "Continue")
        XCTAssertEqual(AskUserQuestionCardCopy.submit, "Submit")
        XCTAssertEqual(AskUserQuestionCardCopy.customAnswer, "Custom answer")
        XCTAssertEqual(ToolCallGrouping.askUserQuestionKindLabel(isRunning: true), "Asking")
        XCTAssertEqual(ToolCallGrouping.askUserContinueLabel, "Continue")
        XCTAssertEqual(ToolCallGrouping.askUserSubmitLabel, "Submit")

        let done = AskUserQuestionCard(index: 0, isRunning: false)
        XCTAssertEqual(AskUserQuestionCardCopy.verb(done), "Asked")
        XCTAssertEqual(AskUserQuestionCardCopy.status(done), "Question")
        XCTAssertEqual(ToolCallGrouping.askUserQuestionKindLabel(isRunning: false), "Asked")

        XCTAssertFalse(AskUserQuestionCardCopy.submit.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(AskUserQuestionCardCopy.continueLabel.localizedCaseInsensitiveContains("99%"))
    }

    func testEnterExitAndAskUserAreOwnCardsNotExplore() {
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "enter_plan_mode"), .planGuidance)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "EnterPlanMode"), .planGuidance)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "exit_plan_mode"), .switchMode)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "ExitPlanMode"), .switchMode)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "ask_user"), .askUserQuestion)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "AskUserQuestion"), .askUserQuestion)
        XCTAssertFalse(ToolCallGrouping.isExploreMember(.planGuidance))
        XCTAssertFalse(ToolCallGrouping.isExploreMember(.switchMode))
        XCTAssertFalse(ToolCallGrouping.isExploreMember(.askUserQuestion))

        let events = [
            ToolCallEvent(name: "grep_code"),
            ToolCallEvent(name: "enter_plan_mode", isRunning: true, planText: "Ship cards"),
            ToolCallEvent(name: "exit_plan_mode", isRunning: true),
            ToolCallEvent(name: "ask_user", question: "Ship?"),
            ToolCallEvent(name: "read_file"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 5, "plan/ask tools must not merge into Explore or each other")
        guard case .explore = groups[0] else { return XCTFail("search is explore") }
        guard case .planGuidance(let plan) = groups[1] else { return XCTFail("enter_plan_mode is plan card") }
        XCTAssertEqual(plan.kindLabel, "Entering plan mode")
        XCTAssertEqual(plan.planText, "Ship cards")
        guard case .switchMode(let sw) = groups[2] else { return XCTFail("exit_plan_mode is switch card") }
        XCTAssertEqual(sw.kindLabel, "Awaiting approval")
        XCTAssertEqual(sw.approveLabel, "Approve")
        guard case .askUserQuestion(let ask) = groups[3] else { return XCTFail("ask_user is ask card") }
        XCTAssertEqual(ask.kindLabel, "Asked")
        XCTAssertEqual(ask.question, "Ship?")
        XCTAssertEqual(ask.continueLabel, "Continue")
        XCTAssertEqual(ask.submitLabel, "Submit")
        guard case .explore(let counts, _) = groups[4] else {
            return XCTFail("read after ask is a new explore")
        }
        XCTAssertEqual(counts.files, 1)
        XCTAssertEqual(counts.searches, 0)
    }

    func testChatStackPaintsPlanSwitchAndAskRowsNotGeneric() throws {
        let src = try appSource("Views/Chat/ZCodeActivityLineView.swift")
        XCTAssertTrue(src.contains("case .planGuidance(let card):"))
        XCTAssertTrue(src.contains("items.append(.planGuidance(card))"))
        XCTAssertTrue(src.contains("planGuidanceRow(card)"))
        XCTAssertTrue(src.contains("case .switchMode(let card):"))
        XCTAssertTrue(src.contains("items.append(.switchMode(card))"))
        XCTAssertTrue(src.contains("switchModeRow(card)"))
        XCTAssertTrue(src.contains("case .askUserQuestion(let card):"))
        XCTAssertTrue(src.contains("items.append(.askUserQuestion(card))"))
        XCTAssertTrue(src.contains("askUserQuestionRow(card)"))
        XCTAssertTrue(src.contains("Text(PlanGuidanceCardCopy.verb(card))"))
        XCTAssertTrue(src.contains("Text(PlanGuidanceCardCopy.status(card))"))
        XCTAssertTrue(src.contains("Text(SwitchModeCardCopy.verb(card))"))
        XCTAssertTrue(src.contains("Text(SwitchModeCardCopy.approve)"))
        XCTAssertTrue(src.contains("Text(SwitchModeCardCopy.approveDescription)"))
        XCTAssertTrue(src.contains("Text(AskUserQuestionCardCopy.verb(card))"))
        XCTAssertTrue(src.contains("Text(AskUserQuestionCardCopy.continueLabel)"))
        XCTAssertTrue(src.contains("Text(AskUserQuestionCardCopy.submit)"))
        XCTAssertEqual(src.components(separatedBy: "private func planGuidanceRow(").count - 1, 1)
        XCTAssertEqual(src.components(separatedBy: "private func switchModeRow(").count - 1, 1)
        XCTAssertEqual(src.components(separatedBy: "private func askUserQuestionRow(").count - 1, 1)
        XCTAssertFalse(src.contains("Ask ZCode"))
        XCTAssertFalse(src.localizedCaseInsensitiveContains("99%"))
        assertNotProductIdentityLies(in: src, file: "ZCodeActivityLineView.swift")
    }

    func testPaintedCopyDoesNotClaimZCodeOrStamp99() throws {
        let files = [
            "Utilities/SettingsDiscoverabilityCopy.swift",
            "Views/Chat/ZCodeActivityLineView.swift",
        ]
        for rel in files {
            assertNotProductIdentityLies(in: try appSource(rel), file: rel)
        }
        XCTAssertFalse(PlanGuidanceCardCopy.verb(PlanGuidanceCard(index: 0, isRunning: true)).localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(SwitchModeCardCopy.approve.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(AskUserQuestionCardCopy.submit.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(AskUserQuestionCardCopy.continueLabel.localizedCaseInsensitiveContains("99%"))
    }

    // MARK: - helpers

    private func assertNotProductIdentityLies(in text: String, file: String) {
        let lower = text.lowercased()
        XCTAssertFalse(
            lower.contains("vibecoder is zcode"),
            "\(file) must not claim VibeCoder IS ZCode")
        XCTAssertFalse(
            lower.contains("we are zcode"),
            "\(file) must not claim the product is ZCode")
        XCTAssertFalse(
            lower.contains("this app is electron")
                || lower.contains("vibecoder is electron"),
            "\(file) must not claim Electron")
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func appSource(_ relative: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(relative), encoding: .utf8)
    }
}
