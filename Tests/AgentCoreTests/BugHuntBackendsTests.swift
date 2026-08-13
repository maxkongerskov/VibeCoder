import XCTest
@testable import AgentCore

/// Verification-first backend bug hunt. Assertions describe the
/// intended contract; failures are the reproduced defects.
final class BugHuntBackendsTests: XCTestCase {

    // MARK: - Mock URLProtocol

    final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data, [String: String]?))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            do {
                let (code, data, headers) = try handler(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: code,
                    httpVersion: nil, headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(base: String = "http://127.0.0.1:9/v1") -> OpenAICompatibleClient {
        OpenAICompatibleClient(
            config: .init(baseURL: URL(string: base)!),
            session: makeSession())
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func collectChunks(from client: OpenAICompatibleClient, sse: String) async throws -> [ChatChunk] {
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url?.path.contains("chat/completions") ?? false)
            return (200, Data(sse.utf8), ["Content-Type": "text/event-stream"])
        }
        let body = ChatCompletionRequestBody(
            model: "m",
            messages: [.init(role: "user", content: "hi")],
            sampling: .coder)
        var chunks: [ChatChunk] = []
        let stream = await client.streamChatCompletion(streamID: UUID(), body: body)
        for try await chunk in stream { chunks.append(chunk) }
        return chunks
    }

    private func doneReasons(_ chunks: [ChatChunk]) -> [String] {
        chunks.compactMap { chunk in
            if case .done(let r) = chunk { return r }
            return nil
        }
    }

    private func contentText(_ chunks: [ChatChunk]) -> String {
        chunks.compactMap { chunk -> String? in
            if case .contentDelta(let s) = chunk { return s }
            return nil
        }.joined()
    }

    private func toolDeltas(_ chunks: [ChatChunk]) -> [(Int, String?, String?, String?)] {
        chunks.compactMap { chunk in
            if case .toolCallDelta(let i, let id, let name, let args) = chunk {
                return (i, id, name, args)
            }
            return nil
        }
    }

    // MARK: - ChatCompletionChunk / SSE mapping

    /// Some OpenAI-compat servers emit a terminator with `finish_reason`
    /// and no `delta`. `Choice.delta` is required, so the client skips
    /// the event and `[DONE]` fabricates `stop`.
    func testFinishReasonOnlyChunkPreservesToolCallsReason() async throws {
        let sse = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\\"p\\":1}"}}]}}]}

        data: {"choices":[{"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        let chunks = try await collectChunks(from: makeClient(), sse: sse)
        XCTAssertFalse(toolDeltas(chunks).isEmpty, "tool deltas should survive")
        XCTAssertEqual(
            doneReasons(chunks),
            ["tool_calls"],
            "finish_reason-only chunk (no delta) must not be overwritten with stop. chunks=\(chunks)")
    }

    func testFinishReasonOnlyChunkDecodesAsChatCompletionChunk() throws {
        let json = Data(#"{"choices":[{"finish_reason":"tool_calls"}]}"#.utf8)
        do {
            let raw = try JSONDecoder().decode(ChatCompletionChunk.self, from: json)
            let mapped = ChatChunkMapper().map(raw)
            let reasons = mapped.compactMap { c -> String? in
                if case .done(let r) = c { return r }
                return nil
            }
            XCTAssertEqual(reasons, ["tool_calls"], "mapped=\(mapped)")
        } catch {
            XCTFail("ChatCompletionChunk must decode finish_reason-only choice (missing delta): \(error)")
        }
    }

    /// Local servers (Ollama, some llama.cpp builds) emit
    /// `function.arguments` as a JSON object. The wire type requires
    /// String, so the whole SSE event is skipped.
    func testToolCallArgumentsObjectIsAccepted() async throws {
        let sse = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":{"path":"."}}}]}}]}

        data: [DONE]

        """
        let chunks = try await collectChunks(from: makeClient(), sse: sse)
        let deltas = toolDeltas(chunks)
        XCTAssertFalse(
            deltas.isEmpty,
            "object-valued tool arguments must not drop the tool call. chunks=\(chunks)")
        XCTAssertEqual(deltas.first?.2, "read_file")
    }

    /// Incomplete `usage` (missing completion_tokens) on the same event
    /// as content makes decode fail-closed: content is discarded too.
    func testIncompleteUsageDoesNotDropContent() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10}}

        data: [DONE]

        """
        let chunks = try await collectChunks(from: makeClient(), sse: sse)
        XCTAssertEqual(
            contentText(chunks),
            "hello",
            "partial usage object must not discard sibling content. chunks=\(chunks)")
    }

    func testNonSSEJSONCompletionIsNotSilentEmptySuccess() async throws {
        MockURLProtocol.handler = { _ in
            let body = #"{"choices":[{"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}]}"#
            return (200, Data(body.utf8), ["Content-Type": "application/json"])
        }
        let client = makeClient()
        let body = ChatCompletionRequestBody(
            model: "m",
            messages: [.init(role: "user", content: "hi")],
            sampling: .coder)
        var chunks: [ChatChunk] = []
        let stream = await client.streamChatCompletion(streamID: UUID(), body: body)
        for try await chunk in stream { chunks.append(chunk) }
        XCTAssertFalse(
            chunks.isEmpty,
            "non-SSE 200 completion must yield content or throw, not succeed with zero chunks")
    }

    // MARK: - RetryPolicy / hard-connect needles

    func testHardConnectMatchesURLSessionOfflineLocalizedDescription() {
        let offline = "The Internet connection appears to be offline."
        XCTAssertTrue(
            RetryClassifier.isHardConnectFailure(offline),
            "offline URLSession copy must short-circuit like code=-1009")

        let urlError = URLError(.notConnectedToInternet).localizedDescription
        XCTAssertTrue(
            RetryClassifier.isHardConnectFailure(urlError),
            "URLError.notConnectedToInternet.localizedDescription must match (got \(urlError))")
    }

    func testHardConnectMatchesCannotFindHost() {
        let dns = "A server with the specified hostname could not be found."
        XCTAssertTrue(
            RetryClassifier.isHardConnectFailure(dns),
            "DNS / cannot-find-host must not burn the 15-retry budget")

        let urlError = URLError(.cannotFindHost).localizedDescription
        XCTAssertTrue(
            RetryClassifier.isHardConnectFailure(urlError),
            "URLError.cannotFindHost.localizedDescription must match (got \(urlError))")
    }

    func testOfflineClassifiesAsHardConnectEscalate() {
        let err = BackendError.transport("The Internet connection appears to be offline.")
        if case .escalate = RetryClassifier.classify(
            err, attemptCount: RetryPolicy.hardConnectRetryThreshold
        ) {} else {
            let outcome = RetryClassifier.classify(
                err, attemptCount: RetryPolicy.hardConnectRetryThreshold)
            XCTFail("offline should escalate at hardConnect threshold, got \(outcome)")
        }
    }

    // MARK: - DoomLoopDetector

    func testDoomLoopTakeDrainsRecordedSignals() {
        let detector = DoomLoopDetector()
        detector.recordClientRepetition(4)
        XCTAssertEqual(detector.take().count, 1)
        XCTAssertEqual(
            detector.take().count,
            0,
            "take() is documented to drain; a second take must be empty")
    }

    // MARK: - OMLX encode drops thinking (custom backend is the control)

    func testOMLXEncodeForwardsThinkingEffort() async throws {
        guard let cap = ThinkingModelScanner.detect(modelId: "GLM-5.2-mxfp4") else {
            return XCTFail("scanner should detect GLM")
        }
        final class Capture: @unchecked Sendable {
            var body: Data?
        }
        let capture = Capture()
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/models/status") {
                let status = """
                {"loaded_count":1,"models":[{"id":"GLM-5.2-mxfp4","loaded":true}]}
                """
                return (200, Data(status.utf8), nil)
            }
            if path.contains("chat/completions") {
                if let data = req.httpBody {
                    capture.body = data
                } else if let stream = req.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                    defer { buffer.deallocate() }
                    while stream.hasBytesAvailable {
                        let n = stream.read(buffer, maxLength: 4096)
                        if n <= 0 { break }
                        data.append(buffer, count: n)
                    }
                    capture.body = data
                }
                let sse = #"data: {"choices":[{"delta":{"content":"ok"}}]}"# + "\n\ndata: [DONE]\n\n"
                return (200, Data(sse.utf8), ["Content-Type": "text/event-stream"])
            }
            return (404, Data(), nil)
        }

        let backend = OMLXBackend(host: "127.0.0.1", port: 8080, apiKey: "k", session: makeSession())
        let request = ChatRequest(
            model: ModelDescriptor(
                id: "GLM-5.2-mxfp4",
                displayName: "GLM",
                backend: .omlx,
                supportsTools: true),
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: [],
            sampling: .coder,
            thinking: ThinkingRequestConfig(capability: cap, effort: .high))

        var sawContent = false
        for try await chunk in backend.stream(request: request) {
            if case .contentDelta = chunk { sawContent = true }
        }
        XCTAssertTrue(sawContent, "preflight/load must succeed so encode is exercised")

        let data = try XCTUnwrap(capture.body, "chat POST body missing")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let thinking = obj?["thinking"] as? [String: Any]
        XCTAssertEqual(
            thinking?["type"] as? String,
            "enabled",
            "oMLX must forward GLM thinking params; body=\(obj ?? [:])")
        XCTAssertEqual(
            obj?["reasoning_effort"] as? String,
            "high",
            "oMLX must forward reasoning_effort; body=\(obj ?? [:])")
    }

    func testOpenAICompatibleBackendForwardsThinkingEffort() async throws {
        guard let cap = ThinkingModelScanner.detect(modelId: "GLM-5.2-mxfp4") else {
            return XCTFail("scanner should detect GLM")
        }
        final class Capture: @unchecked Sendable {
            var body: Data?
        }
        let capture = Capture()
        MockURLProtocol.handler = { req in
            if req.url?.path.contains("chat/completions") == true {
                if let data = req.httpBody {
                    capture.body = data
                } else if let stream = req.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                    defer { buffer.deallocate() }
                    while stream.hasBytesAvailable {
                        let n = stream.read(buffer, maxLength: 4096)
                        if n <= 0 { break }
                        data.append(buffer, count: n)
                    }
                    capture.body = data
                }
                let sse = #"data: {"choices":[{"delta":{"content":"ok"}}]}"# + "\n\ndata: [DONE]\n\n"
                return (200, Data(sse.utf8), ["Content-Type": "text/event-stream"])
            }
            return (404, Data(), nil)
        }

        let backend = OpenAICompatibleBackend(
            baseURL: URL(string: "http://127.0.0.1:9/v1")!,
            session: makeSession())
        let request = ChatRequest(
            model: ModelDescriptor(
                id: "GLM-5.2-mxfp4",
                displayName: "GLM",
                backend: .custom,
                supportsTools: true),
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: [],
            sampling: .coder,
            thinking: ThinkingRequestConfig(capability: cap, effort: .high))

        for try await _ in backend.stream(request: request) {}

        let data = try XCTUnwrap(capture.body, "chat POST body missing")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["reasoning_effort"] as? String, "high", "body=\(obj ?? [:])")
    }

    // MARK: - XAI context default

    func testXAILiveListUsesFallbackContextForGrok3() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url?.path.hasSuffix("/models") ?? false)
            let body = #"{"data":[{"id":"grok-3"},{"id":"grok-3-mini"},{"id":"grok-2-latest"}]}"#
            return (200, Data(body.utf8), nil)
        }
        let backend = XAIBackend(apiKey: "test-key", session: makeSession())
        let models = try await backend.listModels()
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        XCTAssertEqual(
            byID["grok-3"]?.contextLength,
            131_072,
            "live /v1/models without context_length must keep the known Grok 3 window, not 256k")
        XCTAssertEqual(byID["grok-3-mini"]?.contextLength, 131_072)
        XCTAssertEqual(byID["grok-2-latest"]?.contextLength, 131_072)
    }

    // MARK: - MLXInferenceService.listModels

    func testMLXListModelsFiltersToDownloadedSnapshots() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let downloader = MLXHubDownloader(cacheBase: tmp)
        let service = MLXInferenceService(downloader: downloader)
        let models = try await service.listModels()
        XCTAssertFalse(CuratedMLXCatalog.all.isEmpty, "catalog fixture must be non-empty")
        XCTAssertTrue(
            models.isEmpty,
            "listModels is documented to return only locally-downloaded snapshots; empty cache must be empty, got \(models.map(\.id))")
    }

    // MARK: - OMLX listModels duplicate ids

    /// `Dictionary(uniqueKeysWithValues:)` traps on duplicate keys.
    /// Named `testZ_` so it runs last and does not hide earlier failures.
    func testZ_OMLXListModelsDuplicateIDsMustNotTrap() async throws {
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/models/status") {
                let status = #"{"loaded_count":0,"models":[{"id":"base","loaded":false}]}"#
                return (200, Data(status.utf8), nil)
            }
            if path.hasSuffix("/models") {
                let body = #"{"data":[{"id":"dup"},{"id":"dup","context_length":8192}]}"#
                return (200, Data(body.utf8), nil)
            }
            return (404, Data(), nil)
        }
        let backend = OMLXBackend(host: "127.0.0.1", port: 8080, session: makeSession())
        let models = try await backend.listModels()
        XCTAssertFalse(models.isEmpty, "duplicate /v1/models ids must not crash listModels")
    }
}
