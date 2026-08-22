//
//  RemoteControlServer.swift
//
//  Lightweight LAN remote-control bridge for AgentOS.
//  Phone (QR) or laptop (link) open a tokenized web session that can
//  view the active chat, send messages, and stop the current turn.
//
//  SHUT DOWN (2026-08-20): `isEnabled` is false. `start()` refuses —
//  no bind on 0.0.0.0 / :18765, no session URL. Flip `isEnabled` to
//  restore the previous all-interfaces listener. Pixel hid the sheet
//  in parallel; this gate holds even if UI still calls `start()`.
//
//  Historical: bound all interfaces so LAN phones/laptops could connect.
//  Auth is a long random token in the URL path (optional password cookie).
//

import Foundation
import Network
import Security

// MARK: - Snapshot types (JSON for the web UI)

public struct RemoteMessageDTO: Codable, Sendable {
    public let id: String
    public let role: String
    public let content: String
    public let reasoning: String?

    public init(id: String, role: String, content: String, reasoning: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
    }
}

public struct RemoteSnapshotDTO: Codable, Sendable {
    public let conversationId: String
    public let title: String
    public let isRunning: Bool
    public let status: String
    public let streaming: String
    public let reasoning: String
    public let activity: String?
    public let model: String?
    public let messages: [RemoteMessageDTO]

    public init(
        conversationId: String,
        title: String,
        isRunning: Bool,
        status: String,
        streaming: String,
        reasoning: String,
        activity: String?,
        model: String?,
        messages: [RemoteMessageDTO]
    ) {
        self.conversationId = conversationId
        self.title = title
        self.isRunning = isRunning
        self.status = status
        self.streaming = streaming
        self.reasoning = reasoning
        self.activity = activity
        self.model = model
        self.messages = messages
    }
}

/// Host app supplies the live session. Called on the main actor.
public protocol RemoteControlHost: AnyObject {
    @MainActor func remoteControlSnapshot() -> RemoteSnapshotDTO?
    @MainActor func remoteControlSend(_ text: String)
    @MainActor func remoteControlStop()
}

// MARK: - Server

