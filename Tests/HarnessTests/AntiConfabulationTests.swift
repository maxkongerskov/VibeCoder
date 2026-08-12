//
//  AntiConfabulationTests.swift  (Harness)
//
//  Pins anti-confabulation gates via AgentCore.ChatLoop (shared with production).
//

import XCTest
import AgentCore

final class AntiConfabulationTests: XCTestCase {

    private let sampleMutating: Set<String> = [
        "write_file", "edit_file", "apply_patch",
        "create_directory", "delete_file", "move_file", "xcode_project_editor",
    ]
    private let sampleVerification: Set<String> = ToolClassification.postEditVerificationCore

    private func msg(_ role: ChatMessage.Role, _ content: String,
                     calls: [ToolCallInvocation] = []) -> ChatMessage {
        ChatMessage(role: role, content: content, toolCalls: calls)
    }

    private func toolMsg(_ content: String, id: String = "t1") -> ChatMessage {
        ChatMessage(role: .tool, content: content, toolCallID: id)
    }

    func testVerifyBeforeFinishFiresOnSuccessClaimAfterFailure() {
        XCTAssertTrue(ChatLoop.shouldVerifyBeforeFinish(
            recentToolErrorFlags: [false, true],
            finalAssistantContent: "All done — created the file successfully."))
    }

    func testVerifyBeforeFinishSkipsHonestAnswerAfterFailure() {
        XCTAssertFalse(ChatLoop.shouldVerifyBeforeFinish(
            recentToolErrorFlags: [false, true],
            finalAssistantContent: "I can't check your emails — the directory is empty."))
        XCTAssertFalse(ChatLoop.shouldVerifyBeforeFinish(
            recentToolErrorFlags: [false, true],
            finalAssistantContent: "No matching files were found."))
    }

    func testVerifyBeforeFinishNeverFiresWithoutTrailingFailure() {
        XCTAssertFalse(ChatLoop.shouldVerifyBeforeFinish(
            recentToolErrorFlags: [true, false], finalAssistantContent: "Done."))
        XCTAssertFalse(ChatLoop.shouldVerifyBeforeFinish(
            recentToolErrorFlags: [], finalAssistantContent: "Done."))
    }

    func testSuccessClaimAfterErrorTripsVerifyBeforeFinish() {
        XCTAssertTrue(ChatLoop.shouldVerifyBeforeFinish(
            recentToolErrorFlags: [true],
            finalAssistantContent: "Build succeeded and all tests pass."))
    }

    func testHedgedLanguageDoesNotTripClaimsUnverifiedSuccess() {
        XCTAssertFalse(ChatLoop.claimsUnverifiedSuccess(
            "I created a draft but the build failed, so it's not done."))
        XCTAssertFalse(ChatLoop.claimsUnverifiedSuccess(
            "I was not able to complete this — the file was empty."))
        XCTAssertTrue(ChatLoop.claimsUnverifiedSuccess(
            "All done, the file was created."))
    }

    func testShouldVerifyEditsRequiresEditThenSilence() {
        let editCall = ToolCallInvocation(id: "e1", name: "write_file", arguments: "{}")
        let messages: [ChatMessage] = [
            msg(.user, "fix it"),
            msg(.assistant, "", calls: [editCall]),
            toolMsg("Wrote 10 bytes", id: "e1"),
            msg(.assistant, "All done!"),
        ]
        XCTAssertTrue(ChatLoop.shouldVerifyEdits(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification, alreadyVerified: false))
        XCTAssertFalse(ChatLoop.shouldVerifyEdits(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification, alreadyVerified: true))

        let readOnly: [ChatMessage] = [
            msg(.user, "look around"),
            msg(.assistant, "", calls: [.init(id: "r1", name: "read_file", arguments: "{}")]),
            toolMsg("contents", id: "r1"),
            msg(.assistant, "Here's what I found."),
        ]
        XCTAssertFalse(ChatLoop.shouldVerifyEdits(
            messages: readOnly, turnStartIndex: 0,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification, alreadyVerified: false))
    }

