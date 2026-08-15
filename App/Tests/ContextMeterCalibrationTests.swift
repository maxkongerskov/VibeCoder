//
//  ContextMeterCalibrationTests.swift
//
//  Unit tests for the context-meter calibration: when the model server
//  reports real `prompt_tokens`, the meter anchors to that number plus the
//  estimated growth since the last response, and falls back to the pure
//  chars/4 estimate when no valid anchor exists.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

@MainActor
final class ContextMeterCalibrationTests: XCTestCase {

    /// A fresh view model with an empty system prompt so the wire estimate is
    /// small and predictable. Returns the view model (the app is retained by
    /// the view model for the test's lifetime).
    private func makeViewModel() -> ChatViewModel {
        let app = AppViewModel()
        var settings = AppSettings()
        settings.systemPrompt = ""
        app.settings = settings
        app.selectedModelID = "test-model"
        return ChatViewModel(conversation: Conversation(), app: app)
    }

    /// Seed a valid anchor for the current conversation + model.
    private func seedValidAnchor(_ vm: ChatViewModel, promptTokens: Int, anchorEstimate: Int) {
        vm.usageAnchorPromptTokens = promptTokens
        vm.usageAnchorEstimatedTotal = anchorEstimate
        vm.usageAnchorConversationID = vm.conversation.id
        vm.usageAnchorModelID = vm.activeThinkingModelID
    }

    func testCalibratedWhenValidAnchor() {
        let vm = makeViewModel()
        vm.conversation.messages = [.init(role: .user, content: "hello")]
        seedValidAnchor(vm, promptTokens: 1000, anchorEstimate: 1)

        XCTAssertTrue(vm.contextUsageBreakdown.isCalibrated)
        // Calibrated total = 1000 + (now - 1). `now` is small for a short
        // conversation, so the total sits just above 1000 — far above the
        // pure chars/4 estimate (~10 tokens here).
        let tokens = vm.liveContextTokens
        XCTAssertGreaterThanOrEqual(tokens, 1000)
        XCTAssertLessThan(tokens, 1100)
        // The status-bar meter and the breakdown sheet must agree.
        XCTAssertEqual(tokens, vm.contextUsageBreakdown.totalTokens)
    }

    func testCalibratedTotalGrowsWithNewContent() {
        let vm = makeViewModel()
        vm.conversation.messages = [.init(role: .user, content: "hello")]
        seedValidAnchor(vm, promptTokens: 1000, anchorEstimate: 1)
        let before = vm.liveContextTokens

        // A new tool result grows the conversation → the calibrated total
        // must grow by roughly the estimated size of the added content.
        vm.conversation.messages.append(
            .init(role: .tool, content: String(repeating: "x", count: 400), toolCallID: "t1"))
        let after = vm.liveContextTokens
        XCTAssertGreaterThan(after, before,
                             "calibrated total must track growth since the anchor")
    }

    func testFallsBackWhenNoAnchor() {
        let vm = makeViewModel()
        vm.conversation.messages = [.init(role: .user, content: "hello")]
        // No anchor set (server didn't report usage).
        XCTAssertNil(vm.usageAnchorPromptTokens)
        XCTAssertFalse(vm.contextUsageBreakdown.isCalibrated)
        // Pure estimate — small for a short conversation.
        XCTAssertLessThan(vm.liveContextTokens, 100)
    }

    func testFallsBackWhenConversationChanged() {
        let vm = makeViewModel()
        vm.conversation.messages = [.init(role: .user, content: "hello")]
        vm.usageAnchorPromptTokens = 1000
        vm.usageAnchorEstimatedTotal = 1
        vm.usageAnchorConversationID = UUID()   // stale: different conversation
        vm.usageAnchorModelID = vm.activeThinkingModelID
        XCTAssertFalse(vm.contextUsageBreakdown.isCalibrated)
        XCTAssertLessThan(vm.liveContextTokens, 100)
    }

    func testFallsBackWhenModelChanged() {
        let vm = makeViewModel()
        vm.conversation.messages = [.init(role: .user, content: "hello")]
        vm.usageAnchorPromptTokens = 1000
        vm.usageAnchorEstimatedTotal = 1
        vm.usageAnchorConversationID = vm.conversation.id
        vm.usageAnchorModelID = "some-other-model"   // stale: model switch
        XCTAssertFalse(vm.contextUsageBreakdown.isCalibrated)
        XCTAssertLessThan(vm.liveContextTokens, 100)
    }

    func testFallsBackWhenConversationShrank() {
        let vm = makeViewModel()
        vm.conversation.messages = [.init(role: .user, content: "hi")]
        // Anchor captured when the conversation was much larger than now.
        seedValidAnchor(vm, promptTokens: 1000, anchorEstimate: 10_000)
        XCTAssertFalse(vm.contextUsageBreakdown.isCalibrated,
                       "a shrunken conversation means the anchor is stale")
        XCTAssertLessThan(vm.liveContextTokens, 100)
    }
}
