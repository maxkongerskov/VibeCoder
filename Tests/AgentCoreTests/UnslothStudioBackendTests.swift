import XCTest
@testable import AgentCore

/// Unsloth Studio: list models with `loaded` flag, load/unload native REST.
final class UnslothStudioBackendTests: XCTestCase {

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

    func testListModelsParsesLoadedFlagAndSkipsEmbeddings() async throws {
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            XCTAssertTrue((req.value(forHTTPHeaderField: "Authorization") ?? "")
                .hasPrefix("Bearer "))
            if path.hasSuffix("/v1/models") || path == "/v1/models" {
                let body = """
                {
                  "object": "list",
                  "data": [
                    {
                      "id": "unsloth/gemma-4-26B-A4B-it-GGUF",
                      "object": "model",
                      "owned_by": "unsloth-studio",
                      "quant": "BF16",
                      "context_length": 262144,
                      "loaded": true
                    },
                    {
                      "id": "Qwen/Qwen3-Embedding-0.6B-GGUF",
                      "object": "model",
                      "owned_by": "unsloth-studio",
                      "quant": "f16",
                      "loaded": false
                    },
                    {
                      "id": "org/other-chat",
                      "object": "model",
                      "loaded": false
                    }
                  ]
                }
                """
                return (200, Data(body.utf8))
            }
            return (404, Data())
        }

        let backend = UnslothStudioBackend(
            host: "127.0.0.1",
            port: 8888,
            apiKey: "sk-test",
            session: makeSession())
        let models = try await backend.listModels()
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].id, "unsloth/gemma-4-26B-A4B-it-GGUF")
        XCTAssertEqual(models[0].isLoaded, true)
        XCTAssertEqual(models[0].backend, .unslothStudio)
        XCTAssertTrue(models.contains { $0.id == "org/other-chat" && $0.isLoaded == false })
        XCTAssertFalse(models.contains { $0.id.contains("Embedding") })
    }

    func testLoadPostsModelPath() async throws {
        var sawLoad = false
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/v1/models") || path == "/v1/models" {
                // After load, report loaded.
                let loaded = sawLoad
                let body = """
                {
                  "object":"list",
                  "data":[{"id":"unsloth/gemma","object":"model","loaded":\(loaded)}]
                }
                """
                return (200, Data(body.utf8))
            }
            if path.hasSuffix("/v1/load") || path == "/v1/load" {
                sawLoad = true
                XCTAssertEqual(req.httpMethod, "POST")
                if let data = req.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    XCTAssertEqual(json["model_path"] as? String, "unsloth/gemma")
                }
                let body = #"{"status":"ok","model":"unsloth/gemma","display_name":"gemma"}"#
                return (200, Data(body.utf8))
            }
            return (404, Data())
        }

        let backend = UnslothStudioBackend(
            host: "127.0.0.1", port: 8888, apiKey: "sk-test", session: makeSession())
        try await backend.warmUp(model: ModelDescriptor(
            id: "unsloth/gemma",
            displayName: "gemma",
            backend: .unslothStudio,
            isLoaded: false))
        XCTAssertTrue(sawLoad)
    }

    func testUnloadPostsModelPath() async throws {
        var sawUnload = false
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/v1/unload") || path == "/v1/unload" {
                sawUnload = true
                XCTAssertEqual(req.httpMethod, "POST")
                if let data = req.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    XCTAssertEqual(json["model_path"] as? String, "unsloth/gemma")
                }
                return (200, Data(#"{"status":"ok","model":"unsloth/gemma"}"#.utf8))
            }
            return (404, Data())
        }

        let backend = UnslothStudioBackend(
            host: "127.0.0.1", port: 8888, apiKey: "sk-test", session: makeSession())
        try await backend.unload(model: ModelDescriptor(
            id: "unsloth/gemma",
            displayName: "gemma",
            backend: .unslothStudio,
            isLoaded: true))
        XCTAssertTrue(sawUnload)
    }

    func testBackendIdentifierAliases() {
        XCTAssertEqual(BackendIdentifier.migrating(fromRaw: "unsloth"), .unslothStudio)
        XCTAssertEqual(BackendIdentifier.migrating(fromRaw: "unsloth-studio"), .unslothStudio)
        XCTAssertEqual(BackendIdentifier.migrating(fromRaw: "unslothStudio"), .unslothStudio)
        XCTAssertTrue(BackendIdentifier.unslothStudio.supportsLoadUnload)
    }
}
