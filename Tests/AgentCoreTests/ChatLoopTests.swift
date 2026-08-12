//
//  ChatLoopTests.swift
//
//  Unit tests for the pure helpers in ChatLoop that AgentLoop now wires
//  in (2026-06-09): history compaction, stall detection, and the
//  anti-confabulation gates. These were shipped untested while unwired;
//  now that the orchestrator calls them, their behaviour is pinned.
//

import XCTest
@testable import AgentCore

final class ChatLoopTests: XCTestCase {

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

    // MARK: - compactHistory

    func testCompactionLeavesShortHistoryUntouched() {
        let messages = [msg(.user, "hi"), msg(.assistant, "hello")]
        let out = ChatLoop.compactHistory(messages, systemPromptTokens: 100, budgetTokens: 10_000)
        XCTAssertEqual(out.map(\.content), messages.map(\.content))
    }

    func testCompactionElidesOldToolOutputFirst() {
        let bigToolOutput = String(repeating: "x", count: 40_000)
        var messages: [ChatMessage] = [
            msg(.user, "do the thing"),
            msg(.assistant, "", calls: [.init(id: "t1", name: "read_file", arguments: "{}")]),
            toolMsg(bigToolOutput),
        ]
        // Recent padding so the old tool message is outside keepRecent.
        for i in 0..<8 {
            messages.append(msg(.user, "follow-up \(i)"))
            messages.append(msg(.assistant, "answer \(i)"))
        }

        let out = ChatLoop.compactHistory(messages, systemPromptTokens: 0, budgetTokens: 2_000)

        // Structure intact: same count, same roles, tool_call pairing alive.
        XCTAssertEqual(out.count, messages.count)
        XCTAssertEqual(out[2].role, .tool)
        XCTAssertEqual(out[2].toolCallID, "t1")
        // Old tool body elided, marker present.
        XCTAssertLessThan(out[2].content.count, 2_000)
        XCTAssertTrue(out[2].content.contains("elided"))
        // User messages never touched.
        XCTAssertEqual(out[0].content, "do the thing")
    }

    func testCompactionNeverTouchesRecentMessages() {
        let big = String(repeating: "y", count: 30_000)
        var messages: [ChatMessage] = []
        for i in 0..<4 {
            messages.append(msg(.user, "q\(i)"))
            messages.append(msg(.assistant, "", calls: [.init(id: "c\(i)", name: "grep_code", arguments: "{}")]))
            messages.append(toolMsg(big, id: "c\(i)"))
        }
        let out = ChatLoop.compactHistory(messages, systemPromptTokens: 0,
                                          budgetTokens: 1_000, keepRecent: 3)
        // The last 3 messages are protected even when over budget.
        for i in (messages.count - 3)..<messages.count {
            XCTAssertEqual(out[i].content, messages[i].content,
                           "message \(i) is inside keepRecent and must be untouched")
        }
    }

    // MARK: - Stall / ping-pong detection

    func testDetectStuckPatternOnTripleRepeat() {
        XCTAssertNotNil(ChatLoop.detectStuckPattern(["a()", "a()", "a()"]))
        XCTAssertNil(ChatLoop.detectStuckPattern(["a()", "b()", "a()"]))
    }

    func testDetectStuckPatternOnPingPong() {
        XCTAssertNotNil(ChatLoop.detectStuckPattern(["a()", "b()", "a()", "b()"]))
        XCTAssertNil(ChatLoop.detectStuckPattern(["a()", "b()", "c()", "b()"]))
    }

    // MARK: - Anti-confabulation gates

    func testVerifyBeforeFinishFiresOnSuccessClaimAfterFailure() {
        // Trailing failure + a success claim → fire (the confabulation case).
        XCTAssertTrue(ChatLoop.shouldVerifyBeforeFinish(
            recentToolErrorFlags: [false, true],
            finalAssistantContent: "All done — created the file successfully."))
    }

