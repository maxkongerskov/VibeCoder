import XCTest
@testable import AgentCore

final class AgentRunBootstrapTests: XCTestCase {

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            do {
                let (code, data) = try handler(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: code,
                    httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testPrepareChatRunResolves179200BudgetFromAdvertisedLength() async throws {
        MockURLProtocol.handler = { req in
            switch req.url?.path {
            case "/v1/models":
                let body = """
                {"data":[{"id":"GLM-5.2-mxfp4","context_length":256000}]}
                """
                return (200, Data(body.utf8))
            case "/v1/models/status":
                let body = "{\"status\":\"ok\"}"
                return (200, Data(body.utf8))
            default:
                let body = "{\"error\":\"not found\"}"
                return (404, Data(body.utf8))
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        let backend = OMLXBackend(session: session)
        let models = try await backend.listModels()
        XCTAssertEqual(models.first?.contextLength, 256_000)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ModelSettingsStore(directoryURL: tempDir)
        var appSettings = AppSettings()
        appSettings.xcodeMCPEnabled = false
        let (loopConfig, _, modelSettings) = await AgentRunBootstrap.prepareChatRun(
            workerModel: models[0],
            settings: appSettings,
            store: store,
            xcodeMCPLive: false,
            headless: false,
            safeMode: nil,
            patchReviewer: nil,
            orchestratorBrief: nil)
        XCTAssertEqual(modelSettings.loadSettings.contextLength, 256_000,
                       "applyActivation must persist advertised context into ModelSettings")
        print("VERIFY step4(a): prepareChatRun contextBudgetTokens=\(loopConfig.contextBudgetTokens) expected=179200 storedCtx=\(modelSettings.loadSettings.contextLength)")
        XCTAssertEqual(loopConfig.contextBudgetTokens, 179_200)
    }

    func testPrepareChatRunPassesStallWindowFromSettings() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ModelSettingsStore(directoryURL: tempDir)
        var appSettings = AppSettings()
        appSettings.stallWindow = 5
        let model = ModelDescriptor(id: "test", displayName: "Test", backend: .lmStudio)
        let (loopConfig, _, _) = await AgentRunBootstrap.prepareChatRun(
            workerModel: model,
            settings: appSettings,
            store: store,
            xcodeMCPLive: false,
            headless: false,
            safeMode: nil,
            patchReviewer: nil,
            orchestratorBrief: nil)
        XCTAssertEqual(loopConfig.stallWindow, 5)
    }

    /// Developer Inference UI writes ModelSettingsStore; chat must see those
    /// values (including maxTokens) via prepareChatRun — not only AppSettings.defaultSampling.
    func testPrepareChatRunSamplingMatchesModelSettingsStoreInference() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-inf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ModelSettingsStore(directoryURL: tempDir)
        var appSettings = AppSettings()
        // Global defaults deliberately different from the values we persist.
        appSettings.defaultSampling = SamplingParams(
            temperature: 0.1, topP: 0.5, topK: 10, repeatPenalty: 1.0, maxTokens: 16)
        let modelId = "org/model-GGUF::weights-Q4_K_M.gguf"
        let model = ModelDescriptor(
            id: modelId, displayName: "weights", backend: .ollama, contextLength: 8192)

        // First activation freezes initial settings from defaults.
        _ = await store.applyActivation(
            modelId: modelId, defaults: appSettings, advertised: 8192)

        // Simulate Developer Inference sliders saving per-model inference.
        await store.update(modelId: modelId, defaults: appSettings) { ms in
            ms.inferenceSettings.temperature = 0.42
            ms.inferenceSettings.topP = 0.88
            ms.inferenceSettings.topK = 33
            ms.inferenceSettings.repeatPenalty = 1.17
            ms.inferenceSettings.maxTokens = 512
        }

        // Changing global defaultSampling must NOT override the store for this model.
        appSettings.defaultSampling = SamplingParams(
            temperature: 0.99, topP: 0.99, topK: 99, repeatPenalty: 1.5, maxTokens: 7)

        let (_, sampling, modelSettings) = await AgentRunBootstrap.prepareChatRun(
            workerModel: model,
            settings: appSettings,
            store: store,
            xcodeMCPLive: false,
            headless: false,
            safeMode: nil,
            patchReviewer: nil,
            orchestratorBrief: nil)

        XCTAssertEqual(sampling.temperature, 0.42, accuracy: 0.0001)
        XCTAssertEqual(sampling.topP, 0.88, accuracy: 0.0001)
        XCTAssertEqual(sampling.topK, 33)
        XCTAssertEqual(sampling.repeatPenalty, 1.17, accuracy: 0.0001)
        XCTAssertEqual(sampling.maxTokens, 512)
        XCTAssertEqual(modelSettings.inferenceSettings.maxTokens, 512)
        XCTAssertEqual(modelSettings.samplingParams().temperature, sampling.temperature, accuracy: 0.0001)
    }

    func testXcodeMCPSuppressesXcodeBuildWithDynamicMcpTools() async throws {
        await ToolRegistry.shared.registerBuiltins()

        let mcpEntry: [String: Any] = [
            "name": "BuildProject",
            "description": "Build the open project",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "tabIdentifier": ["type": "string", "description": "tab"],
                ],
                "required": ["tabIdentifier"],
            ],
        ]
        guard let schema = XcodeMCPBridge.toolSchema(from: mcpEntry) else {
            return XCTFail("Expected MCP schema")
        }
        let meta = ToolRegistry.ToolMetadata(
            name: schema.name,
            category: .build,
            permission: .readOnly,
            availability: .platformGated(check: { true }),
            schema: schema)
        await ToolRegistry.shared.registerDynamicTool(metadata: meta) { _, _ in
            ToolResult(content: "built")
        }

        var appSettings = AppSettings()
        appSettings.xcodeMCPEnabled = true
        let loopConfig = AgentRunBootstrap.buildLoopConfiguration(
            modelSettings: ModelSettings(
                modelId: "test",
                loadSettings: .init(
                    contextLength: ModelSettings.defaultContextLength,
                    gpuOffloadLayers: ModelSettings.defaultGPUOffloadLayers,
                    flashAttention: ModelSettings.defaultFlashAttention,
                    kvCacheType: ModelSettings.defaultKVCacheType),
                inferenceSettings: .init(
                    temperature: 0.7, topP: 0.9, topK: 40, repeatPenalty: 1.0),
                savedAt: Date()),
            workerModel: ModelDescriptor(id: "test", displayName: "Test", backend: .lmStudio),
            settings: appSettings,
            xcodeMCPLive: true,
            headless: false,
            safeMode: nil,
            patchReviewer: nil,
            orchestratorBrief: nil).config

        XCTAssertTrue(loopConfig.xcodeMCPEnabled)

        let schemas = await ToolSchemaAssembler.baseSchemas(
            registry: .shared,
            conversation: Conversation(),
            config: loopConfig)
        let names = Set(schemas.map(\.name))
        XCTAssertFalse(names.contains("xcode_build"))
        XCTAssertTrue(names.contains("BuildProject"))

        await ToolRegistry.shared.unregisterDynamicTools(names: ["BuildProject"])
    }
}