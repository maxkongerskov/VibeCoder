//
//  MCPOAuthCoordinator.swift
//
//  Coordinates the OAuth flow for MCP HTTP servers, ported from Grok
//  Build's `oauth.rs` and rmcp's `AuthorizationManager`. Implements the
//  full Authorization Code + PKCE flow with:
//
//    - Browser-based user consent (system browser via NSWorkspace)
//    - Loopback callback server for the redirect
//    - Token exchange (code → access + refresh)
//    - Proactive token refresh (30s before expiry, matching Grok's
//      `REFRESH_BUFFER_SECS`)
//    - Cross-process dedup (flock + in-memory task map) so multiple
//      VibeCoder instances don't each open a browser tab for the same server
//
//  Two dedup layers (mirrors Grok Build's design):
//
//    Layer 1 — Cross-process (`flock`): the second VibeCoder process to
//      need auth for "github" waits on a flock. When the first process
//      finishes, it writes the token to disk; the second reads that fresh
//      token and skips its own browser flow.
//
//    Layer 2 — In-process (task map): two agent turns within the same
//      process that both need auth for "github" share a single in-flight
//      task. The second turn awaits the first's result instead of
//      opening a second browser tab.
//
//  Token storage: file-based via `MCPTokenStore`, keyed by
//  `"serverName:serverURL"`. Atomic writes with 0600 perms (see
//  MCPTokenStore.swift for the security rationale).
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// OAuth configuration for a single MCP server.
///
/// Stored alongside `MCPServerConfig` (it's the server-definition part
/// that changes per-provider: GitHub, Slack, etc. all have different
/// authorize/token URLs and client IDs).
public struct MCPOAuthConfig: Codable, Sendable, Equatable {
    /// Client ID registered with the authorization server.
    public var clientID: String
    /// Authorization endpoint URL (where the browser goes for consent).
    public var authorizationURL: String
    /// Token endpoint URL (where we exchange the code for tokens).
    public var tokenURL: String
    /// OAuth scopes to request, space-separated (e.g. "repo issues").
    public var scopes: [String]
    /// Optional client secret (for confidential clients). Most MCP
    /// servers use public clients (native apps) where this is nil.
    public var clientSecret: String?
    /// Optional fixed callback port. If nil, an ephemeral port is used.
    public var callbackPort: UInt16?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case authorizationURL = "authorization_url"
        case tokenURL = "token_url"
        case scopes
        case clientSecret = "client_secret"
        case callbackPort = "callback_port"
    }

    public init(clientID: String,
                authorizationURL: String,
                tokenURL: String,
                scopes: [String] = [],
                clientSecret: String? = nil,
                callbackPort: UInt16? = nil) {
        self.clientID = clientID
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.scopes = scopes
        self.clientSecret = clientSecret
        self.callbackPort = callbackPort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.clientID = try c.decode(String.self, forKey: .clientID)
        self.authorizationURL = try c.decode(String.self, forKey: .authorizationURL)
        self.tokenURL = try c.decode(String.self, forKey: .tokenURL)
        self.scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        self.clientSecret = try c.decodeIfPresent(String.self, forKey: .clientSecret)
        self.callbackPort = try c.decodeIfPresent(UInt16.self, forKey: .callbackPort)
    }
}

/// The OAuth coordinator. One instance is shared across all MCP HTTP
/// connections in the process, so in-process dedup works.
public final class MCPOAuthCoordinator: @unchecked Sendable {

    /// Shared singleton. VibeCoder uses one process-wide coordinator so
    /// all MCP servers benefit from the in-process dedup layer.
    public static let shared = MCPOAuthCoordinator()

    /// Token store — file-based, keyed by "serverName:serverURL".
    public let tokenStore = MCPTokenStore.shared

    /// In-flight auth tasks, keyed by server name. Layer 2 dedup:
    /// if task A starts the browser flow for "github" and task B also
    /// needs it, B awaits A's result instead of opening a second tab.
    private var inFlight: [String: Task<Void, Error>] = [:]
    private let inFlightLock = NSLock()

    /// URL session for token exchange requests (POST to token endpoint).
    private let session: URLSession

    public init() {
        self.session = URLSession(configuration: .ephemeral)
    }

    // MARK: - Public API

