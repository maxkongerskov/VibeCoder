import XCTest
@testable import AgentCore

final class OpenAICompatibleClientTests: XCTestCase {

    private final class MockURLProtocol: URLProtocol {
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

    private func makeClient() -> OpenAICompatibleClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let base = URL(string: "http://127.0.0.1:8080/v1")!
        return OpenAICompatibleClient(config: .init(baseURL: base), session: session)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testListModelsParsesContextLengthFromShippedClient() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url?.path.hasSuffix("/models") ?? false)
            let body = """
            {"data":[{"id":"GLM-5.2-mxfp4","context_length":256000}]}
            """
            return (200, Data(body.utf8), nil)
        }

        let client = makeClient()
        let models = try await client.listModels()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "GLM-5.2-mxfp4")
        XCTAssertEqual(models[0].contextLength, 256_000)
        XCTAssertEqual(
            ContextBudget.resolve(storedContextLength: 32_768, model: models[0]),
            179_200)
    }

    func testStreamChatCompletionEmitsToolCallDeltasFromShippedClient() async throws {
        let chunk1 = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"path\":"}}]}}]}"#
        let chunk2 = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\".\"}"}}]}}]}"#
        let chunk3 = #"{"choices":[{"finish_reason":"tool_calls"}]}"#
        let sse = "data: \(chunk1)\n\ndata: \(chunk2)\n\ndata: \(chunk3)\n\ndata: [DONE]\n\n"

        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url?.path.hasSuffix("/chat/completions") ?? false)
            return (200, Data(sse.utf8), ["Content-Type": "text/event-stream"])
        }

        let client = makeClient()
        let body = ChatCompletionRequestBody(
            model: "test",
            messages: [.init(role: "user", content: "hi")],
            sampling: .coder)

        var chunks: [ChatChunk] = []
        let stream = await client.streamChatCompletion(streamID: UUID(), body: body)
        for try await chunk in stream {
            chunks.append(chunk)
        }

        let deltas = chunks.compactMap { chunk -> (Int, String?, String?, String?)? in
            if case .toolCallDelta(let index, let id, let name, let args) = chunk {
                return (index, id, name, args)
            }
            return nil
        }
        XCTAssertGreaterThanOrEqual(deltas.count, 2, "Expected tool call deltas, got: \(chunks)")
        XCTAssertEqual(deltas[0].1, "call_1")
        XCTAssertEqual(deltas[0].2, "read_file")
        XCTAssertEqual(deltas[0].3, "{\"path\":")
        XCTAssertEqual(deltas[1].3, "\".\"}")
        let finishReasons = chunks.compactMap { chunk -> String? in
            if case .done(let r) = chunk { return r }
            return nil
        }
        XCTAssertTrue(finishReasons.contains("tool_calls") || finishReasons.contains("stop"),
                        "Expected a terminal done chunk, got: \(finishReasons)")
    }

    func testCancelStopsInflightStream() async throws {
        let chunk = #"{"choices":[{"delta":{"content":"partial"}}]}"#
        let sse = "data: \(chunk)\n\n"

        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { _ in
            gate.wait()
            return (200, Data(sse.utf8), ["Content-Type": "text/event-stream"])
        }

        let client = makeClient()
        let streamID = UUID()
        let body = ChatCompletionRequestBody(
            model: "test",
            messages: [.init(role: "user", content: "hi")],
            sampling: .coder)

        let stream = await client.streamChatCompletion(streamID: streamID, body: body)
        let consume = Task {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await client.cancel(streamID: streamID)
        gate.signal()
        consume.cancel()
        _ = try? await consume.value
    }

    // MARK: - stream_options.include_usage (context-meter calibration)

    private func encodedBodyJSON(_ body: ChatCompletionRequestBody) throws -> [String: Any] {
        let data = try JSONEncoder().encode(body)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func testRequestBodyRequestsUsageWhenStreaming() throws {
        let body = ChatCompletionRequestBody(
            model: "test",
            messages: [.init(role: "user", content: "hi")],
            sampling: .coder,
            stream: true)
        let json = try encodedBodyJSON(body)
        XCTAssertEqual(json["stream"] as? Bool, true)
        let opts = json["stream_options"] as? [String: Any]
        XCTAssertEqual(opts?["include_usage"] as? Bool, true,
                       "streaming requests must ask the server for usage stats")
    }

    func testRequestBodyOmitsStreamOptionsWhenNotStreaming() throws {
        let body = ChatCompletionRequestBody(
            model: "test",
            messages: [.init(role: "user", content: "hi")],
            sampling: .coder,
            stream: false)
        let json = try encodedBodyJSON(body)
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertNil(json["stream_options"],
                     "stream_options is only valid with stream:true; must be omitted otherwise")
    }
}