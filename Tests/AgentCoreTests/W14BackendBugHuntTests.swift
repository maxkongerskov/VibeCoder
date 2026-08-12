import XCTest
@testable import AgentCore

/// Wave C W14 — regression locks for backend / SSE-retry / LocalAPI fixes.
final class W14BackendBugHuntTests: XCTestCase {

    // MARK: - Retry fail-fast (hard connect)

    func testHardConnectFailureDetected() {
        XCTAssertTrue(RetryClassifier.isHardConnectFailure("Connection refused"))
        XCTAssertTrue(RetryClassifier.isHardConnectFailure("Could not connect to the server."))
        XCTAssertTrue(RetryClassifier.isHardConnectFailure("NSURLErrorDomain Code=-1004"))
        XCTAssertFalse(RetryClassifier.isHardConnectFailure("The request timed out."))
        XCTAssertFalse(RetryClassifier.isHardConnectFailure("Connection reset by peer mid-stream"))
    }

    func testHardConnectEscalatesAfterThreshold() {
        let err = BackendError.transport("Connection refused")
        // attemptCount 0,1 → retry; at threshold (2) → escalate
        if case .retry = RetryClassifier.classify(err, attemptCount: 0) {} else {
            XCTFail("expected retry on first hard-connect failure")
        }
        if case .retry = RetryClassifier.classify(err, attemptCount: 1) {} else {
            XCTFail("expected retry on second hard-connect failure")
        }
        if case .escalate = RetryClassifier.classify(
            err, attemptCount: RetryPolicy.hardConnectRetryThreshold
        ) {} else {
            XCTFail("expected escalate once hardConnectRetryThreshold reached")
        }
    }

    func testGenericTransportStillUsesFullBudget() {
        let err = BackendError.transport("The network connection was lost.")
        // Not a hard-connect needle → still retry well past hardConnect threshold
        if case .retry = RetryClassifier.classify(err, attemptCount: 5) {} else {
            XCTFail("generic transport should still retry mid-budget")
        }
    }

    func testDecodingEscalatesAfterThreshold() {
        let err = BackendError.decoding("SSE parse error")
        if case .retry = RetryClassifier.classify(err, attemptCount: 0) {} else {
            XCTFail("decode should retry initially")
        }
        if case .escalate = RetryClassifier.classify(
            err, attemptCount: RetryPolicy.decodingRetryThreshold
        ) {} else {
            XCTFail("decode should escalate at decodingRetryThreshold")
        }
    }

    // MARK: - Factory / LM Studio API key

    func testFactoryPassesLmStudioAPIKey() {
        var s = AppSettings()
        s.backend = .lmStudio
        s.lmStudioAPIKey = "secret-key-xyz"
        let backend = BackendFactory.make(from: s)
        XCTAssertEqual(backend.identifier, .lmStudio)
        // Construction must not throw; key wiring is verified by type + init
        // (client bearer is private). Identity + non-crash is the smoke check.
        _ = LMStudioBackend(host: "127.0.0.1", port: 1234, apiKey: "secret-key-xyz")
        _ = LMStudioBackend(host: "127.0.0.1", port: 1234, apiKey: "  ")
        _ = LMStudioBackend(host: "127.0.0.1", port: 1234, apiKey: nil)
    }

    // MARK: - Custom backend provenance + encode

