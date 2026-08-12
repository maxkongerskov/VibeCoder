//
//  ChatStatusSurfacesTests.swift
//
//  Polish P3 — status bar copy for hook deny, bg job wake, transient chrome.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

@MainActor
final class ChatStatusSurfacesTests: XCTestCase {

    func testHumanStatusHidesIterationCounters() {
        XCTAssertEqual(ChatViewModel.humanStatus("Iteration 4…"), "Working…")
        XCTAssertEqual(ChatViewModel.humanStatus("Hit iteration cap (30)"),
                       "Stopped — turn limit reached")
    }

    func testHumanStatusPolishesLegacyHookDeny() {
        XCTAssertEqual(
            ChatViewModel.humanStatus("Blocked by hook: no secrets"),
            "Prompt blocked: no secrets")
        XCTAssertEqual(
            ChatViewModel.humanStatus("Blocked by UserPromptSubmit hook."),
            "Prompt blocked by project hook.")
    }

    func testHumanStatusPreservesPromptBlockedForm() {
        XCTAssertEqual(
            ChatViewModel.humanStatus("Prompt blocked: policy"),
            "Prompt blocked: policy")
    }

    func testHumanBackgroundWakeStripsTaskId() {
        let raw = "Background subagent completed: explore (task_id=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)"
        let human = ChatViewModel.humanBackgroundWake(raw)
        XCTAssertEqual(human, "Subagent completed: explore")
        XCTAssertFalse(human.contains("task_id"))
        XCTAssertFalse(human.lowercased().contains("aaaaaaaa"))
    }

    func testHumanBackgroundWakeJobFailed() {
        let raw = "Background job failed: swift test — error: failed (task_id=11111111-2222-3333-4444-555555555555)"
        let human = ChatViewModel.humanStatus(raw)
        XCTAssertTrue(human.hasPrefix("Job failed:"), human)
        XCTAssertTrue(human.contains("swift test"), human)
        XCTAssertFalse(human.contains("task_id"), human)
    }

    func testIsTransientStatus() {
        XCTAssertTrue(ChatViewModel.isTransientStatus(""))
        XCTAssertTrue(ChatViewModel.isTransientStatus("Starting…"))
        XCTAssertTrue(ChatViewModel.isTransientStatus("Working…"))
        XCTAssertTrue(ChatViewModel.isTransientStatus("Iteration 2"))
        XCTAssertFalse(ChatViewModel.isTransientStatus("Prompt blocked: x"))
        XCTAssertFalse(ChatViewModel.isTransientStatus("Subagent completed: explore"))
    }

    func testDrainBackgroundJobCompletionsSetsStatusLine() async throws {
        await BackgroundJobManager.shared.cleanup()
        defer { Task { await BackgroundJobManager.shared.cleanup() } }

        let app = AppViewModel()
        var settings = AppSettings()
        settings.xcodeMCPEnabled = false
        app.settings = settings
        let convo = Conversation()
        let vm = ChatViewModel(conversation: convo, app: app)

        let id = try await BackgroundJobManager.shared.registerSubagent(
            description: "explore: p3-status",
            conversationID: convo.id)
        await BackgroundJobManager.shared.completeSubagent(
            id: id, output: "done finding", failed: false)

        await vm.drainBackgroundJobCompletions()
        XCTAssertFalse(vm.statusLine.isEmpty, "wake should set statusLine")
        XCTAssertTrue(
            vm.statusLine.lowercased().contains("subagent")
                || vm.statusLine.lowercased().contains("completed"),
            "expected human wake, got: \(vm.statusLine)")
        XCTAssertFalse(vm.statusLine.contains("task_id"),
                       "status should be humanized: \(vm.statusLine)")
    }
}
