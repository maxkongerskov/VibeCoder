//
//  PolicyEngineTests.swift
//

import XCTest
@testable import AgentCore

final class PolicyEngineTests: XCTestCase {

    private func snapshot(
        iteration: Int = 1,
        maxIterations: Int = 30,
        modelWantsToFinish: Bool = false,
        lastAssistantContent: String = "",
        messages: [ChatMessage] = [],
        turnStartIndex: Int = 0,
        recentToolSignatures: [String] = [],
        recentErrorFlags: [Bool] = [],
        recentToolCalls: [ToolCallSnapshot] = [],
        recentErrorCounts: [Int] = [],
        lastToolOutput: ToolOutputInfo? = nil,
        groundingForceCount: Int = 0,
        editVerifyForceCount: Int = 0,
        stallWindow: Int = 3,
        mutatingToolNames: Set<String> = [],
        verificationToolNames: Set<String> = [],
        readOnlyToolNames: Set<String> = []
    ) -> TurnSnapshot {
        TurnSnapshot(iteration: iteration, maxIterations: maxIterations,
                     modelWantsToFinish: modelWantsToFinish,
                     lastAssistantContent: lastAssistantContent,
                     messages: messages, turnStartIndex: turnStartIndex,
                     recentToolSignatures: recentToolSignatures,
                     recentErrorFlags: recentErrorFlags,
                     recentToolCalls: recentToolCalls,
                     recentErrorCounts: recentErrorCounts,
                     lastToolOutput: lastToolOutput,
                     groundingForceCount: groundingForceCount,
                     editVerifyForceCount: editVerifyForceCount,
                     mutatingToolNames: mutatingToolNames,
                     verificationToolNames: verificationToolNames,
                     readOnlyToolNames: readOnlyToolNames,
                     stallWindow: stallWindow)
    }

    private func msg(_ role: ChatMessage.Role, _ content: String,
                     calls: [ToolCallInvocation] = [],
                     toolCallID: String? = nil) -> ChatMessage {
        ChatMessage(role: role, content: content, toolCalls: calls, toolCallID: toolCallID)
    }

    func testIterationCapHalts() {
        // Cap only when iteration has *exceeded* max (Nth response still allowed).
        XCTAssertEqual(IterationCapPolicy().evaluate(snapshot(iteration: 30, maxIterations: 30)),
                       .proceed)
        XCTAssertEqual(IterationCapPolicy().evaluate(snapshot(iteration: 31, maxIterations: 30)),
                       .halt(reason: "reached the 30-iteration limit for this turn"))
        XCTAssertEqual(IterationCapPolicy().evaluate(snapshot(iteration: 5, maxIterations: 30)),
                       .proceed)
    }

    func testGovernorHaltsOnRepetition() {
        let call = ToolCallSnapshot(tool: "apply_patch", arguments: "{}")
        let d = GovernorPolicy().evaluate(snapshot(recentToolCalls: Array(repeating: call, count: 6)))
        guard case .halt = d else { return XCTFail("expected halt, got \(d)") }
    }

    func testStallHaltsOnRepeatedSignature() {
        let sig = "read_file({})"
        let d = StallPolicy().evaluate(snapshot(
            recentToolSignatures: [sig, sig, sig], stallWindow: 3))
        guard case .halt = d else { return XCTFail("expected halt, got \(d)") }
    }

    func testStallRespectsConfiguredWindow() {
        let sig = "read_file({})"
        let narrow = StallPolicy().evaluate(snapshot(
            recentToolSignatures: [sig, sig, sig], stallWindow: 4))
        XCTAssertEqual(narrow, .proceed)
        let wide = StallPolicy().evaluate(snapshot(
            recentToolSignatures: [sig, sig, sig, sig], stallWindow: 4))
        guard case .halt = wide else { return XCTFail("expected halt, got \(wide)") }
    }

    func testStallRespectsConfiguredWindowAboveSix() {
        let sig = "read_file({})"
        let sigs = Array(repeating: sig, count: 7)
        XCTAssertEqual(StallPolicy().evaluate(snapshot(
            recentToolSignatures: sigs, stallWindow: 8)), .proceed)
        let eight = sigs + [sig]
        guard case .halt = StallPolicy().evaluate(snapshot(
            recentToolSignatures: eight, stallWindow: 8))
        else { return XCTFail("expected halt at stallWindow 8") }
    }