    func testVerifyEditsSkipsWhenAgentAlreadyVerified() {
        let messages: [ChatMessage] = [
            msg(.user, "make and run it"),
            msg(.assistant, "", calls: [.init(id: "e1", name: "write_file", arguments: "{}")]),
            toolMsg("Wrote 100 bytes", id: "e1"),
            msg(.assistant, "", calls: [.init(id: "r1", name: "run_shell", arguments: "{}")]),
            toolMsg("$ swift fib.swift\n[exit 0]\n...", id: "r1"),
            msg(.assistant, "Done — it runs and prints the sequence."),
        ]
        XCTAssertTrue(ChatLoop.editAlreadyVerifiedThisTurn(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification))
        XCTAssertFalse(ChatLoop.shouldVerifyEdits(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification, alreadyVerified: false))
    }

    func testVerifyEditsStillFiresWhenEditUnverified() {
        let messages: [ChatMessage] = [
            msg(.user, "fix it"),
            msg(.assistant, "", calls: [.init(id: "e1", name: "write_file", arguments: "{}")]),
            toolMsg("Wrote 100 bytes", id: "e1"),
            msg(.assistant, "All done!"),
        ]
        XCTAssertFalse(ChatLoop.editAlreadyVerifiedThisTurn(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification))
        XCTAssertTrue(ChatLoop.shouldVerifyEdits(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification, alreadyVerified: false))
    }

    func testVerificationBeforeEditDoesNotCount() {
        let messages: [ChatMessage] = [
            msg(.user, "update it"),
            msg(.assistant, "", calls: [.init(id: "r1", name: "read_file", arguments: "{}")]),
            toolMsg("old contents", id: "r1"),
            msg(.assistant, "", calls: [.init(id: "e1", name: "write_file", arguments: "{}")]),
            toolMsg("Wrote 50 bytes", id: "e1"),
            msg(.assistant, "Updated."),
        ]
        XCTAssertFalse(ChatLoop.editAlreadyVerifiedThisTurn(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification))
        XCTAssertTrue(ChatLoop.shouldVerifyEdits(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification, alreadyVerified: false))
    }

    func testBuildGuardBuildCountsAsVerification() {
        let messages: [ChatMessage] = [
            msg(.user, "patch it"),
            msg(.assistant, "", calls: [.init(id: "e1", name: "edit_file", arguments: "{}")]),
            toolMsg("Edited", id: "e1"),
            msg(.user, SystemReminder.buildGuard(succeeded: true)),
            msg(.assistant, "Patched and it compiles."),
        ]
        XCTAssertTrue(ChatLoop.editAlreadyVerifiedThisTurn(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification))
        XCTAssertFalse(ChatLoop.shouldVerifyEdits(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification, alreadyVerified: false))
    }

    func testDidEditFilesThisTurnDetectsEditTools() {
        let edited: [ChatMessage] = [
            msg(.user, "go"),
            msg(.assistant, "", calls: [.init(id: "e1", name: "apply_patch", arguments: "{}")]),
        ]
        XCTAssertTrue(ChatLoop.didEditFilesThisTurn(
            messages: edited, turnStartIndex: 0, mutatingToolNames: sampleMutating))

        let readOnly: [ChatMessage] = [
            msg(.user, "go"),
            msg(.assistant, "", calls: [.init(id: "r1", name: "read_file", arguments: "{}")]),
        ]
        XCTAssertFalse(ChatLoop.didEditFilesThisTurn(
            messages: readOnly, turnStartIndex: 0, mutatingToolNames: sampleMutating))
    }

    func testReflectionNudgeAfterThreeConsecutiveFailures() {
        XCTAssertTrue(ChatLoop.shouldNudgeReflection(recentToolErrorFlags: [false, true, true, true]))
        XCTAssertFalse(ChatLoop.shouldNudgeReflection(recentToolErrorFlags: [true, true, false]))
        XCTAssertFalse(ChatLoop.shouldNudgeReflection(recentToolErrorFlags: [true, true]))
    }