    func testVerifyBeforeFinishSkipsHonestAnswerAfterFailure() {
        // Trailing failure but the answer is candid → don't force a pass
        // (this is the read-only `ls` / email-summary duplicate bug).
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

    func testShouldVerifyEditsRequiresEditThenSilence() {
        let editCall = ToolCallInvocation(id: "e1", name: "write_file", arguments: "{}")
        let messages: [ChatMessage] = [
            msg(.user, "fix it"),
            msg(.assistant, "", calls: [editCall]),
            toolMsg("Wrote 10 bytes", id: "e1"),
            msg(.assistant, "All done!"),          // finalizing without reading back
        ]
        XCTAssertTrue(ChatLoop.shouldVerifyEdits(messages: messages, turnStartIndex: 0,
                                                 mutatingToolNames: sampleMutating,
                                                 verificationToolNames: sampleVerification,
                                                 alreadyVerified: false))
        XCTAssertFalse(ChatLoop.shouldVerifyEdits(messages: messages, turnStartIndex: 0,
                                                  mutatingToolNames: sampleMutating,
                                                  verificationToolNames: sampleVerification,
                                                  alreadyVerified: true),
                       "the gate fires at most once per turn")
        // A read-only turn must not trip the gate.
        let readOnly: [ChatMessage] = [
            msg(.user, "look around"),
            msg(.assistant, "", calls: [.init(id: "r1", name: "read_file", arguments: "{}")]),
            toolMsg("contents", id: "r1"),
            msg(.assistant, "Here's what I found."),
        ]
        XCTAssertFalse(ChatLoop.shouldVerifyEdits(messages: readOnly, turnStartIndex: 0,
                                                  mutatingToolNames: sampleMutating,
                                                  verificationToolNames: sampleVerification,
                                                  alreadyVerified: false))
    }

    func testVerifyEditsSkipsWhenAgentAlreadyVerified() {
        // write_file, THEN run_shell to run it, then finalize. The agent
        // already checked its work — the gate must NOT fire (firing makes
        // the model repeat its final answer; observed in a headless run).
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
            mutatingToolNames: sampleMutating, verificationToolNames: sampleVerification))
        XCTAssertFalse(ChatLoop.shouldVerifyEdits(messages: messages, turnStartIndex: 0,
                                                  mutatingToolNames: sampleMutating,
                                                  verificationToolNames: sampleVerification,
                                                  alreadyVerified: false),
                       "gate must not fire when the agent already ran its edit")
    }

    func testVerifyEditsStillFiresWhenEditUnverified() {
        // Edit then immediately finalize with no read-back/run — this is
        // the confabulation case the gate exists for. Must still fire.
        let messages: [ChatMessage] = [
            msg(.user, "fix it"),
            msg(.assistant, "", calls: [.init(id: "e1", name: "write_file", arguments: "{}")]),
            toolMsg("Wrote 100 bytes", id: "e1"),
            msg(.assistant, "All done!"),
        ]
        XCTAssertFalse(ChatLoop.editAlreadyVerifiedThisTurn(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: sampleMutating, verificationToolNames: sampleVerification))
        XCTAssertTrue(ChatLoop.shouldVerifyEdits(messages: messages, turnStartIndex: 0,
                                                 mutatingToolNames: sampleMutating,
                                                 verificationToolNames: sampleVerification,
                                                 alreadyVerified: false))
    }

    func testVerificationBeforeEditDoesNotCount() {
        // read_file BEFORE the edit doesn't verify the edit that follows.
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
            mutatingToolNames: sampleMutating, verificationToolNames: sampleVerification),
                       "a read BEFORE the edit must not count as verifying it")
        XCTAssertTrue(ChatLoop.shouldVerifyEdits(messages: messages, turnStartIndex: 0,
                                                 mutatingToolNames: sampleMutating,
                                                 verificationToolNames: sampleVerification,
                                                 alreadyVerified: false))
    }

    func testMutatingClassificationMatchesRegisteredTools() async {
        await ToolRegistry.shared.registerBuiltins()
        let classification = await ToolClassification.load(
            registry: .shared, xcodeMCPEnabled: false)
        let all = await ToolRegistry.shared.all()
        for meta in all where meta.permission == .mutates {
            XCTAssertTrue(classification.mutating.contains(meta.name),
                          "registered mutating tool '\(meta.name)' missing from ToolClassification")
        }
    }

    // MARK: - Reflection nudge

    func testReflectionNudgeAfterThreeConsecutiveFailures() {
        XCTAssertTrue(ChatLoop.shouldNudgeReflection(recentToolErrorFlags: [false, true, true, true]))
        XCTAssertFalse(ChatLoop.shouldNudgeReflection(recentToolErrorFlags: [true, true, false]))
        XCTAssertFalse(ChatLoop.shouldNudgeReflection(recentToolErrorFlags: [true, true]))
    }

    // MARK: - Project instructions

    private func makeProjectDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-instructions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testLoadProjectInstructionsReadsAndFormats() throws {
        let root = try makeProjectDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let agentosDir = root.appendingPathComponent(".agentos")
        try FileManager.default.createDirectory(at: agentosDir, withIntermediateDirectories: true)
        try "Always use SwiftUI. Run swift test before declaring done."
            .write(to: agentosDir.appendingPathComponent("instructions.md"),
                   atomically: true, encoding: .utf8)

        let block = ChatLoop.loadProjectInstructions(projectRoot: root)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("# Project instructions"))
        XCTAssertTrue(block!.contains("Always use SwiftUI"))
    }

    func testLoadProjectInstructionsNilWhenAbsentOrEmpty() throws {
        let root = try makeProjectDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // No file at all.
        XCTAssertNil(ChatLoop.loadProjectInstructions(projectRoot: root))
        // Present but whitespace-only.
        let agentosDir = root.appendingPathComponent(".agentos")
        try FileManager.default.createDirectory(at: agentosDir, withIntermediateDirectories: true)
        try "   \n\t  ".write(to: agentosDir.appendingPathComponent("instructions.md"),
                              atomically: true, encoding: .utf8)
        XCTAssertNil(ChatLoop.loadProjectInstructions(projectRoot: root))
        // Nil project root.
        XCTAssertNil(ChatLoop.loadProjectInstructions(projectRoot: nil))
    }

    func testLoadProjectInstructionsTruncatesAtCap() throws {
        let root = try makeProjectDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let agentosDir = root.appendingPathComponent(".agentos")
        try FileManager.default.createDirectory(at: agentosDir, withIntermediateDirectories: true)
        try String(repeating: "x", count: 10_000)
            .write(to: agentosDir.appendingPathComponent("instructions.md"),
                   atomically: true, encoding: .utf8)

        let block = ChatLoop.loadProjectInstructions(projectRoot: root, cap: 500)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("…(truncated)"))
        XCTAssertLessThan(block!.count, 1_000)
    }
}