    /// Ensure we have a valid access token for the given server, refreshing
    /// if possible and prompting for browser auth as a last resort.
    ///
    /// Returns the access token, or nil if no credentials exist and the
    /// caller didn't request an interactive flow.
    ///
    /// - Parameters:
    ///   - serverName: The MCP server name (e.g. "github").
    ///   - serverURL: The base URL of the MCP server (for keying).
    ///   - config: OAuth configuration (client ID, URLs, scopes).
    ///   - interactive: Whether to open a browser if no token exists.
    ///     Non-interactive callers (e.g. headless mode) get `nil` instead
    ///     of a browser — matching Grok Build's `NeedsInteractiveLogin`.
    public func ensureAuthenticated(
        serverName: String,
        serverURL: String,
        config: MCPOAuthConfig,
        interactive: Bool
    ) async throws -> String? {

        let key = tokenKey(serverName: serverName, serverURL: serverURL)

        // 1. Try to load + refresh existing credentials.
        if let cred = tokenStore.load(key: key) {
            // Proactive refresh — 30s buffer before expiry, matching
            // Grok's REFRESH_BUFFER_SECS.
            if !cred.isExpired() {
                return cred.accessToken
            }
            // Try refresh first (no browser needed).
            if let refreshed = await tryRefresh(
                key: key, cred: cred, config: config) {
                return refreshed
            }
            // Refresh failed — fall through to browser flow.
        }

        guard interactive else { return nil }

        // 2. In-process dedup: if another task is already authenticating
        //    this server, wait for its result and read the token from disk.
        if let existing = inFlightTask(for: serverName) {
            _ = try? await existing.value
            // Another task just finished auth — read its token.
            if let cred = tokenStore.load(key: key), !cred.isExpired() {
                return cred.accessToken
            }
        }

        // 3. Run the interactive auth flow under a task so other callers
        //    can await it (Layer 2 dedup).
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.runInteractiveFlow(
                serverName: serverName,
                key: key,
                config: config
            )
        }
        registerInFlight(serverName: serverName, task: task)

        do {
            try await task.value
        } catch {
            unregisterInFlight(serverName: serverName)
            throw error
        }
        unregisterInFlight(serverName: serverName)

