//
//  LocalAPIServer.swift
//
//  Inbound OpenAI-compatible HTTP server. Xcode 16 → Settings →
//  Intelligence → provider at http://localhost:11435/v1 talks to
//  AgentOS as if it were a local OpenAI-compatible host.
//
//  Default: **backend proxy** with `tools: []` (Xcode-safe). Opt-in
//  `agentToolsEnabled` runs a **bounded multi-step AgentLoop** (model →
//  tools → model) — D1. Still loopback-only; not "Xcode is always agentic."
//
//  P0 implementation uses Network.framework's NWListener — same as the
//  original AgentOS. P3-poly moves to SwiftNIO; until then this is the
//  minimum viable surface.
//
//  Endpoints:
//    GET  /v1/models                       → list models from the active backend
//    POST /v1/chat/completions             → streamed SSE: proxy (default) or
//                                            bounded AgentLoop when
//                                            `agentToolsEnabled` is true
//    OPTIONS *                             → CORS preflight (browser only)
//
//  Compatibility notes — these are the THREE things that keep strict
//  clients (Xcode Intelligence in particular) working, every one of
//  which was discovered the hard way in the DEV PLAN build:
//
//    1. First SSE chunk must include `delta.role = "assistant"` BEFORE
//       any content delta. Xcode's coding assistant won't begin
//       accumulating content until it has seen the role announcement.
//       See `sseRoleChunk` below.
//
//    2. Streamed responses MUST use `Transfer-Encoding: chunked` with
//       proper hex-size frames. Plain text/event-stream without a
//       transfer encoding violates HTTP/1.1 and strict clients hang
//       forever waiting for either Content-Length or a chunked end.
//       See `sendChunked` below.
//
//    3. Request body must be read in a LOOP until Content-Length is
//       satisfied. Xcode requests with full conversation history can
//       easily exceed a single TCP read window (64 KB). The old code
//       silently dropped bytes after the first read, JSON parse
//       failed, and the request 400'd. See `parseRequest` below.
//

import Foundation
import Network

public enum LocalAPIAgentLoopError: Error, LocalizedError, Sendable, Equatable {
    case missingProjectRoot

    public var errorDescription: String? {
        switch self {
        case .missingProjectRoot:
            return "Agent loop requires a project folder (not filesystem root)."
        }
    }
}

