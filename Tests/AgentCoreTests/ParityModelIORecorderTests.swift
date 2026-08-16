//
//  ParityModelIORecorderTests.swift
//  Opt-in model-I/O JSONL recorder (parity §11).
//

import XCTest
@testable import AgentCore

final class ParityModelIORecorderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ModelIORecorder.isEnabled = false
        ModelIORecorder.directoryOverride = tempDir
    }

    override func tearDownWithError() throws {
        ModelIORecorder.isEnabled = false
        ModelIORecorder.directoryOverride = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    func testDefaultIsDisabled() {
        XCTAssertFalse(ModelIORecorder.enabledDefault)
        XCTAssertFalse(ModelIORecorder.isEnabled)
    }

    func testDisabledWritesNothing() {
        ModelIORecorder.isEnabled = false
        let session = "sess-disabled"
        ModelIORecorder.record(
            sessionId: session,
            request: ModelIORecord.Request(
                modelId: "m",
                messageCount: 1,
                toolNames: [],
                systemPromptChars: 0
            ),
            response: nil
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ModelIORecorder.fileURL(sessionId: session).path),
            "disabled recorder must not create a JSONL file"
        )
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? [], [])
    }

    func testEnabledRecordsJSONLRoundTrip() throws {
        ModelIORecorder.isEnabled = true
        let session = "sess-abc"
        let request = ModelIORecord.Request(
            modelId: "glm-4",
            messageCount: 3,
            toolNames: ["read_file", "run_shell"],
            systemPromptChars: 42,
            headers: ["Content-Type": "application/json"]
        )
        let response = ModelIORecord.Response(
            finishReason: "stop",
            usage: .init(promptTokens: 10, completionTokens: 20),
            responseText: "hello",
            error: nil
        )

        ModelIORecorder.record(sessionId: session, request: request, response: response)
        ModelIORecorder.record(
            sessionId: session,
            request: request,
            response: ModelIORecord.Response(finishReason: "tool_calls", error: "boom")
        )

        let url = ModelIORecorder.fileURL(sessionId: session)
        XCTAssertEqual(url.lastPathComponent, "model-io-sess-abc.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)

        let decoder = JSONDecoder()
        let first = try decoder.decode(ModelIORecord.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first.sessionId, session)
        XCTAssertFalse(first.timestamp.isEmpty)
        XCTAssertEqual(first.request.modelId, "glm-4")
        XCTAssertEqual(first.request.messageCount, 3)
        XCTAssertEqual(first.request.toolNames, ["read_file", "run_shell"])
        XCTAssertEqual(first.request.systemPromptChars, 42)
        XCTAssertEqual(first.request.headers?["Content-Type"], "application/json")
        XCTAssertEqual(first.response?.finishReason, "stop")
        XCTAssertEqual(first.response?.usage?.promptTokens, 10)
        XCTAssertEqual(first.response?.usage?.completionTokens, 20)
        XCTAssertEqual(first.response?.usage?.totalTokens, 30)
        XCTAssertEqual(first.response?.responseText, "hello")
        XCTAssertNil(first.response?.error)

        let second = try decoder.decode(ModelIORecord.self, from: Data(lines[1].utf8))
        XCTAssertEqual(second.response?.finishReason, "tool_calls")
        XCTAssertEqual(second.response?.error, "boom")
    }

    func testKeyRedactionHelper() {
        let redacted = ModelIORecorder.redactHeaders([
            "Authorization": "Bearer sk-live-secret",
            "authorization": "bearer another-secret",
            "X-Api-Key": "abc123",
            "api_key": "from-underscore",
            "x-openai-api-key": "openai-secret",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "X-Custom": "sk-embedded",
        ])

        XCTAssertEqual(redacted["Authorization"], "Bearer [REDACTED]")
        XCTAssertEqual(redacted["authorization"], "Bearer [REDACTED]")
        XCTAssertEqual(redacted["X-Api-Key"], "[REDACTED]")
        XCTAssertEqual(redacted["api_key"], "[REDACTED]")
        XCTAssertEqual(redacted["x-openai-api-key"], "[REDACTED]")
        XCTAssertEqual(redacted["Content-Type"], "application/json")
        XCTAssertEqual(redacted["Accept"], "text/event-stream")
        XCTAssertEqual(redacted["X-Custom"], "[REDACTED]")

        XCTAssertTrue(ModelIORecorder.isSensitiveHeader("Proxy-Authorization"))
        XCTAssertTrue(ModelIORecorder.looksLikeSecret("Bearer xyz"))
        XCTAssertFalse(ModelIORecorder.looksLikeSecret("hello"))
        XCTAssertFalse(ModelIORecorder.isSensitiveHeader("Content-Type"))
    }

    func testRecordRedactsAuthorizationInJSONL() throws {
        ModelIORecorder.isEnabled = true
        let secret = "sk-super-secret-do-not-store"
        ModelIORecorder.record(
            sessionId: "sess-auth",
            request: ModelIORecord.Request(
                modelId: "m",
                messageCount: 1,
                toolNames: [],
                systemPromptChars: 0,
                headers: ["Authorization": "Bearer \(secret)"]
            ),
            response: nil
        )

        let raw = try String(contentsOf: ModelIORecorder.fileURL(sessionId: "sess-auth"), encoding: .utf8)
        XCTAssertFalse(raw.contains(secret), "JSONL must not contain the raw API key")
        XCTAssertFalse(raw.contains("sk-super"), "JSONL must not contain a key prefix")
        let record = try JSONDecoder().decode(
            ModelIORecord.self,
            from: Data(raw.trimmingCharacters(in: .newlines).utf8)
        )
        XCTAssertEqual(record.request.headers?["Authorization"], "Bearer [REDACTED]")
    }

    func testResponseTextCappedAt8k() throws {
        ModelIORecorder.isEnabled = true
        let long = String(repeating: "x", count: 9_000)
        ModelIORecorder.record(
            sessionId: "sess-cap",
            request: ModelIORecord.Request(
                modelId: "m",
                messageCount: 0,
                toolNames: [],
                systemPromptChars: 0
            ),
            response: ModelIORecord.Response(responseText: long)
        )
        let raw = try String(contentsOf: ModelIORecorder.fileURL(sessionId: "sess-cap"), encoding: .utf8)
        let record = try JSONDecoder().decode(
            ModelIORecord.self,
            from: Data(raw.trimmingCharacters(in: .newlines).utf8)
        )
        XCTAssertEqual(record.response?.responseText?.count, ModelIORecorder.responseTextLimit)
        XCTAssertEqual(ModelIORecorder.truncatedResponseText(long)?.count, 8_000)
    }

    func testRequestMappingFromChatRequestAndBody() {
        let system = "You are a coding agent."
        let chat = ChatRequest(
            model: ModelDescriptor(id: "local-glm", displayName: "GLM", backend: .custom),
            messages: [
                ChatMessage(role: .system, content: system),
                ChatMessage(role: .user, content: "hi"),
            ],
            tools: [
                ToolSchema(
                    name: "read_file",
                    description: "r",
                    parameters: .init(properties: [:], required: [])
                ),
            ],
            sampling: .coder
        )
        let fromChat = ModelIORecord.Request(chatRequest: chat)
        XCTAssertEqual(fromChat.modelId, "local-glm")
        XCTAssertEqual(fromChat.messageCount, 2)
        XCTAssertEqual(fromChat.toolNames, ["read_file"])
        XCTAssertEqual(fromChat.systemPromptChars, system.count)

        let body = ChatCompletionRequestBody(
            model: chat.model.id,
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
        let fromBody = ModelIORecord.Request(body: body)
        XCTAssertEqual(fromBody, fromChat)
    }

    func testSessionIdPathComponentsAreSanitized() {
        XCTAssertEqual(ModelIORecorder.sanitizedSessionId("a/b\\c"), "a-b-c")
        let url = ModelIORecorder.fileURL(sessionId: "a/b")
        XCTAssertEqual(url.lastPathComponent, "model-io-a-b.jsonl")
    }
}
