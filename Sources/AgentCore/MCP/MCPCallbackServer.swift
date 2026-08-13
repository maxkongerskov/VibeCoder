//
//  MCPCallbackServer.swift
//
//  A minimal HTTP/1.1 server bound to 127.0.0.1 that receives the OAuth
//  authorization-code callback redirect (`?code=...&state=...`).
//
//  Grok Build uses axum in a Tokio task for this; Swift's equivalent is
//  `NWListener` from Network.framework — Apple's recommended API for TCP
//  servers on macOS/iOS. We implement just enough HTTP to parse the GET
//  request line + query string, extract `code` and `state`, and respond
//  with a friendly "you can close this tab" page.
//
//  Why loopback: the redirect URI is `http://127.0.0.1:{port}/callback`.
//  RFC 8252 §7.3 explicitly authorizes loopback redirects for native apps
//  — the OS prevents other hosts from binding to 127.0.0.1:port, so only
//  our process can receive the callback. This is safer than a remote HTTPS
//  redirect, which would require a registered public URL.
//
//  Lifecycle:
//    1. `start()` — opens the listener, returns the bound port
//    2. Browser navigates to the auth URL; provider redirects back to
//       our loopback server after user consents.
//    3. `waitForCallback()` — awaits the code+state, with a timeout.
//    4. `stop()` — tears down the listener (called on cancel/timeout).
//

import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

/// The parsed OAuth callback: authorization code + state token.
public struct MCPOAuthCallback: Sendable, Equatable {
    public let code: String
    public let state: String

    public init(code: String, state: String) {
        self.code = code
        self.state = state
    }
}

/// Thread-safe box for NWListener start failures (callback may run off-thread).
private final class StartResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _failure: Error?

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return _failure
    }

    func setFailure(_ error: Error) {
        lock.lock()
        _failure = error
        lock.unlock()
    }
}

/// A loopback HTTP server that receives OAuth callbacks.
///
/// Listens on 127.0.0.1 with an OS-assigned ephemeral port (or a fixed
/// port if configured). When a browser redirect arrives at `/callback`,
/// it parses `code` and `state`, signals the waiting coordinator, and
/// responds with a success page.
public final class MCPCallbackServer: @unchecked Sendable {

    /// The redirect URI to send in the authorize URL — `http://127.0.0.1:{port}/callback`.
    public private(set) var redirectURI: String = ""

    /// The actual bound port (0 if not started).
    public private(set) var port: UInt16 = 0

    /// The path the server responds to. Always `/callback`.
    public static let path = "/callback"

    private var listener: NWListener?
    private var continuation: CheckedContinuation<MCPOAuthCallback, Error>?
    private let stateLock = NSLock()
    private var hasReceived = false

    public init() {}

    // MARK: - Lifecycle

    /// Start the server. Returns the redirect URI to use in the authorize
    /// URL. Throws if the listener fails to start (port already in use).
    public func start(preferredPort: UInt16 = 0) throws -> String {
        // If the caller didn't specify a port, find a free ephemeral
        // one using a BSD socket: bind to 127.0.0.1:0, read the
        // assigned port via getsockname, close, then create an NWListener
        // on that specific port. (NWListener with .any doesn't expose
        // its bound endpoint, so we can't discover it that way.)
        let actualPort: UInt16
        if preferredPort == 0 {
            guard let discovered = Self.findFreeLoopbackPort() else {
                throw MCPOAuthError.callbackServerStartFailed(
                    "No free loopback port available")
            }
            actualPort = discovered
        } else {
            actualPort = preferredPort
        }

        guard let endpointPort = NWEndpoint.Port(rawValue: actualPort) else {
            throw MCPOAuthError.callbackServerStartFailed(
                "Invalid port: \(actualPort)")
        }

        // TCP parameters — we want a plain HTTP listener, no TLS.
        // Bind loopback only (RFC 8252 / OAuth redirect safety).
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind loopback only via requiredLocalEndpoint. Do not also pass
        // `on: endpointPort` — specifying the port twice makes NWListener
        // throw POSIXError EINVAL.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: endpointPort)

        let newListener = try NWListener(using: params)
        newListener.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }

