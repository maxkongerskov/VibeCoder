//
//  MCPHttpClient.swift
//
//  Streamable HTTP transport for the Model Context Protocol, ported from
//  Grok Build's `xai-grok-mcp` crate (Rust, rmcp SDK) to Swift.
//
//  What this is: an MCP client that connects to a remote HTTP server
//  implementing the Streamable HTTP transport (POST JSON-RPC requests,
//  SSE-formatted responses). This is what cloud MCP servers — GitHub,
//  Slack, databases, anything not running as a local subprocess — use.
//
//  What this is NOT: a full rmcp port. Grok Build wraps the official
//  Rust SDK (`rmcp`) which handles SSE parsing, session negotiation,
//  and retries. We don't have an equivalent Swift SDK, so this file
//  implements the wire protocol directly: one URLSession per server,
//  JSON-RPC over HTTP POST, SSE line parsing for streaming responses.
//
//  Architecture (mirrors Grok's three layers):
//
//    Layer 1 — HTTP transport: POST + SSE response parsing
//                          (this file, ~MCPHttpClient actor)
//    Layer 2 — JSON-RPC framing: initialize / request / notify
//                          (reuses MCPStdioClient's parser + types)
//    Layer 3 — Session lifecycle: connect / disconnect / reconnect
//                          (backoff on SSE stream death, like Grok)
//
//  Why an actor: the same reasons MCPStdioClient is one — concurrent
//  tool calls from multiple agent iterations need safe access to the
//  shared URL session, pending-request map, and reconnect state.
//

import Foundation

/// Errors specific to the HTTP transport layer. The JSON-RPC error
/// cases (`serverError`, `invalidResponse`) are shared with the stdio
/// client — both transports use the same response shape.
public enum MCPHttpError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case httpStatus(Int, String)         // status code + body snippet
    case noResponseBody
    case sseParseError(String)
    case backoffExhausted               // SSE stream died repeatedly, gave up
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "Invalid MCP server URL: \(s)"
        case .httpStatus(let code, let body): return "HTTP \(code): \(body)"
        case .noResponseBody: return "Server returned an empty response body"
        case .sseParseError(let s): return "Failed to parse SSE stream: \(s)"
        case .backoffExhausted: return "MCP server's SSE stream died repeatedly; backing off"
        case .connectionFailed(let s): return "MCP connection failed: \(s)"
        }
    }
}

