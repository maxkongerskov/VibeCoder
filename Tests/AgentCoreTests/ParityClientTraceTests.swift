//
//  ParityClientTraceTests.swift
//  Wave-2 client hook: ModelIORecorder after each settled HTTP attempt.
//

import XCTest
@testable import AgentCore

final class ParityClientTraceTests: XCTestCase {

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

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-trace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ModelIORecorder.isEnabled = false
        ModelIORecorder.directoryOverride = tempDir
        MockURLProtocol.handler = nil
    }

    override func tearDownWithError() throws {
        ModelIORecorder.isEnabled = false
        ModelIORecorder.directoryOverride = nil
        MockURLProtocol.handler = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    func testDefaultDisabledAndDirectRecordWritesFile() throws {
        XCTAssertFalse(ModelIORecorder.enabledDefault)
        XCTAssertFalse(ModelIORecorder.isEnabled)

        let system = "You are a coding agent."
        let body = ChatCompletionRequestBody(
            model: "local-glm",
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: "hi"),
            ],
            tools: [
                .init(function: .init(
                    name: "read_file",
                    description: "r",
                    parameters: .init(properties: [:], required: [])
                )),
            ],
            sampling: .coder
        )

        ModelIORecorder.record(
            sessionId: "sess-direct",
            request: ModelIORecord.Request(body: body),
            response: ModelIORecord.Response(finishReason: "stop", responseText: "ok")
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ModelIORecorder.fileURL(sessionId: "sess-direct").path),
            "disabled recorder must not create a JSONL file"
        )

        ModelIORecorder.isEnabled = true
        ModelIORecorder.record(
            sessionId: "sess-direct",
            request: ModelIORecord.Request(body: body),
            response: ModelIORecord.Response(finishReason: "stop", responseText: "ok")
        )

        let url = ModelIORecorder.fileURL(sessionId: "sess-direct")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let record = try decodeFirstRecord(at: url)
        XCTAssertEqual(record.request.modelId, "local-glm")
        XCTAssertEqual(record.request.messageCount, 2)
        XCTAssertEqual(record.request.toolNames, ["read_file"])
        XCTAssertEqual(record.request.systemPromptChars, system.count)
        XCTAssertEqual(record.response?.finishReason, "stop")
        XCTAssertEqual(record.response?.responseText, "ok")
    }

    func testClientStreamRecordsWhenEnabled() async throws {
        ModelIORecorder.isEnabled = true
        let secret = "sk-client-trace-secret-do-not-store"
        let streamID = UUID()
        let system = "sys-prompt"
        let body = ChatCompletionRequestBody(
            model: "trace-model",
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: "hi"),
            ],
            sampling: .coder
        )

        let chunk1 = #"{"choices":[{"delta":{"content":"hello"}}]}"#
        let chunk2 = #"{"choices":[{"finish_reason":"stop"}]}"#
        let chunk3 = #"{"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":2}}"#
        let sse = "data: \(chunk1)\n\ndata: \(chunk2)\n\ndata: \(chunk3)\n\ndata: [DONE]\n\n"
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url?.path.hasSuffix("/chat/completions") ?? false)
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")
            return (200, Data(sse.utf8), ["Content-Type": "text/event-stream"])
        }

        let client = makeClient(bearerToken: secret)
        var chunks: [ChatChunk] = []
        let stream = await client.streamChatCompletion(streamID: streamID, body: body)
        for try await chunk in stream {
            chunks.append(chunk)
        }
        XCTAssertFalse(chunks.isEmpty)

        let url = ModelIORecorder.fileURL(sessionId: streamID.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "client path must invoke ModelIORecorder.record")
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains(secret), "JSONL must not contain the raw bearer token")

        let record = try decodeFirstRecord(at: url)
        XCTAssertEqual(record.sessionId, streamID.uuidString)
        XCTAssertEqual(record.request.modelId, "trace-model")
        XCTAssertEqual(record.request.messageCount, 2)
        XCTAssertEqual(record.request.systemPromptChars, system.count)
        XCTAssertEqual(record.request.headers?["Authorization"], "Bearer [REDACTED]")
        XCTAssertEqual(record.response?.finishReason, "stop")
        XCTAssertEqual(record.response?.responseText, "hello")
        XCTAssertEqual(record.response?.usage?.promptTokens, 11)
        XCTAssertEqual(record.response?.usage?.completionTokens, 2)
        XCTAssertNil(record.response?.error)
    }

    func testClientStreamWritesNothingWhenDisabled() async throws {
        ModelIORecorder.isEnabled = false
        let streamID = UUID()
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\ndata: [DONE]\n\n"
        MockURLProtocol.handler = { _ in
            (200, Data(sse.utf8), ["Content-Type": "text/event-stream"])
        }

        let client = makeClient()
        let body = ChatCompletionRequestBody(
            model: "m",
            messages: [.init(role: "user", content: "hi")],
            sampling: .coder
        )
        let stream = await client.streamChatCompletion(streamID: streamID, body: body)
        for try await _ in stream {}

        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? [],
            [],
            "disabled recorder must not write from the client path"
        )
    }

    func testClientRecordsHTTPErrorWithoutThrowingFromRecord() async throws {
        ModelIORecorder.isEnabled = true
        let streamID = UUID()
        MockURLProtocol.handler = { _ in
            (400, Data("bad request".utf8), ["Content-Type": "application/json"])
        }

        let client = makeClient()
        let body = ChatCompletionRequestBody(
            model: "m",
            messages: [.init(role: "user", content: "hi")],
            sampling: .coder
        )
        let stream = await client.streamChatCompletion(streamID: streamID, body: body)
        do {
            for try await _ in stream {
                XCTFail("400 must fail the stream")
            }
            XCTFail("expected stream to throw")
        } catch {
            // expected — record must not replace this error
        }

        let url = ModelIORecorder.fileURL(sessionId: streamID.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let record = try decodeFirstRecord(at: url)
        XCTAssertEqual(record.request.modelId, "m")
        XCTAssertNotNil(record.response?.error)
        XCTAssertTrue(record.response?.error?.contains("400") == true)
        XCTAssertTrue(record.response?.error?.contains("bad request") == true)
    }

    // MARK: - Helpers

    private func makeClient(bearerToken: String? = nil) -> OpenAICompatibleClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let base = URL(string: "http://127.0.0.1:8080/v1")!
        return OpenAICompatibleClient(
            config: .init(baseURL: base, bearerToken: bearerToken),
            session: session
        )
    }

    private func decodeFirstRecord(at url: URL) throws -> ModelIORecord {
        let text = try String(contentsOf: url, encoding: .utf8)
        let line = text.split(separator: "\n", omittingEmptySubsequences: true)[0]
        return try JSONDecoder().decode(ModelIORecord.self, from: Data(line.utf8))
    }
}
