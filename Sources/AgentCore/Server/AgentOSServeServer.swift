//
//  AgentOSServeServer.swift
//
//  Headless OpenAI-compatible HTTP server for automation / `serve` paths.
//
//  Modes (PB7 honesty):
//    • **Backend** — when `configure(backend:)` is given a real
//      `InferenceBackend`, `/v1/models` and `/v1/chat/completions` proxy
//      that backend (tools empty unless `agentToolsEnabled` is true).
//    • **Echo** — when no backend is configured, responses are an
//      intentional stub (model id `agentos-echo`) so callers never
//      confuse a loopback echo with a live model.
//
//  This is **not** the full in-app agent loop (no multi-step tool
//  execute → re-prompt). See LocalAPIServer + ARCHITECTURE §5.7 / §10.1.
//

import Foundation
import Network

// MARK: - Shared route resolver (unit-tested)

/// OpenAI-compat path routing shared by LocalAPIServer + AgentOSServeServer.
public enum OpenAICompatServeRoute: Equatable, Sendable {
    case models
    case chatCompletions
    case options
    case notFound

    /// Pure routing — no I/O. Trailing slash normalized.
    public static func resolve(method: String, path: String) -> OpenAICompatServeRoute {
        let m = method.uppercased()
        var p = path
        if let q = p.firstIndex(of: "?") {
            p = String(p[..<q])
        }
        if p.hasSuffix("/"), p.count > 1 {
            p = String(p.dropLast())
        }
        if m == "OPTIONS" { return .options }
        switch (m, p) {
        case ("GET", "/v1/models"): return .models
        case ("POST", "/v1/chat/completions"): return .chatCompletions
        default: return .notFound
        }
    }
}

/// How Local API / serve handle tools on `/v1/chat/completions` (PB7 → D1).
public enum ServeToolsPolicy: Equatable, Sendable {
    /// Default for Xcode / Local API: no AgentCore tools on the wire.
    case proxyOnly
    /// Legacy PB7 mode: attach ToolRegistry **schemas** only (no execute).
    /// Kept for explicit tests / intermediate clients — not the default
    /// mapping of the Settings opt-in (that is now `.agentLoop`).
    case schemasOnly
    /// Opt-in multi-step agent loop: model → tools → model (AgentLoop),
    /// bounded iterations. Default Settings mapping when agent tools On.
    case agentLoop

    /// Map the Settings / configure flag. **true → agentLoop** (D1);
    /// **false → proxyOnly**. Schemas-only is no longer selected by this
    /// flag — use `.schemasOnly` explicitly if a caller needs it.
    public static func resolve(agentToolsEnabled: Bool) -> ServeToolsPolicy {
        agentToolsEnabled ? .agentLoop : .proxyOnly
    }

    /// Schemas placed on a **proxy** ChatRequest. Agent-loop mode returns
    /// `[]` here — tools are loaded inside AgentLoop from ToolRegistry.
    public static func tools(
        policy: ServeToolsPolicy,
        registeredSchemas: [ToolSchema]
    ) -> [ToolSchema] {
        switch policy {
        case .proxyOnly, .agentLoop: return []
        case .schemasOnly: return registeredSchemas
        }
    }

    /// Whether completions should run AgentLoop (tool execute + re-prompt).
    public var runsAgentLoop: Bool {
        if case .agentLoop = self { return true }
        return false
    }
}

// MARK: - Server