public actor LocalAPIServer {

    public static let shared = LocalAPIServer()

    private var listener: NWListener?
    private var port: Int = 11435
    private var backend: (any InferenceBackend)?
    private var settings: AppSettings = AppSettings()
    /// Opt-in (default **false**): run bounded multi-step AgentLoop on
    /// `/v1/chat/completions` (tool execute + re-prompt). When false,
    /// Xcode-safe proxy with `tools: []`.
    private var agentToolsEnabled: Bool = false
    /// Required workspace for agent-loop turns. Without a usable root,
    /// agent-loop requests fail closed (no unattended writes at `/`).
    private var agentLoopProjectRoot: URL?

    /// Hard cap for LocalAPI agent-loop iterations (anti recursion bomb).
    /// Independent of in-app `maxAgentIterations` (which may be 30–100).
    public static let agentLoopMaxIterations = 8

    public init() {}

    public func configure(
        backend: any InferenceBackend,
        settings: AppSettings,
        agentToolsEnabled: Bool = false,
        agentLoopProjectRoot: URL? = nil
    ) {
        self.backend = backend
        self.settings = settings
        self.agentToolsEnabled = agentToolsEnabled
        self.agentLoopProjectRoot = agentLoopProjectRoot
    }

    public func setAgentLoopProjectRoot(_ url: URL?) {
        agentLoopProjectRoot = url
    }

    public func currentAgentLoopProjectRoot() -> URL? { agentLoopProjectRoot }

    public func isAgentToolsEnabled() -> Bool { agentToolsEnabled }

    /// Update the opt-in without restarting (next request sees the flag).
    public func setAgentToolsEnabled(_ enabled: Bool) {
        agentToolsEnabled = enabled
    }

    /// Effective tools policy for the current flag (testable).
    public func toolsPolicy() -> ServeToolsPolicy {
        ServeToolsPolicy.resolve(agentToolsEnabled: agentToolsEnabled)
    }

    public enum ServerError: Error, LocalizedError {
        case invalidPort(Int)
        case bindFailed(Int)
        public var errorDescription: String? {
            switch self {
            case .invalidPort(let p): return "Invalid port: \(p)"
            case .bindFailed(let p): return "Could not bind Local API Server on :\(p) (address already in use?)"
            }
        }
    }

    public func start(port: Int) async throws {
        // Always tear down first so "Address already in use" from a stale
        // listener (double start on settings save / app relaunch) is avoided.
        await stopAndWait()
        self.port = port
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard port > 0, port <= 65_535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ServerError.invalidPort(port)
        }
        // Bind to LOOPBACK ONLY. Without requiredLocalEndpoint the
        // listener accepts connections from any interface — i.e. every
        // device on the LAN could drive this server (and, once v1.1
        // routes requests through the agent loop, the user's filesystem
        // tools). Xcode/curl on this Mac is the only intended client.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)

        // Retry once after a short delay if the OS still holds the port.
        var lastError: Error?
        for attempt in 1...2 {
            do {
                let newListener = try NWListener(using: params)
                // Handler must be set *before* start — NWListener errors if not.
                newListener.newConnectionHandler = { [weak self] connection in
                    Task { [weak self] in
                        await self?.handle(connection: connection)
                    }
                }
                let ready = try await Self.waitUntilReady(newListener, port: port)
                if !ready {
                    newListener.cancel()
                    throw ServerError.bindFailed(port)
                }
                self.listener = newListener
                Diagnostics.info("LocalAPIServer ready on :\(port)")
                return
            } catch {
                lastError = error
                Diagnostics.warn("LocalAPIServer start attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt == 1 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        throw lastError ?? ServerError.bindFailed(port)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        Diagnostics.info("LocalAPIServer stopped")
    }

    /// Cancel listener and give the kernel a moment to free the port.
    public func stopAndWait() async {
        if listener != nil {
            listener?.cancel()
            listener = nil
            try? await Task.sleep(nanoseconds: 150_000_000)
            Diagnostics.info("LocalAPIServer stopped")
        }
    }

    private static func waitUntilReady(_ listener: NWListener, port: Int) async throws -> Bool {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            let box = ReadyBox()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.finish(true, cont)
                case .failed(let err):
                    Diagnostics.error("LocalAPIServer failed: \(err.localizedDescription)")
                    box.finish(false, cont)
                case .cancelled:
                    box.finish(false, cont)
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            // Timeout: if never ready, fail the attempt.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                box.finish(false, cont)
            }
        }
    }

    /// One-shot resume helper for NWListener ready wait.
    private final class ReadyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func finish(_ value: Bool, _ cont: CheckedContinuation<Bool, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            cont.resume(returning: value)
        }
    }

    public func isRunning() -> Bool { listener != nil }

    public func currentPort() -> Int { port }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        Task { [weak self] in
            await self?.serve(connection: connection)
        }
    }

    /// Top-level request handler. Parses, routes, writes response, closes.
    private func serve(connection: NWConnection) async {
        defer { connection.cancel() }
        guard let parsed = await Self.parseRequest(connection: connection) else {
            return
        }
        let (method, path, headers, body) = parsed
        let origin = headers["origin"]

        // CORS preflight — short-circuit before anything else. Browsers
        // send OPTIONS before POST on cross-origin requests; native
        // clients (Xcode, curl) never trigger this path.
        if method == "OPTIONS" {
            await Self.write(connection,
                             "HTTP/1.1 204 No Content\r\n\(Self.cors(origin: origin))Content-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }

        switch OpenAICompatServeRoute.resolve(method: method, path: path) {
        case .options:
            // Already handled above for browsers; keep for pure resolve parity.
            await Self.write(connection,
                             "HTTP/1.1 204 No Content\r\n\(Self.cors(origin: origin))Content-Length: 0\r\nConnection: close\r\n\r\n")
        case .models:
            await respondModels(connection: connection, origin: origin)
        case .chatCompletions:
            await respondChatCompletion(body: body, connection: connection, origin: origin)
        case .notFound:
            let e = #"{"error":{"message":"not found","type":"not_found"}}"#
            await Self.writeJSON(connection, origin: origin, body: e, status: 404)
        }
    }

    private func respondModels(connection: NWConnection, origin: String?) async {
        guard let backend else {
            await Self.writeJSON(connection, origin: origin,
                                 body: #"{"error":{"message":"no backend configured","type":"server_error"}}"#,
                                 status: 503)
            return
        }
        do {
            let models = try await backend.listModels()
            let items = models.map {
                ["id": $0.id, "object": "model", "created": 1700000000, "owned_by": "agentos"] as [String: Any]
            }
            let payload: [String: Any] = ["object": "list", "data": items]
            let json = Self.jsonString(payload)
            await Self.writeJSON(connection, origin: origin, body: json, status: 200)
        } catch {
            await Self.writeJSON(connection, origin: origin,
                                 body: Self.errorBody(error.localizedDescription, type: "backend_error"),
                                 status: 502)
        }
    }

    private func respondChatCompletion(body: Data, connection: NWConnection, origin: String?) async {
        guard let backend else {
            await Self.writeJSON(connection, origin: origin,
                                 body: #"{"error":{"message":"no backend configured","type":"server_error"}}"#,
                                 status: 503)
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            await Self.writeJSON(connection, origin: origin,
                                 body: #"{"error":{"message":"invalid JSON body","type":"invalid_request_error"}}"#,
                                 status: 400)
            return
        }
        let modelID = (json["model"] as? String) ?? "default"
        let rawMessages = (json["messages"] as? [[String: Any]]) ?? []
        let messages: [ChatMessage] = rawMessages.compactMap { dict in
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

            // Content may arrive in two shapes:
            //   (1) Plain string: "Hi"
            //   (2) OpenAI content-parts array:
            //       [{"type":"text","text":"Hi"}, ...]
            // Modern clients — including Xcode 16's Intelligence —
            // emit shape (2) even for plain text.
            //
            // NB on the array cast: `dict["content"] as? [[String: Any]]`
            // looks right but routinely fails in practice because
            // JSONSerialization returns NSArray-of-NSDictionary, and
            // the Swift bridging doesn't drill into the elements on a
            // single deep cast. We have to cast to `[Any]` first then
            // individually downcast each element. Skipping that step
            // was what made the parser silently drop Xcode messages.
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

        // Fail closed: empty message list after parse used to stream an
        // empty completion (or upstream 400) with only a Diagnostics log.
        // Strict clients (Xcode) get a clear 400 instead.
        if messages.isEmpty {
            Diagnostics.error("LocalAPIServer: parsed 0 messages from request with \(rawMessages.count) raw entries")
            await Self.writeJSON(connection, origin: origin,
                                 body: Self.errorBody(
                                    "No messages provided (parsed 0 of \(rawMessages.count) raw entries)",
                                    type: "invalid_request_error"),
                                 status: 400)
            return
        }

        let model = ModelDescriptor(id: modelID, displayName: modelID, backend: backend.identifier)
        let policy = ServeToolsPolicy.resolve(agentToolsEnabled: agentToolsEnabled)

        // D1: opt-in multi-step AgentLoop (tool execute + re-prompt).
        // Default remains Xcode-safe proxy with tools: [].
        if policy.runsAgentLoop {
            guard let root = PathConfinement.usableWorkspaceRoot(agentLoopProjectRoot) else {
                await Self.writeJSON(
                    connection,
                    origin: origin,
                    body: Self.errorBody(
                        "Agent loop requires a project folder. Bind a project in the app, then retry.",
                        type: "invalid_request_error"),
                    status: 400)
                return
            }
            await respondAgentLoop(
                messages: messages,
                model: model,
                backend: backend,
                connection: connection,
                origin: origin,
                projectRoot: root
            )
            return
        }

        let streamID = UUID()
        let tools = await Self.completionTools(agentToolsEnabled: false)
        let request = ChatRequest(model: model, messages: messages,
                                  tools: tools,
                                  sampling: settings.defaultSampling,
                                  streamID: streamID)

        // Stream as SSE with chunked transfer encoding (HTTP/1.1
        // requires either Content-Length or Transfer-Encoding; we have
        // no Content-Length up front).
        let headerOK = await Self.write(connection,
                         "HTTP/1.1 200 OK\r\n\(Self.cors(origin: origin))Content-Type: text/event-stream\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
        if !headerOK {
            await backend.cancel(streamID: streamID)
            return
        }

        let chatID = "chatcmpl-\(UUID().uuidString.prefix(24))"
        let created = Int(Date().timeIntervalSince1970)

        // Bug-1 fix: send the leading role chunk BEFORE any content
        // deltas. Xcode's coding assistant ignores everything that
        // arrives before this.
        if !(await Self.sendChunked(connection,
                               text: Self.sseRoleChunk(id: chatID, created: created, model: modelID))) {
            // Client gone before first token — stop backend generation.
            await backend.cancel(streamID: streamID)
            return
        }

        do {
            for try await chunk in backend.stream(request: request) {
                let line = Self.formatSSE(chunk: chunk, id: chatID, created: created, model: modelID)
                // C2: if the client disconnects mid-stream, stop pumping
                // the backend (was: ignore send errors and run to completion).
                if !(await Self.sendChunked(connection, text: line)) {
                    await backend.cancel(streamID: streamID)
                    return
                }
            }
            _ = await Self.sendChunked(connection, text: "data: [DONE]\n\n")
            // Chunked-encoding terminator: zero-size chunk.
            _ = await Self.write(connection, "0\r\n\r\n")
        } catch {
            let errLine = "data: \(Self.errorBody(error.localizedDescription, type: "backend_error"))\n\n"
            _ = await Self.sendChunked(connection, text: errLine)
            _ = await Self.write(connection, "0\r\n\r\n")
        }
    }

    /// Multi-step agent path: stream AgentLoop content as OpenAI SSE.
    private func respondAgentLoop(
        messages: [ChatMessage],
        model: ModelDescriptor,
        backend: any InferenceBackend,
        connection: NWConnection,
        origin: String?,
        projectRoot: URL
    ) async {
        let headerOK = await Self.write(connection,
                         "HTTP/1.1 200 OK\r\n\(Self.cors(origin: origin))Content-Type: text/event-stream\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
        if !headerOK { return }

        let chatID = "chatcmpl-\(UUID().uuidString.prefix(24))"
        let created = Int(Date().timeIntervalSince1970)
        let modelID = model.id

        if !(await Self.sendChunked(connection,
                               text: Self.sseRoleChunk(id: chatID, created: created, model: modelID))) {
            return
        }

        let clientGone = ClientGoneFlag()
        let cancel = LoopCancelHandle()
        let loopTask = Task { [backend, model, messages, settings, projectRoot] in
            try await Self.runAgentLoopTurn(
                backend: backend,
                model: model,
                messages: messages,
                settings: settings,
                maxIterations: Self.agentLoopMaxIterations,
                projectRoot: projectRoot
            ) { event in
                guard !clientGone.value else { return }
                switch event {
                case .contentDelta(let s):
                    guard !s.isEmpty else { return }
                    let line = Self.formatSSE(
                        chunk: .contentDelta(s),
                        id: chatID, created: created, model: modelID)
                    if !(await Self.sendChunked(connection, text: line)) {
                        clientGone.mark()
                        cancel.cancel()
                    }
                case .error(let description):
                    let errLine = "data: \(Self.errorBody(description, type: "agent_error"))\n\n"
                    _ = await Self.sendChunked(connection, text: errLine)
                default:
                    break
                }
            }
        }
        cancel.task = loopTask
        do {
            _ = try await loopTask.value
            if !clientGone.value {
                _ = await Self.sendChunked(connection, text: "data: [DONE]\n\n")
                _ = await Self.write(connection, "0\r\n\r\n")
            }
        } catch is CancellationError {
            // Client gone — AgentLoop already checked Task.isCancelled.
        } catch {
            let errLine = "data: \(Self.errorBody(error.localizedDescription, type: "agent_error"))\n\n"
            _ = await Self.sendChunked(connection, text: errLine)
            _ = await Self.write(connection, "0\r\n\r\n")
        }
    }

    /// Shared cancel token so a failed SSE write can stop the agent Task.
    final class LoopCancelHandle: @unchecked Sendable {
        var task: Task<Conversation, Error>?
        func cancel() { task?.cancel() }
    }

    // MARK: - Agent loop (testable without NWConnection)

    /// Split request messages into conversation history + latest user turn.
    public static func splitHistoryAndUser(
        _ messages: [ChatMessage]
    ) -> (history: [ChatMessage], userMessage: String) {
        if let lastIdx = messages.lastVisibleUserIndex() {
            let history = Array(messages[..<lastIdx])
            let user = messages[lastIdx].content
            return (history, user)
        }
        // No user message — treat entire list as history, empty prompt
        // (AgentLoop will still append an empty user turn; callers should
        // fail-closed earlier on empty content when possible).
        return (messages, "")
    }

    /// Drive one bounded AgentLoop turn for LocalAPI. Pure of HTTP —
    /// unit tests inject a scripted backend + assert tool round-trips.
    @discardableResult
    /// Fail closed: no project, or filesystem root (`/`), is not a workspace.
    public static func requireUsableProjectRoot(_ url: URL?) throws -> URL {
        guard let root = PathConfinement.usableWorkspaceRoot(url) else {
            throw LocalAPIAgentLoopError.missingProjectRoot
        }
        return root
    }

    public static func runAgentLoopTurn(
        backend: any InferenceBackend,
        model: ModelDescriptor,
        messages: [ChatMessage],
        settings: AppSettings = AppSettings(),
        maxIterations: Int = agentLoopMaxIterations,
        projectRoot: URL? = nil,
        events: @escaping @Sendable (LoopEvent) async -> Void = { _ in }
    ) async throws -> Conversation {
        let root = try requireUsableProjectRoot(projectRoot)
        await ToolRegistry.shared.registerBuiltins()
        let cap = max(1, min(maxIterations, agentLoopMaxIterations))
        let (history, userMessage) = splitHistoryAndUser(messages)
        var convo = Conversation(
            title: "local-api",
            modelID: model.id,
            projectRoot: root
        )
        convo.messages = history

        // Auto (edit): file mutations stay inside `root` via PathConfinement.
        // Shell / MCP still `.ask` and hard-deny without a coordinator.
        // Never Full/yolo — a loopback client must not inherit process CWD.
        let config = AgentLoop.Configuration(
            maxIterations: cap,
            stallWindow: 3,
            verifyEdits: settings.verifyEdits,
            safeMode: nil,
            headlessMode: true,
            rawMode: false,
            // LocalAPI must not open nested MCP / Xcode bridges by default
            // (keeps the opt-in path bounded and predictable).
            xcodeMCPEnabled: false,
            mcpServers: [],
            executionMode: .edit
        )
        let loop = AgentLoop(backend: backend, model: model, config: config)
        let prompt = userMessage.isEmpty ? "(empty user message)" : userMessage
        return try await loop.run(
            userMessage: prompt,
            conversation: convo,
            sampling: settings.defaultSampling,
            events: events
        )
    }

    /// Resolve tool schemas for a **proxy** completion request.
    /// Agent-loop mode does not use this helper (tools load inside AgentLoop).
    /// When `agentToolsEnabled` is true, returns `[]` because resolve maps
    /// to `.agentLoop` which does not attach schemas on the proxy request.
    public static func completionTools(agentToolsEnabled: Bool) async -> [ToolSchema] {
        let policy = ServeToolsPolicy.resolve(agentToolsEnabled: agentToolsEnabled)
        guard policy == .schemasOnly else { return [] }
        await ToolRegistry.shared.registerBuiltins()
        let schemas = await ToolRegistry.shared.schemas()
        return ServeToolsPolicy.tools(policy: policy, registeredSchemas: schemas)
    }

    /// Thread-safe client-disconnect flag for the agent-loop SSE pump.
    private final class ClientGoneFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var gone = false
        var value: Bool {
            lock.lock(); defer { lock.unlock() }
            return gone
        }
        func mark() {
            lock.lock(); gone = true; lock.unlock()
        }
    }

    // MARK: - HTTP plumbing (all `static` so they can run off the actor)

    /// Read the request fully — headers loop until `\r\n\r\n`, then body
    /// loop until `Content-Length` is satisfied. Bug-3 fix.
    private static func parseRequest(connection: NWConnection)
    async -> (method: String, path: String, headers: [String: String], body: Data)?
    {
        var buf = Data()
        let sentinel = Data([0x0D, 0x0A, 0x0D, 0x0A])  // "\r\n\r\n"

        // 1) Read until we see the end-of-headers sentinel.
        while buf.range(of: sentinel) == nil {
            guard let chunk = await recv(connection) else { return nil }
            buf.append(chunk)
            if buf.count > 4 * 1_048_576 { return nil }   // 4 MB header guard
        }

        let split = buf.range(of: sentinel)!
        let headerData = buf[..<split.lowerBound]
        var bodyBuf = Data(buf[split.upperBound...])

        guard let hs = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = hs.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let rlTokens = requestLine.split(separator: " ", maxSplits: 2)
        guard rlTokens.count >= 2 else { return nil }
        let method = String(rlTokens[0])
        let path = String(rlTokens[1]).components(separatedBy: "?").first ?? ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
                .lowercased()
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // 2) Continue reading until Content-Length bytes are in bodyBuf.
        //    Without this, Xcode's bigger requests get truncated.
        if let lenStr = headers["content-length"], let len = Int(lenStr), len > 0 {
            while bodyBuf.count < len {
                guard let chunk = await recv(connection) else { break }
                bodyBuf.append(chunk)
                if bodyBuf.count > 16 * 1_048_576 { break }   // 16 MB body guard
            }
        }
        return (method, path, headers, bodyBuf)
    }

    /// One Network.framework receive call wrapped as `async`.
    private static func recv(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                cont.resume(returning: error == nil ? data : nil)
            }
        }
    }

    /// Plain write — no chunked framing. Used for status lines, the
    /// HTTP header block, and the final zero-chunk terminator.
    /// Returns `false` if the send failed (client disconnect).
    @discardableResult
    private static func write(_ connection: NWConnection, _ string: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            connection.send(content: Data(string.utf8), completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }

    /// Chunked-transfer frame: `<hex-size>\r\n<bytes>\r\n`. Bug-2 fix.
    /// Returns `false` if the client is gone so the caller can cancel the
    /// backend stream instead of generating into a dead socket.
    @discardableResult
    private static func sendChunked(_ connection: NWConnection, text: String) async -> Bool {
        let body = Data(text.utf8)
        var chunk = Data("\(String(body.count, radix: 16))\r\n".utf8)
        chunk.append(body)
        chunk.append(Data("\r\n".utf8))
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            connection.send(content: chunk, completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }

    private static func writeJSON(_ connection: NWConnection, origin: String?, body: String, status: Int) async {
        let statusLine = status == 200 ? "200 OK" : "\(status) \(statusText(status))"
        let header = "HTTP/1.1 \(statusLine)\r\n\(cors(origin: origin))Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        _ = await write(connection, header + body)
    }

    /// CORS headers — only echoed for browser-style requests carrying
    /// `Origin`. Native clients (Xcode, curl) never set `Origin`, so
    /// CORS is a no-op for them. The wildcard `*` is intentionally
    /// avoided; we only allow localhost origins.
    private static func cors(origin: String?) -> String {
        var headers = "Access-Control-Allow-Methods: GET,POST,OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type,Authorization\r\n"
        if let origin, isLocalhostOrigin(origin) {
            headers = "Access-Control-Allow-Origin: \(origin)\r\n" + headers
        }
        return headers
    }

    /// Exact host match only — `http://localhost.evil.com` must not inherit
    /// the `http://localhost` prefix allow-list.
    private static func isLocalhostOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        let host = (url.host ?? "").lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    // MARK: - SSE chunk formatting

    /// Synthetic role chunk emitted before any content deltas. Required
    /// by Xcode's coding assistant. Bug-1 fix.
    private static func sseRoleChunk(id: String, created: Int, model: String) -> String {
        let payload: [String: Any] = [
            "id": id, "object": "chat.completion.chunk",
            "created": created, "model": model,
            "choices": [["index": 0, "delta": ["role": "assistant", "content": ""],
                         "logprobs": NSNull(), "finish_reason": NSNull()]]
        ]
        return "data: \(jsonString(payload))\n\n"
    }

    /// Map a backend `ChatChunk` to an SSE `data:` line.
    private static func formatSSE(chunk: ChatChunk, id: String, created: Int, model: String) -> String {
        switch chunk {
        case .reasoningDelta(let s):
            let payload: [String: Any] = [
                "id": id, "object": "chat.completion.chunk",
                "created": created, "model": model,
                "choices": [["index": 0, "delta": ["reasoning_content": s],
                             "logprobs": NSNull(), "finish_reason": NSNull()]]
            ]
            return "data: \(jsonString(payload))\n\n"
        case .contentDelta(let s):
            let payload: [String: Any] = [
                "id": id, "object": "chat.completion.chunk",
                "created": created, "model": model,
                "choices": [["index": 0, "delta": ["content": s],
                             "logprobs": NSNull(), "finish_reason": NSNull()]]
            ]
            return "data: \(jsonString(payload))\n\n"
        case .toolCallDelta(let index, let cid, let name, let args):
            var tc: [String: Any] = ["index": index, "type": "function"]
            if let cid, !cid.isEmpty { tc["id"] = cid }
            var function: [String: Any] = [:]
            if let n = name { function["name"] = n }
            if let a = args { function["arguments"] = a }
            tc["function"] = function
            let payload: [String: Any] = [
                "id": id, "object": "chat.completion.chunk",
                "created": created, "model": model,
                "choices": [["index": 0, "delta": ["tool_calls": [tc]],
                             "logprobs": NSNull(), "finish_reason": NSNull()]]
            ]
            return "data: \(jsonString(payload))\n\n"
        case .done(let reason):
            let payload: [String: Any] = [
                "id": id, "object": "chat.completion.chunk",
                "created": created, "model": model,
                "choices": [["index": 0, "delta": [:],
                             "logprobs": NSNull(), "finish_reason": reason]]
            ]
            return "data: \(jsonString(payload))\n\n"
        case .usage(let p, let c):
            // The usage chunk MUST carry `choices: []` even though it
            // has no content. OpenAI's spec lists `choices` as a
            // required field on `chat.completion.chunk`, and strict
            // SSE parsers (Xcode 16/26 Intelligence among them) error
            // out on the response when they hit a usage-only chunk
            // without it — the chat still streams visually, but the
            // assistant surfaces "request couldn't be completed" once
            // the parser fails.
            let payload: [String: Any] = [
                "id": id, "object": "chat.completion.chunk",
                "created": created, "model": model,
                "choices": [Any](),  // explicitly empty array, never nil
                "usage": ["prompt_tokens": p, "completion_tokens": c, "total_tokens": p + c]
            ]
            return "data: \(jsonString(payload))\n\n"
        }
    }

    private static func jsonString(_ obj: Any) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    /// Error payload built via JSONSerialization — interpolating raw
    /// error descriptions into JSON literals broke the body whenever a
    /// description contained a newline or backslash (quote-replacement
    /// alone wasn't enough).
    private static func errorBody(_ message: String, type: String) -> String {
        jsonString(["error": ["message": message, "type": type]])
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