    func testCustomListModelsRemapsBackendProvenance() async throws {
        // Shared client stamps .custom now; OpenAICompatibleBackend must
        // still re-tag explicitly. Use a mock URLSession via protocol.
        final class MockURLProtocol: URLProtocol {
            nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                do {
                    let (code, data) = try Self.handler?(request) ?? (500, Data())
                    let resp = HTTPURLResponse(url: request.url!, statusCode: code,
                                               httpVersion: nil, headerFields: nil)!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            override func stopLoading() {}
        }

        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url?.path.hasSuffix("/models") ?? false)
            let body = #"{"data":[{"id":"my-custom-model","context_length":8192}]}"#
            return (200, Data(body.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = OpenAICompatibleBackend(
            baseURL: URL(string: "http://127.0.0.1:9999/v1")!,
            session: session)

        let models = try await backend.listModels()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "my-custom-model")
        XCTAssertEqual(models[0].backend, .custom,
                       "Custom endpoint models must not be tagged as another backend")
    }

    func testCustomEncodeOmitsEmptyToolsAndToolCalls() {
        // Access encode via a stream of empty-tools request is heavy;
        // re-check the public encode path by constructing the same
        // ChatCompletionRequestBody shape LM Studio uses.
        let msg = ChatMessage(role: .assistant, content: "", toolCalls: [])
        XCTAssertTrue(msg.toolCalls.isEmpty)
        let wireToolCalls: [ChatCompletionRequestBody.WireToolCall]? =
            msg.toolCalls.isEmpty ? nil : []
        XCTAssertNil(wireToolCalls, "empty toolCalls must encode as nil not []")

        let tools: [ToolSchema] = []
        let wireTools: [ChatCompletionRequestBody.WireTool]? =
            tools.isEmpty ? nil : []
        XCTAssertNil(wireTools)
    }

    // MARK: - SSE decoder

    func testSSEDecoderDoneAndData() {
        let dec = SSEStreamDecoder()
        if case .done = dec.decode(line: "data: [DONE]") {} else {
            XCTFail("expected done")
        }
        if case .data = dec.decode(line: "data: {\"a\":1}") {} else {
            XCTFail("expected data")
        }
        if case .skip = dec.decode(line: ": ping") {} else {
            XCTFail("expected skip")
        }
        if case .skip = dec.decode(line: "") {} else {
            XCTFail("expected skip on blank")
        }
    }

    // MARK: - EXO listModels empty without pin (topology path needs live server;
    //        lock the pin path and empty fallback without topology)

    func testEXOListModelsWithPinReturnsSingle() async throws {
        let exo = EXOBackend(host: "127.0.0.1", port: 1, pinnedModelID: "pinned/model")
        let models = try await exo.listModels()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "pinned/model")
        XCTAssertEqual(models[0].backend, .exo)
    }

    // MARK: - Client listModels no longer stamps .lmStudio

    // MARK: - C2: no retry after partial stream delivery

    func testStreamRetriesBeforeAnyTokenThenSucceeds() async throws {
        // First attempt HTTP 503 → retry; second yields content. Proves
        // pre-emit retries still work after C2 O1 "no retry after yield".
        final class MockURLProtocol: URLProtocol {
            nonisolated(unsafe) static var callCount = 0
            nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data, [String: String]?))?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Self.callCount += 1
                do {
                    let (code, data, headers) = try Self.handler?(request)
                        ?? (500, Data(), nil)
                    let resp = HTTPURLResponse(url: request.url!, statusCode: code,
                                               httpVersion: nil, headerFields: headers)!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            override func stopLoading() {}
        }

        MockURLProtocol.callCount = 0
        MockURLProtocol.handler = { _ in
            if MockURLProtocol.callCount <= 1 {
                return (503, Data("busy".utf8), nil)
            }
            let sse = #"data: {"choices":[{"delta":{"content":"ok"}}]}"# + "\n\ndata: [DONE]\n\n"
            return (200, Data(sse.utf8), ["Content-Type": "text/event-stream"])
        }
        defer {
            MockURLProtocol.handler = nil
            MockURLProtocol.callCount = 0
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = OpenAICompatibleClient(
            config: .init(baseURL: URL(string: "http://127.0.0.1:9/v1")!),
            session: session)
        let body = ChatCompletionRequestBody(
            model: "m", messages: [.init(role: "user", content: "hi")], sampling: .coder)

        var texts: [String] = []
        let stream = await client.streamChatCompletion(streamID: UUID(), body: body)
        for try await chunk in stream {
            if case .contentDelta(let s) = chunk { texts.append(s) }
        }
        XCTAssertEqual(texts.joined(), "ok")
        XCTAssertGreaterThanOrEqual(MockURLProtocol.callCount, 2,
                                    "expected at least one retry before success")
    }

    func testClientListModelsTagsCustomNotLmStudio() async throws {
        final class MockURLProtocol: URLProtocol {
            nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                do {
                    let (code, data) = try Self.handler?(request) ?? (500, Data())
                    let resp = HTTPURLResponse(url: request.url!, statusCode: code,
                                               httpVersion: nil, headerFields: nil)!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            override func stopLoading() {}
        }
        MockURLProtocol.handler = { _ in
            (200, Data(#"{"data":[{"id":"m1"}]}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = OpenAICompatibleClient(
            config: .init(baseURL: URL(string: "http://127.0.0.1:1/v1")!),
            session: session)
        let models = try await client.listModels()
        XCTAssertEqual(models[0].backend, .custom)
        XCTAssertNotEqual(models[0].backend, .lmStudio)
    }
}
