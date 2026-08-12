import XCTest
@testable import AgentCore

/// LM Studio model listing: prefer native `/api/v1/models` (all downloaded
/// LLMs) over OpenAI-compat `/v1/models` which is loaded-only when JIT is off.
final class LMStudioBackendTests: XCTestCase {

    // MARK: - Mock URL protocol

    final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            do {
                let (code, data) = try Self.handler?(request) ?? (500, Data())
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: nil)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
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

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Native v1 list

    func testListModelsUsesNativeV1AndSkipsEmbeddings() async throws {
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/api/v1/models") {
                let body = """
                {
                  "models": [
                    {
                      "type": "llm",
                      "key": "gemma-4-31b-it",
                      "display_name": "Gemma 4 31B Instruct",
                      "max_context_length": 262144,
                      "params_string": "31B",
                      "loaded_instances": [],
                      "capabilities": { "trained_for_tool_use": true, "vision": true }
                    },
                    {
                      "type": "embedding",
                      "key": "text-embedding-nomic",
                      "display_name": "Nomic Embed",
                      "max_context_length": 2048,
                      "loaded_instances": []
                    },
                    {
                      "type": "llm",
                      "key": "glm-5.2-fp8",
                      "display_name": "GLM 5.2 Fp8",
                      "max_context_length": 1048576,
                      "loaded_instances": [{ "id": "inst-1" }],
                      "capabilities": { "trained_for_tool_use": true }
                    }
                  ]
                }
                """
                return (200, Data(body.utf8))
            }
            // Should not need OpenAI fallback when native succeeds.
            XCTFail("unexpected path \(path)")
            return (404, Data())
        }

        let backend = LMStudioBackend(
            host: "127.0.0.1",
            port: 1234,
            session: makeSession())
        let models = try await backend.listModels()

        XCTAssertEqual(models.count, 2, "embeddings must be filtered out")
        XCTAssertEqual(models.map(\.backend), [.lmStudio, .lmStudio])
        // Loaded model first.
        XCTAssertEqual(models[0].id, "glm-5.2-fp8")
        XCTAssertEqual(models[0].displayName, "GLM 5.2 Fp8")
        XCTAssertEqual(models[1].id, "gemma-4-31b-it")
        XCTAssertEqual(models[1].displayName, "Gemma 4 31B Instruct")
        XCTAssertEqual(models[1].parameterCountB, 31)
        XCTAssertTrue(models[0].supportsTools)
    }

    func testListModelsFallsBackToV0LoadedWhenNativeMissing() async throws {
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/api/v1/models") {
                return (404, Data(#"{"error":"not found"}"#.utf8))
            }
            if path.hasSuffix("/api/v0/models") {
                let body = """
                {
                  "object": "list",
                  "data": [
                    { "id": "only-loaded", "state": "loaded", "max_context_length": 8192, "type": "llm" },
                    { "id": "not-loaded", "state": "not-loaded", "type": "llm" }
                  ]
                }
                """
                return (200, Data(body.utf8))
            }
            XCTFail("unexpected path \(path)")
            return (500, Data())
        }

        let backend = LMStudioBackend(
            host: "127.0.0.1",
            port: 1234,
            session: makeSession())
        let models = try await backend.listModels()
        XCTAssertEqual(models.map(\.id), ["only-loaded"])
        XCTAssertEqual(models[0].backend, .lmStudio)
    }

    func testListModelsFallsBackToOpenAIV1WhenNativeAndV0Empty() async throws {
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/api/v1/models") {
                return (200, Data(#"{"models":[]}"#.utf8))
            }
            if path.hasSuffix("/api/v0/models") {
                return (200, Data(#"{"object":"list","data":[]}"#.utf8))
            }
            if path.hasSuffix("/models") || path.hasSuffix("/v1/models") {
                let body = #"{"data":[{"id":"openai-compat-model","context_length":4096}]}"#
                return (200, Data(body.utf8))
            }
            XCTFail("unexpected path \(path)")
            return (500, Data())
        }

        let backend = LMStudioBackend(
            host: "127.0.0.1",
            port: 1234,
            session: makeSession())
        let models = try await backend.listModels()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "openai-compat-model")
        XCTAssertEqual(models[0].backend, .lmStudio)
    }

    func testWarmUpSkipsLoadWhenAlreadyLoaded() async throws {
        var loadCalled = false
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/api/v1/models") && req.httpMethod != "POST" {
                let body = """
                {
                  "models": [
                    {
                      "type": "llm",
                      "key": "gemma-4-31b-it",
                      "display_name": "Gemma",
                      "loaded_instances": [{ "id": "x" }]
                    }
                  ]
                }
                """
                return (200, Data(body.utf8))
            }
            if path.hasSuffix("/api/v1/models/load") {
                loadCalled = true
                return (200, Data(#"{"status":"loaded"}"#.utf8))
            }
            return (404, Data())
        }

        let backend = LMStudioBackend(
            host: "127.0.0.1",
            port: 1234,
            session: makeSession())
        try await backend.warmUp(model: ModelDescriptor(
            id: "gemma-4-31b-it",
            displayName: "Gemma",
            backend: .lmStudio,
            supportsTools: true))
        XCTAssertFalse(loadCalled, "must not POST load when already loaded")
    }

    func testWarmUpPostsLoadWhenUnloaded() async throws {
        final class Capture: @unchecked Sendable {
            var loadBody: Data?
            var loadPath: String?
        }
        let capture = Capture()
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            if path.hasSuffix("/api/v1/models") && method != "POST" {
                let body = """
                {
                  "models": [
                    {
                      "type": "llm",
                      "key": "gemma-4-31b-it",
                      "display_name": "Gemma",
                      "loaded_instances": []
                    }
                  ]
                }
                """
                return (200, Data(body.utf8))
            }
            if path.contains("models/load") || method == "POST" {
                capture.loadPath = path
                if let data = req.httpBody {
                    capture.loadBody = data
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
                    capture.loadBody = data
                }
                return (200, Data(#"{"status":"loaded","instance_id":"gemma-4-31b-it"}"#.utf8))
            }
            return (404, Data("not \(path)".utf8))
        }

        let backend = LMStudioBackend(
            host: "127.0.0.1",
            port: 1234,
            session: makeSession())
        try await backend.warmUp(model: ModelDescriptor(
            id: "gemma-4-31b-it",
            displayName: "Gemma",
            backend: .lmStudio,
            supportsTools: true,
            contextLength: 8192))

        XCTAssertEqual(capture.loadPath, "/api/v1/models/load")
        let body = try XCTUnwrap(capture.loadBody, "load POST body missing")
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "gemma-4-31b-it")
        // JSONSerialization may decode numbers as NSNumber/Int64 — accept Int-ish.
        XCTAssertEqual((json?["context_length"] as? NSNumber)?.intValue, 8192)
    }
}