public actor AgentOSServeServer {

    /// Explicit echo/stub model id when no backend is configured.
    public static let echoModelID = "agentos-echo"
    /// Legacy alias (older docs / tests).
    public static let defaultModelID = echoModelID

    private var listener: NWListener?
    private var port: Int = 11435
    private var backend: (any InferenceBackend)?
    private var settings: AppSettings = AppSettings()
    /// Opt-in: attach ToolRegistry schemas on chat completions. Default **off**.
    private var agentToolsEnabled: Bool = false

    public init() {}

    /// Wire a real backend for headless automation. Pass `backend: nil` for
    /// intentional echo stub mode. `agentToolsEnabled` defaults to **false**.
    public func configure(
        backend: (any InferenceBackend)?,
        settings: AppSettings = AppSettings(),
        agentToolsEnabled: Bool = false
    ) {
        self.backend = backend
        self.settings = settings
        self.agentToolsEnabled = agentToolsEnabled
    }

    public func isBackendConfigured() -> Bool { backend != nil }
    public func isAgentToolsEnabled() -> Bool { agentToolsEnabled }

    public func start(port: Int) throws {
        listener?.cancel()
        self.port = port
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard port > 0, port <= 65_535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ServeError.invalidPort(port)
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        let newListener = try NWListener(using: params)
        newListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection: connection) }
        }
        newListener.start(queue: .global(qos: .userInitiated))
        listener = newListener
        let mode = backend == nil ? "echo-stub" : (agentToolsEnabled ? "backend+schemas" : "backend-proxy")
        Diagnostics.info("AgentOSServe ready on :\(port) mode=\(mode)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    public func currentPort() -> Int { port }

    public enum ServeError: Error, LocalizedError {
        case invalidPort(Int)
        public var errorDescription: String? {
            switch self {
            case .invalidPort(let p): return "Invalid port: \(p)"
            }
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        Task { await serve(connection: connection) }
    }

    private func serve(connection: NWConnection) async {
        defer { connection.cancel() }
        guard let parsed = await Self.parseRequest(connection: connection) else { return }
        let (method, path, body) = parsed

        switch OpenAICompatServeRoute.resolve(method: method, path: path) {
        case .options:
            await Self.write(connection,
                             "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        case .models:
            await respondModels(connection: connection)
        case .chatCompletions:
            await respondCompletion(body: body, connection: connection)
        case .notFound:
            await Self.writeJSON(connection,
                                 body: #"{"error":{"message":"not found","type":"not_found"}}"#,
                                 status: 404)
        }
    }

    private func respondModels(connection: NWConnection) async {
        if let backend {
            do {
                let models = try await backend.listModels()
                let items: [[String: Any]] = models.map {
                    ["id": $0.id, "object": "model", "created": 1_700_000_000, "owned_by": "agentos"]
                }
                let payload: [String: Any] = ["object": "list", "data": items]
                await Self.writeJSON(connection, body: Self.jsonString(payload), status: 200)
            } catch {
                await Self.writeJSON(connection,
                                     body: Self.errorBody(error.localizedDescription, type: "backend_error"),
                                     status: 502)
            }
            return
        }
        // Honest echo catalog — not a real model.
        let json = """
        {"object":"list","data":[{"id":"\(Self.echoModelID)","object":"model","created":1700000000,"owned_by":"agentos-echo-stub"}]}
        """
        await Self.writeJSON(connection, body: json, status: 200)
    }

    private func respondCompletion(body: Data, connection: NWConnection) async {
        if let backend {
            await respondBackendCompletion(body: body, backend: backend, connection: connection)
            return
        }
        await respondEchoCompletion(body: body, connection: connection)
    }

    private func respondEchoCompletion(body: Data, connection: NWConnection) async {
        let userText = Self.extractLastUserText(from: body) ?? ""
        let reply = userText.isEmpty
            ? "\(AppBranding.displayName) serve echo-stub (no backend configured) — send a user message or configure(backend:)."
            : "\(AppBranding.displayName) serve echo: \(userText.prefix(200))"
        let payload: [String: Any] = [
            "id": "chatcmpl-echo",
            "object": "chat.completion",
            "model": Self.echoModelID,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": reply],
                "finish_reason": "stop",
            ]],
        ]
        await Self.writeJSON(connection, body: Self.jsonString(payload), status: 200)
    }

    private func respondBackendCompletion(
        body: Data,
        backend: any InferenceBackend,
        connection: NWConnection
    ) async {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            await Self.writeJSON(connection,
                                 body: Self.errorBody("invalid JSON body", type: "invalid_request_error"),
                                 status: 400)
            return
        }
        let modelID = (json["model"] as? String) ?? "default"
        let stream = (json["stream"] as? Bool) ?? false
        let messages = Self.parseMessages(from: json)
        if messages.isEmpty {
            await Self.writeJSON(connection,
                                 body: Self.errorBody("No messages provided", type: "invalid_request_error"),
                                 status: 400)
            return
        }

        // Serve's opt-in attaches ToolRegistry schemas on the proxy request.
        // Do not route through `ServeToolsPolicy.tools(.agentLoop)` — that
        // helper returns `[]` because LocalAPI loads tools inside AgentLoop.
        let tools: [ToolSchema]
        if agentToolsEnabled {
            await ToolRegistry.shared.registerBuiltins()
            tools = await ToolRegistry.shared.schemas()
        } else {
            tools = []
        }

        let model = ModelDescriptor(id: modelID, displayName: modelID, backend: backend.identifier)
        let streamID = UUID()
        let request = ChatRequest(
            model: model,
            messages: messages,
            tools: tools,
            sampling: settings.defaultSampling,
            streamID: streamID)

        if stream {
            await streamBackendCompletion(request: request, backend: backend,
                                          modelID: modelID, connection: connection)
        } else {
            await nonStreamBackendCompletion(request: request, backend: backend,
                                             modelID: modelID, connection: connection)
        }
    }

    private func streamBackendCompletion(
        request: ChatRequest,
        backend: any InferenceBackend,
        modelID: String,
        connection: NWConnection
    ) async {
        let headerOK = await Self.write(
            connection,
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n")
        if !headerOK {
            await backend.cancel(streamID: request.streamID)
            return
        }
        let chatID = "chatcmpl-\(UUID().uuidString.prefix(24))"
        let created = Int(Date().timeIntervalSince1970)
        // Role chunk first (Xcode-friendly).
        _ = await Self.write(connection, Self.sseRoleChunk(id: chatID, created: created, model: modelID))
        do {
            for try await chunk in backend.stream(request: request) {
                if case .contentDelta(let text) = chunk, !text.isEmpty {
                    let line = Self.sseContentChunk(id: chatID, created: created, model: modelID, text: text)
                    if !(await Self.write(connection, line)) {
                        await backend.cancel(streamID: request.streamID)
                        return
                    }
                }
            }
            _ = await Self.write(connection, "data: [DONE]\n\n")
        } catch {
            let err = "data: \(Self.errorBody(error.localizedDescription, type: "backend_error"))\n\n"
            _ = await Self.write(connection, err)
        }
    }

    private func nonStreamBackendCompletion(
        request: ChatRequest,
        backend: any InferenceBackend,
        modelID: String,
        connection: NWConnection
    ) async {
        var content = ""
        do {
            for try await chunk in backend.stream(request: request) {
                if case .contentDelta(let t) = chunk { content += t }
            }
        } catch {
            await Self.writeJSON(connection,
                                 body: Self.errorBody(error.localizedDescription, type: "backend_error"),
                                 status: 502)
            return
        }
        let payload: [String: Any] = [
            "id": "chatcmpl-\(UUID().uuidString.prefix(24))",
            "object": "chat.completion",
            "model": modelID,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": content],
                "finish_reason": "stop",
            ]],
        ]
        await Self.writeJSON(connection, body: Self.jsonString(payload), status: 200)
    }

    // MARK: - Pure helpers (tests)

    public static func extractLastUserText(from body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        let messages = parseMessages(from: json)
        return messages.last(where: { $0.role == .user })?.content
    }

    public static func parseMessages(from json: [String: Any]) -> [ChatMessage] {
        let rawMessages = (json["messages"] as? [[String: Any]]) ?? []
        return rawMessages.compactMap { dict in
            guard let role = dict["role"] as? String else { return nil }
            let mapped: ChatMessage.Role = {
                switch role {
                case "system": return .system
                case "user": return .user
                case "assistant": return .assistant
                case "tool": return .tool
                default: return .user
                }
            }()
            let content: String = {
                if let s = dict["content"] as? String { return s }
                if let rawParts = dict["content"] as? [Any] {
                    var assembled = ""
                    for raw in rawParts {
                        guard let part = raw as? [String: Any],
                              (part["type"] as? String) == "text",
                              let text = part["text"] as? String
                        else { continue }
                        assembled += text
                    }
                    return assembled
                }
                return ""
            }()
            return ChatMessage(role: mapped, content: content)
        }
    }

    // MARK: - Minimal HTTP

    private static func parseRequest(connection: NWConnection)
    async -> (method: String, path: String, body: Data)?
    {
        var buf = Data()
        let sentinel = Data([0x0D, 0x0A, 0x0D, 0x0A])
        while buf.range(of: sentinel) == nil {
            guard let chunk = await recv(connection) else { return nil }
            buf.append(chunk)
            if buf.count > 1_048_576 { return nil }
        }
        let split = buf.range(of: sentinel)!
        let headerData = buf[..<split.lowerBound]
        var bodyBuf = Data(buf[split.upperBound...])
        guard let hs = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = hs.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let tokens = requestLine.split(separator: " ", maxSplits: 2)
        guard tokens.count >= 2 else { return nil }
        let method = String(tokens[0])
        let path = String(tokens[1])
        var contentLength = 0
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let val = line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                contentLength = Int(val) ?? 0
            }
        }
        while bodyBuf.count < contentLength {
            guard let chunk = await recv(connection) else { break }
            bodyBuf.append(chunk)
        }
        return (method, path, bodyBuf)
    }

    private static func recv(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                cont.resume(returning: error == nil ? data : nil)
            }
        }
    }

    @discardableResult
    private static func write(_ connection: NWConnection, _ string: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            connection.send(content: Data(string.utf8), completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }

    private static func writeJSON(_ connection: NWConnection, body: String, status: Int) async {
        let statusLine: String
        switch status {
        case 200: statusLine = "200 OK"
        case 400: statusLine = "400 Bad Request"
        case 404: statusLine = "404 Not Found"
        case 502: statusLine = "502 Bad Gateway"
        default: statusLine = "\(status)"
        }
        let header = "HTTP/1.1 \(statusLine)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        _ = await write(connection, header + body)
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func errorBody(_ message: String, type: String) -> String {
        jsonString(["error": ["message": message, "type": type]])
    }

    private static func sseRoleChunk(id: String, created: Int, model: String) -> String {
        let payload: [String: Any] = [
            "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
            "choices": [["index": 0, "delta": ["role": "assistant"], "finish_reason": NSNull()]],
        ]
        return "data: \(jsonString(payload))\n\n"
    }

    private static func sseContentChunk(id: String, created: Int, model: String, text: String) -> String {
        let payload: [String: Any] = [
            "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
            "choices": [["index": 0, "delta": ["content": text], "finish_reason": NSNull()]],
        ]
        return "data: \(jsonString(payload))\n\n"
    }
}
