import XCTest
@testable import AgentCore

/// AC3 regression: `applyActivation` / `applyActivations` single seam.
final class ModelSettingsStoreTests: XCTestCase {

    private func tempStore() throws -> (ModelSettingsStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ModelSettingsStore(directoryURL: dir), dir)
    }

    func testApplyActivationSeeds256KFromAdvertised() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = AppSettings()

        let settings = await store.applyActivation(
            modelId: "GLM-5.2-mxfp4",
            defaults: defaults,
            advertised: 256_000)

        XCTAssertEqual(settings.loadSettings.contextLength, 256_000)
        let model = ModelDescriptor(
            id: "GLM-5.2-mxfp4",
            displayName: "GLM 5.2",
            backend: .omlx,
            contextLength: 256_000)
        XCTAssertEqual(
            ContextBudget.resolveForChatRun(
                modelSettings: settings.loadSettings,
                workerModel: model),
            179_200)
    }

    func testApplyActivationsBatchPersistsAllListedModels() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = AppSettings()
        let models = [
            ModelDescriptor(
                id: "GLM-5.2-mxfp4",
                displayName: "GLM 5.2",
                backend: .omlx,
                contextLength: 256_000),
            ModelDescriptor(
                id: "qwen3-coder",
                displayName: "Qwen3",
                backend: .lmStudio,
                contextLength: 131_072),
        ]

        await store.applyActivations(models: models, defaults: defaults)

        let glm = await store.load(modelId: "GLM-5.2-mxfp4", defaults: defaults)
        let qwen = await store.load(modelId: "qwen3-coder", defaults: defaults)
        XCTAssertEqual(glm.loadSettings.contextLength, 256_000)
        XCTAssertEqual(qwen.loadSettings.contextLength, 131_072)
    }

    func testApplyActivationSkipsWhenStoredAlreadyLarger() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = AppSettings()
        var manual = ModelSettings.initial(modelId: "custom", from: defaults)
        manual.loadSettings.contextLength = 300_000
        await store.save(manual)

        let settings = await store.applyActivation(
            modelId: "custom",
            defaults: defaults,
            advertised: 256_000)
        XCTAssertEqual(settings.loadSettings.contextLength, 300_000)
    }

    func testPrepareChatRunUsesApplyActivationFor179200Budget() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = ModelDescriptor(
            id: "GLM-5.2-mxfp4",
            displayName: "GLM 5.2",
            backend: .omlx,
            contextLength: 256_000)
        var appSettings = AppSettings()
        appSettings.xcodeMCPEnabled = false

        let (loopConfig, _, modelSettings) = await AgentRunBootstrap.prepareChatRun(
            workerModel: model,
            settings: appSettings,
            store: store,
            xcodeMCPLive: false,
            headless: false,
            safeMode: nil,
            patchReviewer: nil,
            orchestratorBrief: nil)

        XCTAssertEqual(modelSettings.loadSettings.contextLength, 256_000)
        print("VERIFY step4(a): prepareChatRun contextBudgetTokens=\(loopConfig.contextBudgetTokens) expected=179200 storedCtx=\(modelSettings.loadSettings.contextLength)")
        XCTAssertEqual(loopConfig.contextBudgetTokens, 179_200)
    }
}