        // Read the token the flow just wrote.
        if let cred = tokenStore.load(key: key), !cred.isExpired() {
            return cred.accessToken
        }
        return nil
    }

    /// Sign out of a server — clear its stored credentials.
    public func signOut(serverName: String, serverURL: String) {
        let key = tokenKey(serverName: serverName, serverURL: serverURL)
        tokenStore.clear(key: key)
    }

    /// Whether a server has a usable OAuth session (for UI status display).
    ///
    /// True when credentials exist and either the access token is still
    /// valid (no buffer) or a refresh token is present so we can renew.
    /// Dead credentials (expired access, no refresh) return false so the
    /// settings UI does not show "Signed in" for unusable sessions.
    public func isAuthenticated(serverName: String, serverURL: String) -> Bool {
        let key = tokenKey(serverName: serverName, serverURL: serverURL)
        guard let cred = tokenStore.load(key: key) else { return false }
        if !cred.isExpired(refreshBuffer: 0) { return true }
        return cred.refreshToken != nil
    }

    /// Force the next `ensureAuthenticated` / tokenProvider call to treat
    /// the access token as expired so a refresh is attempted (used on HTTP 401).
    public func invalidateAccessToken(serverName: String, serverURL: String) {
        let key = tokenKey(serverName: serverName, serverURL: serverURL)
        guard var cred = tokenStore.load(key: key) else { return }
        // Past expiry → isExpired() true → tryRefresh path on next ensure.
        cred.expiresAt = Date().timeIntervalSince1970 - 1
        tokenStore.save(key: key, credential: cred)
    }

    /// Force a fresh interactive flow (user clicked "Re-authenticate").
    public func forceReauthenticate(
        serverName: String,
        serverURL: String,
        config: MCPOAuthConfig
    ) async -> Bool {
        // Clear existing credentials first.
        signOut(serverName: serverName, serverURL: serverURL)
        return (try? await ensureAuthenticated(
            serverName: serverName,
            serverURL: serverURL,
            config: config,
            interactive: true
        )) != nil
    }

    /// Build a closure that returns a valid access token for this server,
    /// refreshing if necessary. The HTTP client calls this on each request.
    ///
    /// Non-interactive — if no token exists, returns nil (the caller
    /// decides whether to trigger an interactive flow). This matches Grok
    /// Build's "fail closed in non-interactive mode" pattern.
    public func tokenProvider(
        serverName: String,
        serverURL: String,
        config: MCPOAuthConfig
    ) -> @Sendable () async -> String? {
        { [weak self] in
            guard let self else { return nil }
            // Non-interactive — swallow errors and return nil so the
            // HTTP request goes out without a token (server will 401).
            return try? await self.ensureAuthenticated(
                serverName: serverName,
                serverURL: serverURL,
                config: config,
                interactive: false
            )
        }
    }

    // MARK: - Interactive flow (browser + callback)

    /// Run the full Authorization Code + PKCE flow:
    ///
    ///   1. Start a loopback callback server.
    ///   2. Build the authorize URL with PKCE + state.
    ///   3. Open it in the system browser.
    ///   4. Wait for the callback (with timeout).
    ///   5. Exchange the code for tokens.
    ///
    /// All under a cross-process lock so concurrent VibeCoder processes
    /// don't each open a browser tab for the same server.
    private func runInteractiveFlow(
        serverName: String,
        key: String,
        config: MCPOAuthConfig
    ) async throws {

        // Cross-process lock — Layer 1 dedup. If another VibeCoder
        // process is already authenticating this server, we wait for its
        // lock. When it releases, we re-read the token from disk — if a
        // fresh one appeared, reuse it and skip our own browser flow.
        let lock = MCPCrossProcessLock(serverName: serverName)

        try await lock.withLock {
            // Token-before snapshot (Grok's "did another process write
            // while we waited?" check).
            if let before = self.tokenStore.load(key: key), !before.isExpired() {
                // Another process authenticated while we waited for the
                // lock. Reuse their token — no browser needed.
                return
            }

            // Run the flow: PKCE → authorize URL → browser → callback.
            let pkce = MCPPKCEPair.generate()
            let state = generateStateToken()

            // Start the callback server.
            let callbackServer = MCPCallbackServer()
            let redirectURI = try callbackServer.start(
                preferredPort: config.callbackPort ?? 0)

            defer { callbackServer.stop() }

            // Build the authorize URL.
            var components = URLComponents(string: config.authorizationURL)
            var queryItems = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: config.clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: pkce.challenge),
                URLQueryItem(name: "code_challenge_method",
                             value: MCPPKCEPair.method),
            ]
            if !config.scopes.isEmpty {
                queryItems.append(URLQueryItem(
                    name: "scope", value: config.scopes.joined(separator: " ")))
            }
            components?.queryItems = queryItems

            guard let authURL = components?.url else {
                throw MCPOAuthError.tokenExchangeFailed(
                    "Invalid authorization URL: \(config.authorizationURL)")
            }

            // Open the system browser.
            await self.openInBrowser(url: authURL)

            // Wait for the callback (5-minute timeout — user might be
            // completing a multi-step consent flow).
            let callback = try await callbackServer.waitForCallback(
                timeout: 300)

            // Validate state (CSRF protection).
            guard callback.state == state else {
                throw MCPOAuthError.tokenExchangeFailed(
                    "State mismatch — possible CSRF attack. " +
                    "Expected \(state.prefix(8))…, got \(callback.state.prefix(8))…")
            }

            // Exchange the code for tokens. Must use the *same* redirect_uri
            // that was sent on the authorize request (OAuth 2.0 exact match).
            try await self.exchangeCode(
                code: callback.code,
                pkce: pkce,
                config: config,
                key: key,
                redirectURI: redirectURI
            )
        }
    }

    // MARK: - Token exchange

    /// Build the application/x-www-form-urlencoded body for the token
    /// endpoint. Exposed for unit tests so we can assert `redirect_uri`
    /// matches the loopback callback (Critical: never hard-code `:0`).
    public static func tokenExchangeParameters(
        code: String,
        clientID: String,
        redirectURI: String,
        codeVerifier: String,
        clientSecret: String? = nil
    ) -> [String: String] {
        var params = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            // Must equal the authorize-time redirect_uri exactly.
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
        ]
        if let secret = clientSecret {
            params["client_secret"] = secret
        }
        return params
    }

    /// Exchange an authorization code for access + refresh tokens.
    private func exchangeCode(
        code: String,
        pkce: MCPPKCEPair,
        config: MCPOAuthConfig,
        key: String,
        redirectURI: String
    ) async throws {

        guard let tokenURL = URL(string: config.tokenURL) else {
            throw MCPOAuthError.tokenExchangeFailed(
                "Invalid token URL: \(config.tokenURL)")
        }

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")

        let params = Self.tokenExchangeParameters(
            code: code,
            clientID: config.clientID,
            redirectURI: redirectURI,
            codeVerifier: pkce.verifier,
            clientSecret: config.clientSecret)

        req.httpBody = encodeFormParams(params)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8)?
                .prefix(200) ?? "<binary>"
            throw MCPOAuthError.tokenExchangeFailed(
                "Token endpoint returned \(status): \(body)")
        }

        // Parse the token response.
        guard let json = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            throw MCPOAuthError.tokenExchangeFailed(
                "Token response is not valid JSON")
        }

        guard let accessToken = json["access_token"] as? String else {
            throw MCPOAuthError.tokenExchangeFailed(
                "Token response missing access_token")
        }

        let refreshToken = json["refresh_token"] as? String
        let expiresIn = (json["expires_in"] as? Double)
            ?? (json["expires_in"] as? Int).map(Double.init)
        let scopes = (json["scope"] as? String)?
            .split(separator: " ").map(String.init) ?? config.scopes

        let expiresAt: Double? = {
            guard let expiresIn else { return nil }
            return Date().timeIntervalSince1970 + expiresIn
        }()

        let cred = MCPOAuthCredential(
            clientID: config.clientID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            scopes: scopes,
            expiresAt: expiresAt)

        tokenStore.save(key: key, credential: cred)
    }

    // MARK: - Refresh

    /// Try to refresh an expired token. Returns the new access token on
    /// success, nil on failure (caller will fall through to browser auth).
    private func tryRefresh(
        key: String,
        cred: MCPOAuthCredential,
        config: MCPOAuthConfig
    ) async -> String? {

        guard let refreshToken = cred.refreshToken else { return nil }

        guard let tokenURL = URL(string: config.tokenURL) else {
            return nil
        }

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")

        var params = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
        ]
        if let secret = config.clientSecret {
            params["client_secret"] = secret
        }
        req.httpBody = encodeFormParams(params)

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
                  let newAccess = json["access_token"] as? String else {
                return nil
            }

            // RFC 6749 §6: if the response omits a new refresh token,
            // preserve the old one.
            let newRefresh = (json["refresh_token"] as? String) ?? refreshToken
            let expiresIn = (json["expires_in"] as? Double)
                ?? (json["expires_in"] as? Int).map(Double.init)
            let expiresAt: Double? = {
                guard let expiresIn else { return nil }
                return Date().timeIntervalSince1970 + expiresIn
            }()

            let refreshed = MCPOAuthCredential(
                clientID: cred.clientID,
                accessToken: newAccess,
                refreshToken: newRefresh,
                scopes: cred.scopes,
                expiresAt: expiresAt)

            tokenStore.save(key: key, credential: refreshed)
            return newAccess
        } catch {
            return nil
        }
    }

    // MARK: - In-process dedup (Layer 2)

    /// Get an in-flight auth task for a server, if one exists.
    private func inFlightTask(for serverName: String) -> Task<Void, Error>? {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return inFlight[serverName]
    }

    /// Register a task as the in-flight auth for a server.
    private func registerInFlight(serverName: String, task: Task<Void, Error>) {
        inFlightLock.lock()
        inFlight[serverName] = task
        inFlightLock.unlock()
    }

    /// Unregister an in-flight task.
    private func unregisterInFlight(serverName: String) {
        inFlightLock.lock()
        inFlight.removeValue(forKey: serverName)
        inFlightLock.unlock()
    }

    // MARK: - Helpers

    /// Build the token-store key for a server.
    public func tokenKey(serverName: String, serverURL: String) -> String {
        "\(serverName):\(serverURL)"
    }

    /// URL-encode form parameters for a POST body.
    private func encodeFormParams(_ params: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = params.map { (k, v) in
            URLQueryItem(name: k, value: v)
        }
        // URLComponents percent-encodes the query — we want the
        // body-ready form (no leading `?`).
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    /// Open a URL in the system browser. Uses NSWorkspace on macOS.
    private func openInBrowser(url: URL) async {
        _ = await MainActor.run {
            #if canImport(AppKit)
            return NSWorkspace.shared.open(url)
            #else
            // Non-macOS fallback — log the URL so a user can open it.
            print("[MCPOAuthCoordinator] Open this URL to authenticate: \(url)")
            return false
            #endif
        }
    }
}