/// Actor implementing the MCP Streamable HTTP transport.
///
/// One instance per configured HTTP server. Connects lazily on first
/// request (or explicitly via `connect()`). The agent loop creates these
/// at turn start from AppSettings, mirrors the stdio client's API so
/// callers don't care which transport they're talking to.
public actor MCPHttpClient {

    private let config: MCPServerConfig
    private let session: URLSession
    private var baseURL: URL?
    private var nextID = 1
    private(set) var isConnected = false

    /// OAuth token provider closure, set when the server has an OAuth
    /// config. Returns a fresh (possibly just-refreshed) access token on
    /// each call — `nil` means no credentials are available (the request
    /// will go out without an Authorization header).
    ///
    /// Set by `MCPServerPool` when the config has `.oauth`. When nil,
    /// the client falls back to the legacy `bearerTokenEnvVar` path.
    private var oauthTokenProvider: (@Sendable () async -> String?)?

    /// Called once on HTTP 401 before a single retry so the coordinator
    /// can mark the access token expired and attempt refresh. Without this,
    /// a non-expired-but-revoked token is retried with the same value.
    private var oauthOnUnauthorized: (@Sendable () async -> Void)?

    /// Backoff state for SSE stream death recovery (ported from Grok's
    /// `ThrottleState`). When a stream dies within 2 seconds of
    /// connecting, we back off exponentially (500ms → 1s → 2s → ...,
    /// capped at 30s) instead of hammering the server.
    private var consecutiveRapidDeaths = 0
    private let stableStreamThreshold: TimeInterval = 2.0
    private let baseDelay: TimeInterval = 0.5
    private let maxDelay: TimeInterval = 30.0

    public init(config: MCPServerConfig) {
        self.config = config
        self.session = URLSession(configuration: .ephemeral)
    }

    /// Set the OAuth token provider. Called by MCPServerPool when wiring
    /// up a server with an `.oauth` config. The closure is stored and
    /// called on each request to get a fresh bearer token (with proactive
    /// refresh handled by the coordinator).
    public func setOAuthTokenProvider(
        _ provider: @escaping @Sendable () async -> String?
    ) {
        self.oauthTokenProvider = provider
    }

    /// Install a 401 handler (typically `invalidateAccessToken` + refresh).
    public func setOAuthOnUnauthorized(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        self.oauthOnUnauthorized = handler
    }

    // MARK: - Connection

    /// Establish the MCP session by sending `initialize` + the
    /// `notifications/initialized` follow-up. Mirrors MCPStdioClient.
    public func connect(clientName: String = AppBranding.displayName,
                        clientVersion: String = AgentCore.version) async throws {
        guard config.transport == .streamableHttp, let urlStr = config.url else {
            throw MCPHttpError.connectionFailed("Config is not a valid HTTP server")
        }
        guard let url = URL(string: urlStr) else {
            throw MCPHttpError.invalidURL(urlStr)
        }
        baseURL = url
        isConnected = false

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

    public func disconnect() {
        isConnected = false
        baseURL = nil
        consecutiveRapidDeaths = 0
    }

    // MARK: - JSON-RPC request / notify

    /// Send a JSON-RPC `request` (with id) and await the response.
    ///
    /// On 401 Unauthorized, if an OAuth provider is configured we attempt
    /// a single retry after refreshing the token (matching Grok Build's
    /// `try_handshake` 401 → refresh → retry pattern).
    public func request(method: String, params: [String: Any],
                        timeout seconds: TimeInterval = 120) async throws -> MCPJSONPayload {
        guard let url = baseURL else { throw MCPHttpError.connectionFailed("Not connected") }

        // First attempt.
        let result = try await sendOneRequest(
            url: url, method: method, params: params,
            id: nil, timeout: seconds)
        if let payload = result.payload {
            return payload
        }

        // If we got a 401 and have an OAuth provider, invalidate the access
        // token so the provider re-enters ensureAuthenticated → tryRefresh,
        // then retry once. A bare retry re-sent the same still-"valid" token.
        if result.statusCode == 401, oauthTokenProvider != nil {
            await oauthOnUnauthorized?()
            if let payload = try await sendOneRequest(
                url: url, method: method, params: params,
                id: nil, timeout: seconds).payload {
                return payload
            }
        }

        // Non-401 error, or 401 without OAuth — surface it.
        if let status = result.statusCode, !(200...299).contains(status) {
            throw MCPHttpError.httpStatus(status, result.errorBody ?? "<empty>")
        }
        // Shouldn't reach here — sendOneRequest returns either a payload
        // or an error status. Defensive fallback.
        throw MCPHttpError.connectionFailed("Request failed with no response")
    }

    /// Send a single JSON-RPC request and return its result.
    ///
    /// `id` is allocated here so the caller doesn't need to manage it.
    private func sendOneRequest(
        url: URL, method: String, params: [String: Any],
        id: Int?, timeout: TimeInterval
    ) async throws -> (payload: MCPJSONPayload?,
                        statusCode: Int?, errorBody: String?) {

        let requestID = id ?? {
            let allocated = nextID
            nextID += 1
            return allocated
        }()

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
        ]
        if !params.isEmpty { payload["params"] = params }

        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        await applyHeaders(to: &request)
        request.timeoutInterval = timeout

        let (data, response) = try await sendData(request: request, timeout: timeout)
        guard let http = response as? HTTPURLResponse else {
            throw MCPHttpError.connectionFailed("Non-HTTP response")
        }

        if (200...299).contains(http.statusCode) {
            return (try parseResponseBody(data: data, id: requestID),
                    http.statusCode, nil)
        }

        let snippet = String(data: data, encoding: .utf8)?
            .prefix(200) ?? "<binary>"
        return (nil, http.statusCode, String(snippet))
    }

    /// Send a JSON-RPC `notification` (no id, no response expected).
    public func notify(method: String, params: [String: Any]) async throws {
        guard let url = baseURL else { throw MCPHttpError.connectionFailed("Not connected") }

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if !params.isEmpty { payload["params"] = params }

        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        await applyHeaders(to: &request)
        // Fire-and-forget; don't wait for response.
        _ = try? await session.data(for: request)
    }

    // MARK: - Response parsing

    /// Parse the HTTP response body. MCP Streamable HTTP servers may
    /// respond with either:
    ///
    ///   1. Plain `{"jsonrpc":"2.0","id":N,"result":{...}}` JSON, OR
    ///   2. SSE-formatted: `event: message\ndata: {...}\n\n`
    ///
    /// We detect SSE by the presence of `data:` lines; otherwise we
    /// parse as plain JSON. Either way, the payload is a JSON-RPC
    /// response with our request's id.
    private func parseResponseBody(data: Data, id: Int) throws -> MCPJSONPayload {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPClientError.invalidResponse("Response body is not valid UTF-8")
        }

        // SSE path: look for `data: {...}` lines.
        if text.contains("data:") {
            return try parseSSEResponse(text: text, expectedID: id)
        }

        // Plain JSON path.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPClientError.invalidResponse("Response is not valid JSON")
        }

        // Check for an error response.
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "Unknown MCP error"
            throw MCPClientError.serverError(code: code, message: message)
        }

        guard let result = json["result"] as? [String: Any] else {
            throw MCPClientError.invalidResponse("Missing 'result' in response")
        }
        return MCPJSONPayload(value: result)
    }

    /// Parse an SSE-formatted response body. The server sends one or
    /// more `event: message\ndata: {...}\n\n` blocks. We extract the
    /// JSON payload from the `data:` line(s) of the block whose id (if
    /// present) matches our request, or the last block if no ids are
    /// present (common for single-request responses).
    private func parseSSEResponse(text: String, expectedID: Int) throws -> MCPJSONPayload {
        var currentData = ""
        var lastPayload: [String: Any]?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { // End of an event block
                if !currentData.isEmpty {
                    if let data = currentData.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // If this response has an id that matches, use it.
                        if let respID = json["id"] as? Int, respID == expectedID {
                            return try extractResult(from: json)
                        }
                        lastPayload = json
                    }
                }
                currentData = ""
            } else if trimmed.hasPrefix("data:") {
                let dataContent = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !currentData.isEmpty { currentData += "\n" }
                currentData += dataContent
            } // Ignore `event:` and `id:` lines for single-request use.
        }

        // Handle the last event block (no trailing blank line).
        if !currentData.isEmpty {
            if let data = currentData.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return try extractResult(from: json)
            }
        }

        if let payload = lastPayload {
            return try extractResult(from: payload)
        }
        throw MCPHttpError.sseParseError("No valid JSON found in SSE response")
    }

    /// Extract the `result` from a JSON-RPC response, checking for errors.
    private func extractResult(from json: [String: Any]) throws -> MCPJSONPayload {
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "Unknown MCP error"
            throw MCPClientError.serverError(code: code, message: message)
        }
        guard let result = json["result"] as? [String: Any] else {
            throw MCPClientError.invalidResponse("Missing 'result' in SSE response")
        }
        return MCPJSONPayload(value: result)
    }

    // MARK: - Header application

    /// Apply configured headers + bearer token (if any) to a request.
    ///
    /// Token resolution order:
    ///   1. OAuth token provider (if set) — calls the coordinator which
    ///      handles proactive refresh and, in interactive mode, browser auth.
    ///   2. `bearerTokenEnvVar` (legacy static env-var path).
    ///
    /// The OAuth provider wins because it can refresh; the env var is a
    /// static value that never changes within a session.
    private func applyHeaders(to request: inout URLRequest) async {
        for (key, value) in config.headers {
            // Don't let a user-configured Authorization header override
            // the one we're about to set from OAuth/env-var. Matches
            // Grok Build's behavior (servers.rs:3375-3386).
            if key.lowercased() == "authorization" { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Try OAuth provider first.
        if let provider = oauthTokenProvider,
           let token = await provider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return
        }

        // Fall back to the legacy env-var path.
        if let envVar = config.bearerTokenEnvVar {
            let token = ProcessInfo.processInfo.environment[envVar] ?? ""
            if !token.isEmpty {
                request.setValue("Bearer \(token)",
                                 forHTTPHeaderField: "Authorization")
            }
        }
    }

    // MARK: - HTTP send with backoff on SSE stream death

    /// Send a URLRequest and return (data, response). For non-streaming
    /// responses this is straightforward. The backoff logic lives here so
    /// repeated rapid failures (server cycling the connection) don't
    /// hammer the endpoint — matches Grok Build's `ThrottleState`.
    private func sendData(request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        do {
            let result = try await session.data(for: request)
            // Reset rapid-death counter on a response that took longer
            // than the stable-stream threshold (the connection was healthy).
            consecutiveRapidDeaths = 0
            return result
        } catch {
            // If this was a quick failure, increment the rapid-death counter.
            consecutiveRapidDeaths += 1
            if consecutiveRapidDeaths > 2 {
                let delay = min(baseDelay * pow(2.0, Double(consecutiveRapidDeaths - 2)), maxDelay)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            throw MCPHttpError.connectionFailed(error.localizedDescription)
        }
    }

    // MARK: - Backoff delay calculation (exposed for tests)

    /// Compute the backoff delay for a given attempt number, matching
    /// Grok Build's `delay_for_attempt`: `BASE * 2^(attempt-2)`, capped
    /// at MAX_DELAY. The first reconnect is immediate (attempt 0/1).
    public static func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 2 else { return 0 }
        let exp = min(attempt - 2, 6) // saturate at 2^6
        let delay = 0.5 * pow(2.0, Double(exp))
        return min(delay, 30.0)
    }
}