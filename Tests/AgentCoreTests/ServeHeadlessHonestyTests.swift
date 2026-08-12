//
//  ServeHeadlessHonestyTests.swift
//  PB7 — routing, tools policy, AgentOSServe echo vs backend configure.
//

import XCTest
@testable import AgentCore

final class ServeHeadlessHonestyTests: XCTestCase {

    // MARK: - Routing

    func testRouteModelsAndChatCompletions() {
        XCTAssertEqual(
            OpenAICompatServeRoute.resolve(method: "GET", path: "/v1/models"),
            .models)
        XCTAssertEqual(
            OpenAICompatServeRoute.resolve(method: "POST", path: "/v1/chat/completions"),
            .chatCompletions)
    }

    func testRouteTrailingSlashAndQuery() {
        XCTAssertEqual(
            OpenAICompatServeRoute.resolve(method: "GET", path: "/v1/models/"),
            .models)
        XCTAssertEqual(
            OpenAICompatServeRoute.resolve(method: "POST", path: "/v1/chat/completions?stream=true"),
            .chatCompletions)
    }

    func testRouteOptionsAndNotFound() {
        XCTAssertEqual(
            OpenAICompatServeRoute.resolve(method: "OPTIONS", path: "/v1/chat/completions"),
            .options)
        XCTAssertEqual(
            OpenAICompatServeRoute.resolve(method: "GET", path: "/v1/unknown"),
            .notFound)
        XCTAssertEqual(
            OpenAICompatServeRoute.resolve(method: "DELETE", path: "/v1/models"),
            .notFound)
    }

    // MARK: - Tools policy

    func testToolsPolicyDefaultProxyOnly() {
        XCTAssertEqual(ServeToolsPolicy.resolve(agentToolsEnabled: false), .proxyOnly)
        XCTAssertFalse(ServeToolsPolicy.proxyOnly.runsAgentLoop)
        let schemas = [
            ToolSchema(name: "read_file", description: "r",
                       parameters: .init(properties: [:], required: []))
        ]
        XCTAssertTrue(
            ServeToolsPolicy.tools(policy: .proxyOnly, registeredSchemas: schemas).isEmpty)
    }

    func testToolsPolicyOptInIsAgentLoopNotSchemasOnly() {
        XCTAssertEqual(ServeToolsPolicy.resolve(agentToolsEnabled: true), .agentLoop)
        XCTAssertTrue(ServeToolsPolicy.agentLoop.runsAgentLoop)
        let schemas = [
            ToolSchema(name: "read_file", description: "r",
                       parameters: .init(properties: [:], required: [])),
            ToolSchema(name: "run_shell", description: "s",
                       parameters: .init(properties: [:], required: [])),
        ]
        // Agent-loop mode does not put schemas on the *proxy* ChatRequest.
        XCTAssertTrue(
            ServeToolsPolicy.tools(policy: .agentLoop, registeredSchemas: schemas).isEmpty)
        // Explicit schemasOnly still attaches for legacy callers/tests.
        let attached = ServeToolsPolicy.tools(policy: .schemasOnly, registeredSchemas: schemas)
        XCTAssertEqual(attached.map(\.name).sorted(), ["read_file", "run_shell"])
    }

    func testLocalAPICompletionToolsDefaultEmpty() async {
        let tools = await LocalAPIServer.completionTools(agentToolsEnabled: false)
        XCTAssertTrue(tools.isEmpty, "Default LocalAPI must not inject AgentCore tools")
    }

    func testLocalAPICompletionToolsOptInEmptyOnProxyHelper() async {
        // Opt-in maps to agentLoop — tools load inside AgentLoop, not via
        // the proxy completionTools helper.
        await ToolRegistry.shared.registerBuiltins()
        let tools = await LocalAPIServer.completionTools(agentToolsEnabled: true)
        XCTAssertTrue(tools.isEmpty, "Agent-loop mode uses ToolRegistry inside AgentLoop")
    }

    func testAgentLoopMaxIterationsIsHardCapped() {
        XCTAssertEqual(LocalAPIServer.agentLoopMaxIterations, 8)
        XCTAssertLessThanOrEqual(LocalAPIServer.agentLoopMaxIterations, 16)
    }

    // MARK: - Message parse / echo helpers

    func testExtractLastUserText() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "m",
            "messages": [
                ["role": "system", "content": "sys"],
                ["role": "user", "content": "hello world"],
            ],
        ])
        XCTAssertEqual(AgentOSServeServer.extractLastUserText(from: body), "hello world")
    }

    func testParseContentPartsArray() throws {
        let json: [String: Any] = [
            "messages": [
                ["role": "user", "content": [
                    ["type": "text", "text": "part-a"],
                    ["type": "text", "text": "part-b"],
                ]],
            ],
        ]
        let msgs = AgentOSServeServer.parseMessages(from: json)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].content, "part-apart-b")
    }

    // MARK: - Serve configure honesty

    func testServeDefaultsToEchoWithoutBackend() async {
        let serve = AgentOSServeServer()
        await serve.configure(backend: nil, agentToolsEnabled: false)
        let configured = await serve.isBackendConfigured()
        let toolsOn = await serve.isAgentToolsEnabled()
        XCTAssertFalse(configured)
        XCTAssertFalse(toolsOn)
        XCTAssertEqual(AgentOSServeServer.echoModelID, "agentos-echo")
        XCTAssertEqual(AgentOSServeServer.defaultModelID, AgentOSServeServer.echoModelID)
    }

    func testServeConfigureBackendAndAgentToolsFlag() async {
        let backend = ScriptedServeBackend(chunks: [.contentDelta("hi"), .done(finishReason: "stop")])
        let serve = AgentOSServeServer()
        await serve.configure(backend: backend, agentToolsEnabled: true)
        let configured = await serve.isBackendConfigured()
        let toolsOn = await serve.isAgentToolsEnabled()
        XCTAssertTrue(configured)
        XCTAssertTrue(toolsOn)
    }

    func testLocalAPIConfigureDefaultAgentToolsOff() async {
        let backend = ScriptedServeBackend(chunks: [])
        let server = LocalAPIServer()
        await server.configure(backend: backend, settings: AppSettings())
        let on = await server.isAgentToolsEnabled()
        XCTAssertFalse(on)
        await server.setAgentToolsEnabled(true)
        let on2 = await server.isAgentToolsEnabled()
        XCTAssertTrue(on2)
    }
}

// MARK: - Minimal scripted backend

private final class ScriptedServeBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let chunks: [ChatChunk]
    init(chunks: [ChatChunk]) { self.chunks = chunks }
    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "scripted", displayName: "scripted", backend: .lmStudio)]
    }
    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { cont in
            for c in chunks { cont.yield(c) }
            cont.finish()
        }
    }
    func cancel(streamID: UUID) async {}
}