    func testGovernorSkipsRunawayForReadOnlyTools() {
        let largeRead = ToolOutputInfo(tool: "read_file", bytes: 100 * 1024 + 1)
        XCTAssertEqual(
            GovernorPolicy().evaluate(snapshot(
                lastToolOutput: largeRead,
                readOnlyToolNames: ["read_file"])),
            .proceed)
        let largeShell = ToolOutputInfo(tool: "run_shell", bytes: 100 * 1024 + 1)
        guard case .halt = GovernorPolicy().evaluate(snapshot(
            lastToolOutput: largeShell,
            readOnlyToolNames: ["read_file"]))
        else { return XCTFail("expected halt for mutating tool runaway") }
    }

    func testEditVerifySkipsWhenBuildGuardSucceededInTranscript() {
        let edit = ToolCallInvocation(id: "e1", name: "write_file", arguments: "{}")
        let messages: [ChatMessage] = [
            msg(.user, "fix"),
            msg(.assistant, "", calls: [edit]),
            msg(.tool, "wrote", toolCallID: "e1"),
            msg(.user, SystemReminder.buildGuard(succeeded: true)),
            msg(.assistant, "Done — app is ready."),
        ]
        let mutating: Set<String> = ["write_file"]
        let verification: Set<String> = ["read_file", "git_diff"]
        let snap = snapshot(
            modelWantsToFinish: true, messages: messages,
            mutatingToolNames: mutating, verificationToolNames: verification)
        XCTAssertEqual(
            EditVerifyPolicy().evaluate(snap), .proceed,
            "BuildGuard success row must satisfy edit verification (no extra model round)")
        XCTAssertFalse(
            ChatLoop.shouldVerifyEdits(
                messages: messages, turnStartIndex: 0,
                mutatingToolNames: mutating, verificationToolNames: verification,
                alreadyVerified: false))
    }

    func testEditVerifyEscalatesNudgeOnSecondForce() {
        let edit = ToolCallInvocation(id: "e1", name: "write_file", arguments: "{}")
        let messages: [ChatMessage] = [
            msg(.user, "fix"),
            msg(.assistant, "", calls: [edit]),
            msg(.tool, "wrote", toolCallID: "e1"),
            msg(.assistant, "Done."),
        ]
        let mutating: Set<String> = ["write_file"]
        let verification: Set<String> = ["read_file", "git_diff"]
        let first = snapshot(
            modelWantsToFinish: true, messages: messages,
            mutatingToolNames: mutating, verificationToolNames: verification)
        guard case let .forceContinue(nudge1, reason1) = EditVerifyPolicy().evaluate(first)
        else { return XCTFail("expected first forceContinue") }
        XCTAssertEqual(nudge1, ChatLoop.verifyEditsNudge)
        XCTAssertEqual(reason1, PolicyForceReason.editVerify)

        let second = snapshot(
            modelWantsToFinish: true, messages: messages,
            editVerifyForceCount: 1,
            mutatingToolNames: mutating, verificationToolNames: verification)
        guard case let .forceContinue(nudge2, _) = EditVerifyPolicy().evaluate(second)
        else { return XCTFail("expected second forceContinue") }
        XCTAssertEqual(nudge2, ChatLoop.verifyEditsNudgeEscalated)

        let third = snapshot(
            modelWantsToFinish: true, messages: messages,
            editVerifyForceCount: 2,
            mutatingToolNames: mutating, verificationToolNames: verification)
        XCTAssertEqual(EditVerifyPolicy().evaluate(third), .proceed)
    }

    func testGroundingForcesContinueOnSuccessClaimAfterError() {
        let d = GroundingPolicy().evaluate(snapshot(
            modelWantsToFinish: true,
            lastAssistantContent: "All done — created the file successfully.",
            recentErrorFlags: [false, true]))
        guard case let .forceContinue(nudge, _) = d else { return XCTFail("expected forceContinue, got \(d)") }
        XCTAssertEqual(nudge, ChatLoop.groundingNudge)
    }

    func testHeadlessNudgesDecisionLoggingButInteractiveDoesNot() {
        var messages: [ChatMessage] = []
        for i in 0..<5 {
            messages.append(msg(.assistant, "", calls: [
                ToolCallInvocation(id: "c\(i)", name: "read_file", arguments: "{}")
            ]))
        }
        let snap = snapshot(iteration: 6, messages: messages)
        XCTAssertTrue(PolicyProfile.headless().decide(snap).nudges
            .contains(ChatLoop.decisionLoggingNudge))
        XCTAssertFalse(PolicyProfile.interactive().decide(snap).nudges
            .contains(ChatLoop.decisionLoggingNudge))
    }
}