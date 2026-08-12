//
//  ChatViewModelContextBudgetTests.swift
//
//  Runtime integration: instantiates ChatViewModel, calls send(), and
//  asserts the resolved loop config uses 70% of the backend-advertised
//  context length (256K → 179,200 tokens).
//

import XCTest
import AgentCore
@testable import VibeCoderApp

@MainActor
final class ChatViewModelContextBudgetTests: XCTestCase {

    private final class FinishingBackend: InferenceBackend, @unchecked Sendable {
        let identifier: BackendIdentifier = .omlx
        let model: ModelDescriptor

        init(model: ModelDescriptor) { self.model = model }

        func listModels() async throws -> [ModelDescriptor] { [model] }

        func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.contentDelta("done"))
                continuation.yield(.done(finishReason: "stop"))
                continuation.finish()
            }
        }

        func cancel(streamID: UUID) async {}
    }

    func testSendResolves179200BudgetFromAdvertisedModelLength() async {
        let model = ModelDescriptor(
            id: "GLM-5.2-mxfp4",
            displayName: "GLM 5.2",
            backend: .omlx,
            contextLength: 256_000)
        let backend = FinishingBackend(model: model)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-vm-budget-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ModelSettingsStore(directoryURL: tempDir)
        var settings = AppSettings()
        settings.backend = .omlx
        settings.xcodeMCPEnabled = false
        _ = await store.load(modelId: model.id, defaults: settings)

        let app = AppViewModel()
        app.testingBackend = backend
        app.availableModels = [model]
        app.selectedModelID = model.id
        app.settings = settings

        let prepared = expectation(description: "loop config prepared")
        let vm = ChatViewModel(conversation: Conversation(), app: app, modelSettingsStore: store)
        vm.onLoopConfigPrepared = { config in
            // Printed for step-4(b) evidence capture in context-budget.log.
            print("VERIFY step4(b): onLoopConfigPrepared contextBudgetTokens=\(config.contextBudgetTokens) expected=179200")
            XCTAssertEqual(
                config.contextBudgetTokens,
                179_200,
                "ChatViewModel.send must resolve 70% of 256K advertised context")
            prepared.fulfill()
        }

        vm.send("exercise context budget path")
        await fulfillment(of: [prepared], timeout: 5)

        let budget = vm.lastPreparedLoopConfig?.contextBudgetTokens
        print("VERIFY step4(b): lastPreparedLoopConfig contextBudgetTokens=\(budget ?? -1) expected=179200")
        XCTAssertEqual(budget, 179_200)
        XCTAssertEqual(vm.lastPreparedModelSettings?.loadSettings.contextLength, 256_000,
                       "applyActivation via prepareChatRun must surface on ChatViewModel")
        XCTAssertEqual(app.activeModelSettings?.loadSettings.contextLength, 256_000,
                       "applyActivation must propagate to AppViewModel.activeModelSettings")
        vm.cancel()
    }
}