    func testDecisionLoggingNudgeFiresAfterEnoughToolUse() {
        var messages: [ChatMessage] = []
        for i in 0..<5 {
            messages.append(msg(.assistant, "", calls: [
                .init(id: "c\(i)", name: "read_file", arguments: "{}")]))
        }
        XCTAssertTrue(ChatLoop.shouldNudgeDecisionLogging(iterations: 6, messages: messages))
    }

    func testDecisionLoggingNudgeSkipsWhenAlreadyLogged() {
        var messages: [ChatMessage] = []
        for i in 0..<5 {
            messages.append(msg(.assistant, "", calls: [
                .init(id: "c\(i)", name: "read_file", arguments: "{}")]))
        }
        messages.append(msg(.assistant, "", calls: [
            .init(id: "d", name: "log_design_decision", arguments: "{}")]))
        XCTAssertFalse(ChatLoop.shouldNudgeDecisionLogging(iterations: 6, messages: messages))
    }

    func testDecisionLoggingNudgeIgnoresBookkeepingTools() {
        var messages: [ChatMessage] = []
        for i in 0..<5 {
            messages.append(msg(.assistant, "", calls: [
                .init(id: "c\(i)", name: "update_todo", arguments: "{}")]))
        }
        XCTAssertFalse(ChatLoop.shouldNudgeDecisionLogging(iterations: 6, messages: messages))
    }

    func testDecisionLoggingNudgeNeedsEnoughIterations() {
        var messages: [ChatMessage] = []
        for i in 0..<5 {
            messages.append(msg(.assistant, "", calls: [
                .init(id: "c\(i)", name: "read_file", arguments: "{}")]))
        }
        XCTAssertFalse(ChatLoop.shouldNudgeDecisionLogging(iterations: 3, messages: messages))
    }

    func testClaimsUnverifiedSuccessIsFalseForNeutralText() {
        XCTAssertFalse(ChatLoop.claimsUnverifiedSuccess("Here is the code."))
        XCTAssertFalse(ChatLoop.claimsUnverifiedSuccess("The function takes two arguments."))
    }

    func testClaimsUnverifiedSuccessHonoursCurlyApostropheCandor() {
        XCTAssertFalse(ChatLoop.claimsUnverifiedSuccess("I couldn’t create it — done."))
        XCTAssertFalse(ChatLoop.claimsUnverifiedSuccess("I can’t verify that; all set otherwise."))
    }

    func testEditBeforeTurnStartIsNotCounted() {
        let messages: [ChatMessage] = [
            msg(.user, "earlier task"),
            msg(.assistant, "", calls: [.init(id: "e0", name: "write_file", arguments: "{}")]),
            toolMsg("Wrote 10 bytes", id: "e0"),
            msg(.user, "now just look"),
            msg(.assistant, "", calls: [.init(id: "r1", name: "read_file", arguments: "{}")]),
            toolMsg("contents", id: "r1"),
            msg(.assistant, "Here's what I found."),
        ]
        XCTAssertFalse(ChatLoop.didEditFilesThisTurn(
            messages: messages, turnStartIndex: 3, mutatingToolNames: sampleMutating))
        XCTAssertFalse(ChatLoop.shouldVerifyEdits(
            messages: messages, turnStartIndex: 3,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification, alreadyVerified: false))
        XCTAssertTrue(ChatLoop.didEditFilesThisTurn(
            messages: messages, turnStartIndex: 0, mutatingToolNames: sampleMutating))
    }

    func testTurnStartIndexOutOfRangeIsSafe() {
        let messages: [ChatMessage] = [msg(.user, "hi"), msg(.assistant, "hello")]
        XCTAssertFalse(ChatLoop.didEditFilesThisTurn(
            messages: messages, turnStartIndex: 99, mutatingToolNames: sampleMutating))
        XCTAssertFalse(ChatLoop.editAlreadyVerifiedThisTurn(
            messages: messages, turnStartIndex: -1,
            mutatingToolNames: sampleMutating,
            verificationToolNames: sampleVerification))
    }
}