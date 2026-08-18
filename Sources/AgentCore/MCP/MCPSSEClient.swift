//
//  MCPSSEClient.swift
//
//  Legacy MCP HTTP+SSE transport (2024-11-05):
//    1. GET the configured URL with Accept: text/event-stream
//    2. Wait for `event: endpoint` (data = POST URI)
//    3. POST JSON-RPC to that URI
//    4. Read JSON-RPC replies as `event: message` on the GET stream
//
//  This is not Streamable HTTP. Streamable HTTP POSTs to the configured
//  URL and may get an SSE *response body*. Legacy SSE keeps a long-lived
//  GET session and never POSTs to the SSE URL.
//

import Foundation

/// Actor implementing the legacy MCP HTTP+SSE transport.
public actor MCPSSEClient {

    private let config: MCPServerConfig
    private let streamSession: URLSession
    private let postSession: URLSession

    private var sseURL: URL?
    private var messageURL: URL?
    private var nextID = 1
    private(set) var isConnected = false
    private var lastEventID: String?

    private var streamTask: Task<Void, Never>?
    private var pending: [Int: CheckedContinuation<MCPJSONPayload, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var endpointWaiters: [CheckedContinuation<URL, Error>] = []
    private var endpointTimeoutTask: Task<Void, Never>?

    private var currentEvent = ""
    private var currentData = ""
    private var currentID: String?

    private var oauthTokenProvider: (@Sendable () async -> String?)?
    private var oauthOnUnauthorized: (@Sendable () async -> Void)?

    public init(config: MCPServerConfig) {
        self.config = config
        let streamCfg = URLSessionConfiguration.ephemeral
        streamCfg.timeoutIntervalForRequest = 0
        streamCfg.timeoutIntervalForResource = 0
        self.streamSession = URLSession(configuration: streamCfg)
        self.postSession = URLSession(configuration: .ephemeral)
    }

    public func setOAuthTokenProvider(
        _ provider: @escaping @Sendable () async -> String?
    ) {
        self.oauthTokenProvider = provider
    }

    public func setOAuthOnUnauthorized(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        self.oauthOnUnauthorized = handler
    }

    /// Last `id:` field seen on the GET stream (for Last-Event-ID reconnect).
    public func lastSeenEventID() -> String? { lastEventID }

    /// Resolve an `endpoint` event payload against the GET URL.
    public static func resolveMessageURL(endpoint: String, sseURL: URL) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let abs = URL(string: trimmed), abs.scheme != nil, abs.host != nil {
            return abs
        }
        return URL(string: trimmed, relativeTo: sseURL)?.absoluteURL
    }

    // MARK: - Connection

    public func connect(clientName: String = AppBranding.displayName,
                        clientVersion: String = AgentCore.version) async throws {
        guard config.transport == .sse, let urlStr = config.url else {
            throw MCPHttpError.connectionFailed("Config is not a valid SSE server")
        }
        guard let url = URL(string: urlStr) else {
            throw MCPHttpError.invalidURL(urlStr)
        }

        await disconnect()
        sseURL = url
        startStream(url: url)

        let endpoint = try await waitForEndpoint(timeout: config.startupTimeout)
        messageURL = endpoint

        let initParams: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": [
                "name": clientName,
                "version": clientVersion,
            ],
        ]
        _ = try await request(method: "initialize", params: initParams, timeout: config.startupTimeout)
        try? await notify(method: "notifications/initialized", params: [:])
        isConnected = true
    }

    public func disconnect() async {
        streamTask?.cancel()
        streamTask = nil
        endpointTimeoutTask?.cancel()
        endpointTimeoutTask = nil
        failEndpointWaiters(MCPClientError.notConnected)
        failAllPending(MCPClientError.notConnected)
        isConnected = false
        sseURL = nil
        messageURL = nil
        lastEventID = nil
        currentEvent = ""
        currentData = ""
        currentID = nil
    }

    // MARK: - JSON-RPC

    public func request(method: String, params: [String: Any],
                        timeout seconds: TimeInterval = 120) async throws -> MCPJSONPayload {
        guard let postURL = messageURL else {
            throw MCPHttpError.connectionFailed("SSE endpoint event not received")
        }
        let id = nextID
        nextID += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            let sleepNanos = UInt64(max(seconds, 0.1) * 1_000_000_000)
            timeoutTasks[id] = Task {
                try? await Task.sleep(nanoseconds: sleepNanos)
                await self.timeoutPendingRequest(id: id, method: method)
            }
            Task { await self.postAndMaybeFulfill(id: id, url: postURL, payload: payload) }
        }
    }

    public func notify(method: String, params: [String: Any]) async throws {
        guard let postURL = messageURL else {
            throw MCPHttpError.connectionFailed("SSE endpoint event not received")
        }
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if !params.isEmpty { payload["params"] = params }
        _ = try await postJSON(url: postURL, payload: payload, timeout: 30, expectResultForID: nil)
    }

    // MARK: - GET stream

    private func startStream(url: URL) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.pumpStream(url: url)
        }
    }

    private func pumpStream(url: URL) async {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let lastEventID, !lastEventID.isEmpty {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }
        await applyHeaders(to: &request)
        request.timeoutInterval = 0

        do {
            let (bytes, response) = try await streamSession.bytes(for: request)
            if Task.isCancelled { return }
            guard let http = response as? HTTPURLResponse else {
                failEndpointWaiters(MCPHttpError.connectionFailed("Non-HTTP SSE response"))
                return
            }
            if http.statusCode == 401, oauthTokenProvider != nil {
                await oauthOnUnauthorized?()
            }
            guard (200...299).contains(http.statusCode) else {
                let err = MCPHttpError.httpStatus(http.statusCode, "SSE GET failed")
                failEndpointWaiters(err)
                failAllPending(err)
                return
            }
            // Parse `\n`-terminated lines ourselves. `bytes.lines` can
            // omit the empty terminator that ends an SSE event.
            var lineBuf = Data()
            for try await byte in bytes {
                if Task.isCancelled { break }
                if byte == 0x0A {
                    if lineBuf.last == 0x0D { lineBuf.removeLast() }
                    let line = String(data: lineBuf, encoding: .utf8) ?? ""
                    lineBuf.removeAll(keepingCapacity: true)
                    ingestSSELine(line)
                } else {
                    lineBuf.append(byte)
                }
            }
            if !lineBuf.isEmpty {
                if lineBuf.last == 0x0D { lineBuf.removeLast() }
                let line = String(data: lineBuf, encoding: .utf8) ?? ""
                ingestSSELine(line)
                dispatchEvent()
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                let err = MCPHttpError.connectionFailed(error.localizedDescription)
                failEndpointWaiters(err)
                failAllPending(err)
            }
        }
    }

    private func ingestSSELine(_ line: String) {
        if line.isEmpty {
            dispatchEvent()
            return
        }
        if line.hasPrefix(":") { return }
        if line.hasPrefix("event:") {
            currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            let dataContent = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if !currentData.isEmpty { currentData += "\n" }
            currentData += dataContent
            // Endpoint is a single data line; don't depend on a trailing blank.
            if currentEvent == "endpoint", !currentData.isEmpty {
                dispatchEvent()
            } else if (currentEvent.isEmpty || currentEvent == "message"),
                      currentData.first == "{", currentData.last == "}" {
                dispatchEvent()
            }
        } else if line.hasPrefix("id:") {
            currentID = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
    }

    private func dispatchEvent() {
        let event = currentEvent
        let data = currentData
        let eventID = currentID
        currentEvent = ""
        currentData = ""
        currentID = nil
        if let eventID, !eventID.isEmpty {
            lastEventID = eventID
        }
        guard !data.isEmpty else { return }

        if event == "endpoint" {
            guard let sseURL, let resolved = Self.resolveMessageURL(endpoint: data, sseURL: sseURL) else {
                failEndpointWaiters(MCPHttpError.sseParseError("Invalid endpoint event: \(data)"))
                return
            }
            noteEndpoint(resolved)
            return
        }

        // Default event type is "message" when omitted.
        if event.isEmpty || event == "message" {
            handleMessageData(data)
        }
    }

    private func handleMessageData(_ data: String) {
        guard let raw = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return
        }
        guard let id = Self.jsonRPCID(json) else { return }
        do {
            let payload = try extractResult(from: json)
            fulfill(id: id, .success(payload))
        } catch {
            fulfill(id: id, .failure(error))
        }
    }

    static func jsonRPCID(_ json: [String: Any]) -> Int? {
        if let i = json["id"] as? Int { return i }
        if let n = json["id"] as? NSNumber { return n.intValue }
        if let s = json["id"] as? String { return Int(s) }
        return nil
    }

    // MARK: - POST

    private func postAndMaybeFulfill(id: Int, url: URL, payload: [String: Any]) async {
        do {
            if let immediate = try await postJSON(
                url: url, payload: payload, timeout: 120, expectResultForID: id
            ) {
                fulfill(id: id, .success(immediate))
            }
        } catch {
            fulfill(id: id, .failure(error))
        }
    }

    /// POST JSON-RPC. Returns a payload when the POST body itself is the
    /// JSON-RPC result (some servers do this). 202 / empty body means the
    /// reply will arrive on the GET stream.
    @discardableResult
    private func postJSON(url: URL, payload: [String: Any],
                          timeout: TimeInterval,
                          expectResultForID: Int?) async throws -> MCPJSONPayload? {
        let body = try JSONSerialization.data(withJSONObject: payload)
        func makeRequest() async -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = body
            request.timeoutInterval = timeout
            await applyHeaders(to: &request)
            return request
        }

        var request = await makeRequest()
        var (data, response) = try await postSession.data(for: request)
        var http = response as? HTTPURLResponse

        if http?.statusCode == 401, oauthTokenProvider != nil {
            await oauthOnUnauthorized?()
            request = await makeRequest()
            (data, response) = try await postSession.data(for: request)
            http = response as? HTTPURLResponse
        }

        guard let http else {
            throw MCPHttpError.connectionFailed("Non-HTTP POST response")
        }
        if http.statusCode == 202 || data.isEmpty {
            return nil
        }
        if !(200...299).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? "<binary>"
            throw MCPHttpError.httpStatus(http.statusCode, String(snippet))
        }
        guard let expectResultForID else { return nil }
        if MCPHttpClient.looksLikeSSE(
            text: String(data: data, encoding: .utf8) ?? "",
            contentType: http.value(forHTTPHeaderField: "Content-Type")
        ) {
            // POST accidentally returned an SSE body — still try to extract.
            if let text = String(data: data, encoding: .utf8) {
                return try parseSSEResult(text: text, expectedID: expectResultForID)
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if Self.jsonRPCID(json) == expectResultForID || json["result"] != nil || json["error"] != nil {
            return try extractResult(from: json)
        }
        return nil
    }

    private func parseSSEResult(text: String, expectedID: Int) throws -> MCPJSONPayload {
        var current = ""
        var last: [String: Any]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty,
                   let data = current.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if Self.jsonRPCID(json) == expectedID {
                        return try extractResult(from: json)
                    }
                    last = json
                }
                current = ""
            } else if trimmed.hasPrefix("data:") {
                let dataContent = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !current.isEmpty { current += "\n" }
                current += dataContent
            }
        }
        if !current.isEmpty,
           let data = current.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return try extractResult(from: json)
        }
        if let last { return try extractResult(from: last) }
        throw MCPHttpError.sseParseError("No JSON-RPC result in POST SSE body")
    }

    private func extractResult(from json: [String: Any]) throws -> MCPJSONPayload {
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "Unknown MCP error"
            throw MCPClientError.serverError(code: code, message: message)
        }
        guard let result = json["result"] as? [String: Any] else {
            throw MCPClientError.invalidResponse("Missing 'result' in SSE message")
        }
        return MCPJSONPayload(value: result)
    }

    // MARK: - Waiters

    private func waitForEndpoint(timeout: TimeInterval) async throws -> URL {
        if let messageURL { return messageURL }
        return try await withCheckedThrowingContinuation { cont in
            endpointWaiters.append(cont)
            endpointTimeoutTask?.cancel()
            let nanos = UInt64(max(timeout, 0.1) * 1_000_000_000)
            endpointTimeoutTask = Task {
                try? await Task.sleep(nanoseconds: nanos)
                self.failEndpointWaiters(
                    MCPHttpError.connectionFailed("Timed out waiting for SSE endpoint event"))
            }
        }
    }

    private func noteEndpoint(_ url: URL) {
        messageURL = url
        endpointTimeoutTask?.cancel()
        endpointTimeoutTask = nil
        let waiters = endpointWaiters
        endpointWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: url) }
    }

    private func failEndpointWaiters(_ error: Error) {
        endpointTimeoutTask?.cancel()
        endpointTimeoutTask = nil
        let waiters = endpointWaiters
        endpointWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func timeoutPendingRequest(id: Int, method: String) async {
        await Task.yield()
        timeoutTasks.removeValue(forKey: id)
        guard let waiter = pending.removeValue(forKey: id) else { return }
        waiter.resume(throwing: MCPClientError.timeout(method))
    }

    private func fulfill(id: Int, _ result: Result<MCPJSONPayload, Error>) {
        timeoutTasks[id]?.cancel()
        timeoutTasks.removeValue(forKey: id)
        guard let waiter = pending.removeValue(forKey: id) else { return }
        switch result {
        case .success(let payload): waiter.resume(returning: payload)
        case .failure(let error): waiter.resume(throwing: error)
        }
    }

    private func failAllPending(_ error: Error) {
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
        let waiters = pending
        pending.removeAll()
        for (_, waiter) in waiters { waiter.resume(throwing: error) }
    }

    private func applyHeaders(to request: inout URLRequest) async {
        for (key, value) in config.headers {
            if key.lowercased() == "authorization" { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let provider = oauthTokenProvider,
           let token = await provider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return
        }
        if let envVar = config.bearerTokenEnvVar {
            let token = ProcessInfo.processInfo.environment[envVar] ?? ""
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
    }
}