public actor RemoteControlServer {

    public static let shared = RemoteControlServer()

    /// LAN remote control is off. Set `true` to restore `start()` binding
    /// on all interfaces (default port 18765). Leave false: `start()`
    /// throws `.disabled` and never publishes a session URL.
    public static let isEnabled = false

    private var listener: NWListener?
    private var port: Int = 18765
    private var token: String?
    private var expiresAt: Date?
    private weak var host: (any RemoteControlHost)?

    /// Continuations waiting for SSE push (v1: we still poll-friendly; SSE sends heartbeats + state).
    private var eventClients: [UUID: NWConnection] = [:]

    public init() {}

    public enum ServerError: Error, LocalizedError, Equatable {
        case invalidPort(Int)
        case alreadyRunning
        case disabled
        public var errorDescription: String? {
            switch self {
            case .invalidPort(let p): return "Invalid port: \(p)"
            case .alreadyRunning: return "Remote control is already running"
            case .disabled: return "Remote control is turned off."
            }
        }
    }

    // MARK: - Lifecycle

    public func isRunning() -> Bool { listener != nil }

    public func currentPort() -> Int { port }

    public func currentToken() -> String? {
        guard let token, let exp = expiresAt, exp > Date() else { return nil }
        return token
    }

    public func sessionURL(hostAddress: String) -> URL? {
        guard let token = currentToken() else { return nil }
        return URL(string: "http://\(hostAddress):\(port)/s/\(token)/")
    }

    public func attachHost(_ host: any RemoteControlHost) {
        self.host = host
    }

    /// Start (or restart) remote control with a fresh token.
    /// - Parameters:
    ///   - port: TCP port (default 18765)
    ///   - lifetime: token validity
    /// - Throws: `.disabled` while `isEnabled` is false (no bind, no token).
    @discardableResult
    public func start(port: Int = 18765, lifetime: TimeInterval = 3600) throws -> String {
        // Fail-closed: do not bind any interface or publish a session URL.
        // Tear down a leftover listener if one exists (should not in a
        // fresh process). UI may still call this after Pixel hides the sheet.
        guard Self.isEnabled else {
            if listener != nil {
                stop()
            } else {
                token = nil
                expiresAt = nil
            }
            throw ServerError.disabled
        }
        // Validate before tearing down a live listener — `start(port: 0)`
        // must not kill a running session or replace its token.
        guard port > 0, port <= 65_535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ServerError.invalidPort(port)
        }
        if listener != nil { stop() }
        self.port = port
        let newToken = Self.makeToken()
        self.token = newToken
        self.expiresAt = Date().addingTimeInterval(lifetime)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // All interfaces — LAN phones/laptops need this (unlike LocalAPIServer).
        let newListener = try NWListener(using: params, on: nwPort)
        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Diagnostics.info("RemoteControlServer ready on :\(port)")
            case .failed(let err):
                Diagnostics.error("RemoteControlServer failed: \(err.localizedDescription)")
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            Task { [weak self] in
                await self?.handle(connection: connection)
            }
        }
        newListener.start(queue: .global(qos: .userInitiated))
        self.listener = newListener
        return newToken
    }

    public func stop() {
        for (_, c) in eventClients { c.cancel() }
        eventClients.removeAll()
        listener?.cancel()
        listener = nil
        token = nil
        expiresAt = nil
        Diagnostics.info("RemoteControlServer stopped")
    }

    public func revoke() {
        stop()
        // Invalidate all existing session cookies.
        RemoteAccessPasswordStore.shared.rotateSessionSecret()
    }

    // MARK: - Connection

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        Task { [weak self] in
            await self?.serve(connection: connection)
        }
    }

    private func serve(connection: NWConnection) async {
        guard let request = await readHTTPRequest(connection: connection) else {
            connection.cancel()
            return
        }
        let path = request.path
        let method = request.method.uppercased()

        // Health
        if path == "/health" || path == "/healthz" {
            await writeResponse(connection, status: 200, contentType: "text/plain", body: Data("ok".utf8))
            connection.cancel()
            return
        }

        // Session routes: /s/<token>/...
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "s" else {
            await writeResponse(connection, status: 404, contentType: "text/plain", body: Data("not found".utf8))
            connection.cancel()
            return
        }
        let pathToken = parts[1]
        guard validateToken(pathToken) else {
            await writeResponse(connection, status: 401, contentType: "text/plain",
                                body: Data("invalid or expired session".utf8))
            connection.cancel()
            return
        }

        let rest = parts.dropFirst(2).joined(separator: "/")

        // ── Password auth gate (only enforced when a password is set) ──

        // Read the session cookie from the request (Cookie: header).
        let cookieHeader = Self._readRequestHeader(request, for: "cookie")
        let sessionCookie = Self._extractSessionCookie(cookieHeader)

        // Whether a password is configured on disk.
        let hasPassword = RemoteAccessPasswordStore.shared.isSet()

        // Determine if the request carries a valid session cookie.
        let hasValidCookie: Bool = {
            guard hasPassword, let sessionCookie else { return false }
            return RemoteAccessPasswordStore.shared.validateSessionCookie(sessionCookie)
        }()

        // API auth: authenticated if no password is set, or cookie validates.
        let isAPIAuthorized = !hasPassword || hasValidCookie

        switch (method, rest) {

        // ── Login / logout routes (always accessible after token check) ──

        case ("POST", "api/login"):
            await self.handleLogin(request: request, connection: connection)

        case ("POST", "api/logout"):
            await self.handleLogout(connection: connection, pathToken: pathToken)

        // ── Main page: render login form or chat UI depending on auth state ──

        case ("GET", ""), ("GET", "index.html"):
            if hasPassword, !hasValidCookie {
                // Render the login form.
                let html = Self.loginPageHTML(tokenPath: "s/\(pathToken)/")
                await writeResponse(connection, status: 200, contentType: "text/html; charset=utf-8",
                                    body: Data(html.utf8))
            } else {
                await writeResponse(connection, status: 200, contentType: "text/html; charset=utf-8",
                                    body: Data(Self.htmlPage.utf8))
            }

        // ── Authenticated API routes ──

        case ("GET", "api/state"):
            guard isAPIAuthorized else {
                await writeResponse(connection, status: 401, contentType: "application/json",
                                    body: Data(#"{"error":"unauthorized"}"#.utf8))
                break
            }
            let json = await snapshotJSON()
            await writeResponse(connection, status: 200, contentType: "application/json", body: json)

        case ("POST", "api/message"):
            guard isAPIAuthorized else {
                await writeResponse(connection, status: 401, contentType: "application/json",
                                    body: Data(#"{"error":"unauthorized"}"#.utf8))
                break
            }
            let text = Self.parseJSONText(request.body) ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await writeResponse(connection, status: 400, contentType: "application/json",
                                    body: Data(#"{"ok":false,"error":"empty"}"#.utf8))
            } else {
                // Box host so MainActor.run's @Sendable closure doesn't
                // capture a non-Sendable existential (Swift 6).
                let hostBox = HostBox(host)
                await MainActor.run { hostBox.value?.remoteControlSend(text) }
                await writeResponse(connection, status: 200, contentType: "application/json",
                                    body: Data(#"{"ok":true}"#.utf8))
            }

        case ("POST", "api/stop"):
            guard isAPIAuthorized else {
                await writeResponse(connection, status: 401, contentType: "application/json",
                                    body: Data(#"{"error":"unauthorized"}"#.utf8))
                break
            }
            let hostBox = HostBox(host)
            await MainActor.run { hostBox.value?.remoteControlStop() }
            await writeResponse(connection, status: 200, contentType: "application/json",
                                body: Data(#"{"ok":true}"#.utf8))

        case ("GET", "api/events"):
            guard isAPIAuthorized else {
                await writeResponse(connection, status: 401, contentType: "application/json",
                                    body: Data(#"{"error":"unauthorized"}"#.utf8))
                break
            }
            // Long-lived SSE: poll host snapshot every 400ms
            await streamSSE(connection: connection)
            return // connection closed inside streamSSE

        default:
            await writeResponse(connection, status: 404, contentType: "text/plain", body: Data("not found".utf8))
        }
        connection.cancel()
    }

    private func validateToken(_ t: String) -> Bool {
        guard let token, let exp = expiresAt, exp > Date() else { return false }
        return t == token
    }

    private func snapshotJSON() async -> Data {
        let hostBox = HostBox(host)
        let snap = await MainActor.run { hostBox.value?.remoteControlSnapshot() }
        let enc = JSONEncoder()
        if let snap, let data = try? enc.encode(snap) { return data }
        return Data(#"{"error":"no active conversation"}"#.utf8)
    }

    // MARK: - SSE

    private func streamSSE(connection: NWConnection) async {
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Connection: keep-alive\r
        Access-Control-Allow-Origin: *\r
        \r

        """
        await writeRaw(connection, Data(headers.utf8))

        var lastPayload = ""
        for _ in 0..<(15 * 60) { // ~15 min at 1s if we used 1s; we use 0.4s → cap loops
            if Task.isCancelled { break }
            let data = await snapshotJSON()
            let payload = String(data: data, encoding: .utf8) ?? "{}"
            if payload != lastPayload {
                lastPayload = payload
                let frame = "event: state\ndata: \(payload)\n\n"
                let ok = await writeRaw(connection, Data(frame.utf8))
                if !ok { break }
            } else {
                // heartbeat
                let ok = await writeRaw(connection, Data(": ping\n\n".utf8))
                if !ok { break }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        connection.cancel()
    }

    // MARK: - HTTP helpers

    private struct HTTPRequest {
        var method: String
        var path: String
        var body: Data
        var headers: [String: String] = [:]
    }

    private func readHTTPRequest(connection: NWConnection) async -> HTTPRequest? {
        var buffer = Data()
        // Read until headers complete, then body by Content-Length
        while buffer.count < 1024 * 1024 {
            guard let chunk = await receive(connection) else { break }
            buffer.append(chunk)
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
                let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
                guard let requestLine = lines.first else { return nil }
                let rl = requestLine.split(separator: " ")
                guard rl.count >= 2 else { return nil }
                let method = String(rl[0])
                var path = String(rl[1])
                if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }

                var contentLength = 0
                var headers = [String: String]()
                for line in lines.dropFirst() {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        let v = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                        contentLength = Int(v) ?? 0
                    }
                    // Store all headers (lowercased key for case-insensitive lookup).
                    if let colon = line.firstIndex(of: ":") {
                        let colonIdx = line.index(after: colon)
                        // `index(after:)` is always valid when `colon` is not the last index.
                        guard colonIdx <= line.endIndex else { continue }
                        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                        let value = colonIdx == line.endIndex ? "" : String(line[colonIdx...]).trimmingCharacters(in: .whitespaces)
                        if !key.isEmpty { headers[key] = value }
                    }
                }
                var body = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                while body.count < contentLength {
                    guard let more = await receive(connection) else { break }
                    body.append(more)
                }
                if body.count > contentLength {
                    body = body.prefix(contentLength)
                }
                return HTTPRequest(method: method, path: path, body: body, headers: headers)
            }
            if buffer.count > 64 * 1024 { break }
        }
        return nil
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete || error != nil {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    private func writeResponse(_ connection: NWConnection, status: Int, contentType: String, body: Data) async {
        let reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : "Error"
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r

        """
        var data = Data(header.utf8)
        data.append(body)
        _ = await writeRaw(connection, data)
    }

    @discardableResult
    private func writeRaw(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { cont in
            connection.send(content: data, completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }

    private static func parseJSONText(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        return obj["text"] as? String ?? obj["message"] as? String
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cookie / session helpers

    /// Extract the raw value of a named header from the parsed request headers.
    private static func _readRequestHeader(_ request: HTTPRequest, for name: String) -> String? {
        return request.headers[name.lowercased()]
    }

    /// Parse the `Cookie` header and extract a single named cookie value.
    /// Looks for `agentos_remote_session=<value>`.
    private static func _extractSessionCookie(_ header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let idx = trimmed.firstIndex(of: "=")
            let afterIdx = idx.map { trimmed.index(after: $0) }
            guard let idx, let afterIdx, afterIdx <= trimmed.endIndex else { continue }
            let key = String(trimmed[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = afterIdx == trimmed.endIndex ? "" : String(trimmed[afterIdx...]).trimmingCharacters(in: .whitespaces)
            if key == "agentos_remote_session" { return value }
        }
        return nil
    }

    // MARK: - Login / logout handlers

    /// Handle POST /api/login — verifies password and issues a session cookie.
    private func handleLogin(request: HTTPRequest, connection: NWConnection) async {
        let store = RemoteAccessPasswordStore.shared

        // Parse the password from the JSON body.
        guard let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let password = obj["password"] as? String else {
            await writeResponse(connection, status: 400, contentType: "application/json",
                                body: Data(#"{"ok":false,"error":"bad request"}"#.utf8))
            return
        }

        // Verify the password before issuing a cookie.
        guard store.verify(password) else {
            await writeResponse(connection, status: 401, contentType: "application/json",
                                body: Data(#"{"ok":false,"error":"unauthorized"}"#.utf8))
            return
        }

        let cookie = store.issueSessionCookie(expiresAt: Date().addingTimeInterval(3600))
        // Full Set-Cookie header line (must include the header name).
        let setCookie = "Set-Cookie: agentos_remote_session=\(cookie); HttpOnly; Path=/; SameSite=Lax"
        let bodyData = Data(#"{"ok":true}"#.utf8)
        await writeResponseWithHeaders(connection, status: 200, contentType: "application/json",
                                       extraHeaders: [setCookie], body: bodyData)
    }

    /// Handle POST /api/logout — redirect to clear the session cookie.
    private func handleLogout(connection: NWConnection, pathToken: String) async {
        // Stay under the session path so the browser can re-show the login form.
        let location = "/s/\(pathToken)/"
        let cookieValue = "agentos_remote_session=; HttpOnly; Path=/; Max-Age=0"
        let locationHeader = "Location: \(location)"
        let response = """
        HTTP/1.1 302 Found\r
        \(locationHeader)\r
        Set-Cookie: \(cookieValue)\r
        Content-Length: 0\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r

        """
        await writeRaw(connection, Data(response.utf8))
    }

    private func writeResponseWithHeaders(_ connection: NWConnection, status: Int, contentType: String,
                                          extraHeaders: [String], body: Data) async {
        let reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : "Error"
        var headerLines = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Access-Control-Allow-Origin: *\r
        """
        for extra in extraHeaders {
            headerLines.append("\r\n\(extra)")
        }
        headerLines.append("\r\nConnection: close\r\n\r\n")

        var data = Data(headerLines.utf8)
        data.append(body)
        _ = await writeRaw(connection, data)
    }

    // MARK: - Login page

    private static let htmlPage: String = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"/>
<title>AgentOS Remote</title>
<style>
  :root {
    --bg: #1c1c1e; --card: #2c2c2e; --text: #f5f5f7; --muted: #98989f;
    --accent: #3385f2; --user: rgba(255,255,255,0.08); --border: rgba(255,255,255,0.08);
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    background: var(--bg); color: var(--text); min-height: 100dvh;
    display: flex; flex-direction: column;
  }
  header {
    padding: 12px 16px; border-bottom: 1px solid var(--border);
    display: flex; align-items: center; gap: 10px; position: sticky; top: 0;
    background: rgba(28,28,30,0.92); backdrop-filter: blur(12px); z-index: 2;
  }
  header h1 { font-size: 15px; font-weight: 600; margin: 0; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .pill {
    font-size: 11px; color: var(--muted); background: var(--card);
    padding: 4px 8px; border-radius: 999px;
  }
  .pill.live { color: #34c759; }
  #log {
    flex: 1; overflow-y: auto; padding: 16px; display: flex; flex-direction: column; gap: 14px;
  }
  .msg { max-width: 920px; width: 100%; margin: 0 auto; }
  .msg.user { display: flex; justify-content: flex-end; }
  .msg.user .bubble {
    background: var(--user); border-radius: 16px; padding: 10px 14px;
    max-width: min(420px, 88%); font-size: 15px; line-height: 1.45;
  }
  .msg.assistant .bubble {
    font-size: 15px; line-height: 1.5; white-space: pre-wrap; word-break: break-word;
  }
  .thinking {
    font-size: 13px; color: var(--muted); margin-bottom: 8px;
  }
  .activity { font-size: 13px; color: var(--accent); margin-bottom: 6px; }
  .status { font-size: 12px; color: var(--muted); text-align: center; padding: 4px; }
  footer {
    border-top: 1px solid var(--border); padding: 10px 12px calc(10px + env(safe-area-inset-bottom));
    background: rgba(28,28,30,0.96); display: flex; gap: 8px; align-items: flex-end;
  }
  textarea {
    flex: 1; resize: none; min-height: 44px; max-height: 120px;
    border-radius: 14px; border: 1px solid var(--border); background: var(--card);
    color: var(--text); padding: 12px 14px; font-size: 16px; font-family: inherit;
  }
  button {
    border: 0; border-radius: 12px; height: 44px; padding: 0 16px;
    font-size: 15px; font-weight: 600; cursor: pointer;
  }
  #send { background: var(--accent); color: white; }
  #stop { background: var(--card); color: var(--text); }
  #send:disabled { opacity: 0.4; }
  .err { color: #ff6b6b; font-size: 13px; padding: 8px 16px; }
</style>
</head>
<body>
  <header>
    <h1 id="title">AgentOS Remote</h1>
    <span class="pill" id="model"></span>
    <span class="pill" id="live">Idle</span>
  </header>
  <div class="status" id="status"></div>
  <div id="log"></div>
  <div class="err" id="err" hidden></div>
  <footer>
    <button id="stop" type="button" title="Stop">■</button>
    <textarea id="input" rows="1" placeholder="Message AgentOS…"></textarea>
    <button id="send" type="button">Send</button>
  </footer>
<script>
const base = location.pathname.replace(/\/?$/, '/');
const log = document.getElementById('log');
const input = document.getElementById('input');
const sendBtn = document.getElementById('send');
const stopBtn = document.getElementById('stop');
const titleEl = document.getElementById('title');
const liveEl = document.getElementById('live');
const modelEl = document.getElementById('model');
const statusEl = document.getElementById('status');
const errEl = document.getElementById('err');

function esc(s) {
  return (s || '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function render(state) {
  if (!state || state.error) {
    errEl.hidden = false;
    errEl.textContent = (state && state.error) || 'No active conversation on the Mac. Open a chat in AgentOS.';
    return;
  }
  errEl.hidden = true;
  titleEl.textContent = state.title || 'AgentOS Remote';
  modelEl.textContent = state.model || '';
  liveEl.textContent = state.isRunning ? 'Working' : 'Idle';
  liveEl.className = 'pill' + (state.isRunning ? ' live' : '');
  statusEl.textContent = state.status || '';

  const parts = [];
  for (const m of (state.messages || [])) {
    if (m.role === 'user') {
      parts.push(`<div class="msg user"><div class="bubble">${esc(m.content)}</div></div>`);
    } else if (m.role === 'assistant') {
      let inner = '';
      if (m.reasoning) inner += `<div class="thinking">Thought…</div>`;
      inner += `<div class="bubble">${esc(m.content)}</div>`;
      parts.push(`<div class="msg assistant">${inner}</div>`);
    }
  }
  if (state.isRunning) {
    let live = '';
    if (state.reasoning) live += `<div class="thinking">Thinking…</div>`;
    if (state.activity) live += `<div class="activity">${esc(state.activity)}</div>`;
    if (state.streaming) live += `<div class="bubble">${esc(state.streaming)}</div>`;
    if (!state.streaming && !state.activity && !state.reasoning) live += `<div class="thinking">Working…</div>`;
    parts.push(`<div class="msg assistant">${live}</div>`);
  }
  log.innerHTML = parts.join('');
  log.scrollTop = log.scrollHeight;
  sendBtn.disabled = false;
}

async function fetchState() {
  try {
    const r = await fetch(base + 'api/state');
    const j = await r.json();
    render(j);
  } catch (e) {
    errEl.hidden = false;
    errEl.textContent = 'Disconnected from AgentOS host.';
  }
}

function connectSSE() {
  try {
    const es = new EventSource(base + 'api/events');
    es.addEventListener('state', (ev) => {
      try { render(JSON.parse(ev.data)); } catch (_) {}
    });
    es.onerror = () => { /* fall back to poll */ };
  } catch (_) {}
  setInterval(fetchState, 2000);
}

sendBtn.onclick = async () => {
  const text = input.value.trim();
  if (!text) return;
  sendBtn.disabled = true;
  input.value = '';
  try {
    await fetch(base + 'api/message', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text })
    });
  } catch (_) {}
  fetchState();
};

stopBtn.onclick = async () => {
  try {
    await fetch(base + 'api/stop', { method: 'POST' });
  } catch (_) {}
  fetchState();
};

input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendBtn.click();
  }
});

fetchState();
connectSSE();
</script>
</body>
</html>
"""#

    // MARK: - Login page

    /// Generate the login page HTML for a given token path.
    private static func loginPageHTML(tokenPath: String) -> String {
        // Absolute path under the session token so relative resolution cannot double-prefix.
        let sessionRoot = "/" + tokenPath  // e.g. /s/<token>/
        let loginURL = sessionRoot + "api/login"
        // Extended raw string (#""") needs \#(…) for interpolation.
        return #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"/>
<title>AgentOS Remote — Sign in</title>
<style>
  :root { --bg: #1c1c1e; --card: #2c2c2e; --text: #f5f5f7; --muted: #98989f;
          --accent: #3385f2; --border: rgba(255,255,255,0.08); --error: #ff6b6b; }
  * { box-sizing: border-box; }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         background: var(--bg); color: var(--text); min-height: 100dvh;
         display: flex; align-items: center; justify-content: center; }
  .card { width: min(360px, 90vw); background: var(--card); border-radius: 16px;
          padding: 32px 24px; border: 1px solid var(--border); }
  h1 { font-size: 18px; font-weight: 600; text-align: center; margin: 0 0 4px; }
  .sub { font-size: 13px; color: var(--muted); text-align: center; margin-bottom: 24px; }
  input[type="password"] { width: 100%; border-radius: 12px; border: 1px solid var(--border);
    background: rgba(255,255,255,0.06); color: var(--text); padding: 12px 14px;
    font-size: 16px; font-family: inherit; outline: none; }
  input[type="password"]:focus { border-color: var(--accent); }
  button { width: 100%; margin-top: 16px; border: 0; border-radius: 12px; height: 44px;
           font-size: 15px; font-weight: 600; cursor: pointer; background: var(--accent);
           color: white; }
  button:disabled { opacity: 0.4; cursor: default; }
  .err { color: var(--error); font-size: 13px; text-align: center; margin-top: 12px; min-height: 18px; }
</style>
</head>
<body>
<div class="card">
  <h1>AgentOS Remote</h1>
  <p class="sub">Enter the password for this AgentOS session.</p>
  <form id="f" action="\#(loginURL)" method="post">
    <input type="password" id="pw" name="password" placeholder="Password" autocomplete="current-password" autofocus/>
  </form>
  <button type="submit" form="f" id="btn">Sign in</button>
  <div class="err" id="err"></div>
</div>
<script>
const f = document.getElementById('f');
const pw = document.getElementById('pw');
const err = document.getElementById('err');
const btn = document.getElementById('btn');
const sessionHome = '\#(sessionRoot)';

f.onsubmit = async (e) => {
  e.preventDefault();
  const p = pw.value;
  if (!p) return;
  btn.disabled = true;
  try {
    const r = await fetch(f.action, { method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ password: p }) });
    if (r.ok) { location.href = sessionHome; }
    else { err.textContent = 'Wrong password. Please try again.'; btn.disabled = false; }
  } catch (_) { err.textContent = 'Could not reach AgentOS. Is it running?'; btn.disabled = false; }
};

pw.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); f.dispatchEvent(new Event('submit')); } });
</script>
</body>
</html>
"""#
    }

    /// Unchecked Sendable box for hopping a weak host ref onto MainActor.
    private struct HostBox: @unchecked Sendable {
        weak var value: (any RemoteControlHost)?
        init(_ host: (any RemoteControlHost)?) { self.value = host }
    }

    // MARK: - Password management (public API)

    /// Whether a password is currently configured.
    public func passwordIsSet() async -> Bool {
        RemoteAccessPasswordStore.shared.isSet()
    }

    /// Set a new password. Throws on too-short passwords or store write failures.
    public func setPassword(_ password: String) async throws {
        try RemoteAccessPasswordStore.shared.setPassword(password)
    }

    /// Clear the password (removes from disk). Use with caution.
    public func clearPassword() async {
        RemoteAccessPasswordStore.shared.clear()
    }
}