        // Wait for the listener to become ready before returning, so
        // we know it's actually listening on the port.
        // Box the failure so the NWListener callback (concurrent) never
        // mutates a captured `var` (Swift 6 concurrency error).
        let startBox = StartResultBox()
        let started = DispatchSemaphore(value: 0)
        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                started.signal()
            case .failed(let error):
                startBox.setFailure(error)
                started.signal()
            default:
                break
            }
        }

        // Use a dedicated queue so we don't block the caller's.
        let queue = DispatchQueue(label: "MCPCallbackServer.listener",
                                  qos: .utility)
        newListener.start(queue: queue)
        self.listener = newListener

        // Wait up to 5 seconds for the listener to become ready.
        if started.wait(timeout: .now() + 5) == .timedOut {
            throw MCPOAuthError.callbackServerStartFailed(
                "NWListener failed to start within 5s")
        }

        if let error = startBox.failure {
            throw MCPOAuthError.callbackServerStartFailed(
                "NWListener failed: \(error.localizedDescription)")
        }

        self.port = actualPort
        self.redirectURI =
            "http://127.0.0.1:\(actualPort)\(Self.path)"

        return redirectURI
    }

    /// Find a free TCP port on 127.0.0.1 by binding a socket to
    /// INADDR_LOOPBACK:0 (ephemeral), reading the assigned port via
    /// getsockname, then closing. This is how Python's `http.server`
    /// discovers a free port — reliable and portable across macOS versions.
    static func findFreeLoopbackPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,
                   &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK)  // 127.0.0.1 in network byte order
        addr.sin_port = 0                        // ephemeral

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        // Read back the actual port.
        var addrOut = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addrOut) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard result == 0 else { return nil }

        // Port is in network byte order — convert to host.
        return UInt16(bigEndian: addrOut.sin_port)
    }

    /// Stop the server and release its resources.
    public func stop() {
        listener?.cancel()
        listener = nil
        // If anyone is awaiting a callback, cancel them with an error.
        stateLock.lock()
        if let cont = continuation {
            self.continuation = nil
            stateLock.unlock()
            cont.resume(throwing: CancellationError())
        } else {
            stateLock.unlock()
        }
    }

    // MARK: - Waiting for the callback

    /// Await the OAuth callback. Resolves with `code` + `state`, or throws
    /// on timeout/cancel.
    public func waitForCallback(timeout: TimeInterval) async throws -> MCPOAuthCallback {
        try await withCheckedThrowingContinuation { cont in
            stateLock.lock()
            self.continuation = cont
            stateLock.unlock()

            // Set up a timeout. If the callback doesn't arrive in time,
            // we cancel the continuation and stop the server.
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    self.stateLock.lock()
                    if !self.hasReceived, let cont = self.continuation {
                        self.continuation = nil
                        self.stateLock.unlock()
                        cont.resume(throwing:
                            MCPOAuthError.tokenExchangeFailed(
                                "OAuth callback timed out after \(Int(timeout))s"))
                    } else {
                        self.stateLock.unlock()
                    }
            }
        }
    }

    // MARK: - Connection handling

    /// Handle a single incoming TCP connection (one HTTP request).
    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))

        // Read the request. We only need the first line (the request
        // target), so 8KB is more than enough for a callback URL.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                connection.cancel()
                _ = error
                return
            }

            guard let data, let text = String(data: data, encoding: .utf8) else {
                self.respond(connection: connection,
                             status: 400, body: "Bad request")
                return
            }

            // Parse the request line (e.g. "GET /callback?code=X&state=Y HTTP/1.1").
            let firstLine = text.split(separator: "\r\n").first
                .map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2,
                  parts[0] == "GET" else {
                self.respond(connection: connection, status: 405,
                             body: "Method not allowed")
                return
            }

            let requestTarget = String(parts[1])
            guard requestTarget.hasPrefix(Self.path) else {
                self.respond(connection: connection, status: 404,
                             body: "Not found")
                return
            }

            // Extract query string.
            let queryString = requestTarget.contains("?")
                ? String(requestTarget.split(separator: "?", maxSplits: 1).last ?? "")
                : ""

            // Parse code and state from the query string.
            let params = self.parseQueryString(queryString)
            guard let code = params["code"],
                  let state = params["state"] else {
                // Missing code or state — this isn't a valid callback.
                self.respond(connection: connection, status: 400,
                             body: "Missing code or state")
                return
            }

            // Respond with a success page.
            let html = """
            <!DOCTYPE html><html><head><meta charset="utf-8">\
            <title>Authorized</title>\
            <style>body{font-family:-apple-system,sans-serif;\
            text-align:center;padding:3rem;color:#333;}\
            h1{color:#34c759;}</style></head>\
            <body><h1>✅ Authorized</h1>\
            <p>You can close this tab and return to VibeCoder.</p>\
            </body></html>
            """
            self.respond(connection: connection, status: 200,
                         body: html)

            // Signal the waiting coordinator.
            self.stateLock.lock()
            if !self.hasReceived, let cont = self.continuation {
                self.hasReceived = true
                self.continuation = nil
                self.stateLock.unlock()
                cont.resume(returning: MCPOAuthCallback(
                    code: code, state: state))
            } else {
                self.stateLock.unlock()
            }
        }
    }

    /// Send an HTTP response and close the connection.
    private func respond(connection: NWConnection, status: Int, body: String) {
        let statusText = (200...299).contains(status) ? "OK" : "Error"
        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(
            content: response.data(using: .utf8),
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }

    /// Parse a URL query string into a dictionary. Handles
    /// `key=value` pairs separated by `&`, with URL-decoding.
    private func parseQueryString(_ qs: String) -> [String: String] {
        var result = [String: String]()
        for pair in qs.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            // URL-decode the value.
            let val = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            result[key] = val
        }
        return result
    }

    deinit { listener?.cancel() }
}