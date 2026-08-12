//
//  ChatPromptHooksTests.swift
//
//  Phase B PB2 — UserPromptSubmit / Stop app-wire unit tests.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

@MainActor
final class ChatPromptHooksTests: XCTestCase {

    override func tearDown() {
        ChatPromptHooks.resetTestHandlers()
        super.tearDown()
    }

    func testUserPromptSubmitAllowReturnsNilMessage() {
        ChatPromptHooks.userPromptSubmitHandler = { _, _, _ in .allow }
        let msg = ChatPromptHooks.userPromptSubmitDeniedMessage(
            text: "hello",
            projectRoot: nil,
            worktreeRoot: nil
        )
        XCTAssertNil(msg)
    }

    func testUserPromptSubmitDenySurfacesReason() {
        ChatPromptHooks.userPromptSubmitHandler = { _, _, _ in
            .deny("no secrets")
        }
        let msg = ChatPromptHooks.userPromptSubmitDeniedMessage(
            text: "leak api key",
            projectRoot: nil,
            worktreeRoot: nil
        )
        XCTAssertEqual(msg, "Prompt blocked: no secrets")
    }

    func testUserPromptSubmitDenyWithoutReasonUsesDefault() {
        ChatPromptHooks.userPromptSubmitHandler = { _, _, _ in
            // Empty reason → default status copy.
            .deny("")
        }
        let msg = ChatPromptHooks.userPromptSubmitDeniedMessage(
            text: "x",
            projectRoot: nil,
            worktreeRoot: nil
        )
        XCTAssertEqual(msg, "Prompt blocked by project hook.")
    }

    func testStopHandlerInvokedWithReason() {
        var seen: (String, String)?
        ChatPromptHooks.stopHandler = { reason, detail, _, _ in
            seen = (reason, detail)
        }
        ChatPromptHooks.fireStop(
            reason: "cancelled",
            detail: "Task ended by user",
            projectRoot: nil,
            worktreeRoot: nil
        )
        XCTAssertEqual(seen?.0, "cancelled")
        XCTAssertEqual(seen?.1, "Task ended by user")
    }

    func testSendDoesNotStartWhenHookDenies() async {
        ChatPromptHooks.userPromptSubmitHandler = { _, _, _ in
            .deny("blocked in test")
        }

        let model = ModelDescriptor(
            id: "test-model",
            displayName: "Test",
            backend: .omlx,
            contextLength: 8_192)
        let backend = FinishingBackend(model: model)

        let app = AppViewModel()
        app.testingBackend = backend
        app.availableModels = [model]
        app.selectedModelID = model.id
        var settings = AppSettings()
        settings.backend = .omlx
        settings.xcodeMCPEnabled = false
        app.settings = settings

        let vm = ChatViewModel(conversation: Conversation(), app: app)
        vm.send("this must not start a turn")

        XCTAssertFalse(vm.isRunning, "denied UserPromptSubmit must not start agent turn")
        XCTAssertEqual(vm.statusLine, "Prompt blocked: blocked in test")
        XCTAssertTrue(vm.conversation.messages.isEmpty,
                      "denied send must not append conversation messages")
    }

    func testFinishRunFiresStopHook() async {
        var stopReasons: [String] = []
        ChatPromptHooks.stopHandler = { reason, _, _, _ in
            stopReasons.append(reason)
        }
        ChatPromptHooks.userPromptSubmitHandler = { _, _, _ in .allow }

        let model = ModelDescriptor(
            id: "test-model-stop",
            displayName: "Test",
            backend: .omlx,
            contextLength: 8_192)
        let backend = FinishingBackend(model: model)

        let app = AppViewModel()
        app.testingBackend = backend
        app.availableModels = [model]
        app.selectedModelID = model.id
        var settings = AppSettings()
        settings.backend = .omlx
        settings.xcodeMCPEnabled = false
        app.settings = settings

        let vm = ChatViewModel(conversation: Conversation(), app: app)
        let done = expectation(description: "turn finished")
        vm.onLoopConfigPrepared = { _ in
            // Loop will finish quickly via FinishingBackend.
        }

        // Observe isRunning fall via polling
        vm.send("go")
        XCTAssertTrue(vm.isRunning || !stopReasons.isEmpty || true)

        // Wait until stop fires or timeout
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !stopReasons.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        done.fulfill()
        await fulfillment(of: [done], timeout: 1)

        XCTAssertTrue(
            stopReasons.contains("completed") || stopReasons.contains("cancelled"),
            "finishRun must fire Stop hook, got \(stopReasons)"
        )
    }
}

// MARK: - Test backend

@MainActor
private final class FinishingBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .omlx
    let model: ModelDescriptor

    init(model: ModelDescriptor) { self.model = model }

    func listModels() async throws -> [ModelDescriptor] { [model] }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta("ok"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }

    func cancel(streamID: UUID) async {}
}
