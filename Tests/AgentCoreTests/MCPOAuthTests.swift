import XCTest
@testable import AgentCore

/// Tests for the MCP OAuth layer: PKCE generation, token store CRUD +
/// file permissions, cross-process lock name sanitization, OAuth config
/// Codable round-trip, and coordinator key derivation.
final class MCPOAuthTests: XCTestCase {

    // MARK: - PKCE

    func testPKCEGenerationProducesValidPair() {
        let pair = MCPPKCEPair.generate()

        // Verifier should be 43 chars (32 bytes base64url, no padding).
        XCTAssertEqual(pair.verifier.count, 43,
                       "PKCE verifier should be 43 chars (32 bytes base64url)")

        // Challenge should equal SHA256(verifier) base64url.
        XCTAssertTrue(pair.isValid(),
                      "PKCE challenge must equal S256(verifier)")

        // Method string.
        XCTAssertEqual(MCPPKCEPair.method, "S256")
    }

    func testPKCEPairsAreUnique() {
        // Generate 10 pairs — all should have distinct verifiers.
        var seen = Set<String>()
        for _ in 0..<10 {
            let pair = MCPPKCEPair.generate()
            XCTAssertFalse(seen.contains(pair.verifier),
                           "PKCE verifiers should be random and unique")
            seen.insert(pair.verifier)
        }
    }

    func testBase64URLEncoding() {
        // Known: "hello" → "aGVsbG8"
        let data = Data("hello".utf8)
        XCTAssertEqual(base64URLEncode(data), "aGVsbG8")

        // Bytes that produce + and / in standard base64.
        let tricky = Data([0xFB, 0xFF, 0xBF])
        let standard = tricky.base64EncodedString()
        XCTAssertTrue(standard.contains("+") || standard.contains("/"),
                      "Precondition: standard base64 of these bytes has + or /")
        let urlSafe = base64URLEncode(tricky)
        XCTAssertFalse(urlSafe.contains("+"), "URL-safe should not contain +")
        XCTAssertFalse(urlSafe.contains("/"), "URL-safe should not contain /")
        XCTAssertFalse(urlSafe.contains("="), "URL-safe should not be padded")
    }

    func testStateTokenIsRandom() {
        let s1 = generateStateToken()
        let s2 = generateStateToken()
        XCTAssertNotEqual(s1, s2, "State tokens should be random")
        XCTAssertEqual(s1.count, 43, "State token should be 43 chars (32 bytes base64url)")
    }

    // MARK: - Token Store

    func testTokenStoreSaveLoadClear() {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let store = MCPTokenStore(fileURL: tmpURL)
        let key = "github:https://mcp.github.com/sse"

        // Initially empty.
        XCTAssertNil(store.load(key: key))
        XCTAssertFalse(store.hasCredential(key: key))

        // Save a credential.
        let cred = MCPOAuthCredential(
            clientID: "client-123",
            accessToken: "access-abc",
            refreshToken: "refresh-xyz",
            scopes: ["repo", "issues"])
        store.save(key: key, credential: cred)

        // Load it back.
        let loaded = store.load(key: key)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.clientID, "client-123")
        XCTAssertEqual(loaded?.accessToken, "access-abc")
        XCTAssertEqual(loaded?.refreshToken, "refresh-xyz")
        XCTAssertEqual(loaded?.scopes, ["repo", "issues"])
        XCTAssertTrue(store.hasCredential(key: key))

        // Clear it.
        store.clear(key: key)
        XCTAssertNil(store.load(key: key))
        XCTAssertFalse(store.hasCredential(key: key))
    }

    func testTokenStorePersistsAcrossInstances() {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // Write with one store instance.
        let store1 = MCPTokenStore(fileURL: tmpURL)
        let key = "server:url"
        store1.save(key: key, credential: MCPOAuthCredential(
            clientID: "c", accessToken: "tok"))

        // Read with a fresh instance — file is the source of truth.
        let store2 = MCPTokenStore(fileURL: tmpURL)
        XCTAssertNotNil(store2.load(key: key))
    }

    func testTokenStoreFilePermissions() {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_perms_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let store = MCPTokenStore(fileURL: tmpURL)
        store.save(key: "k", credential: MCPOAuthCredential(
            clientID: "c", accessToken: "t"))

        // Verify the file has 0600 perms (owner read/write only).
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: tmpURL.path)
        let perms = attrs?[.posixPermissions] as? NSNumber
        XCTAssertNotNil(perms, "File should have posix permissions")
        XCTAssertEqual(perms?.int16Value ?? -1, 0o600,
                       "Token store file should have 0600 permissions (owner-only)")
    }

    func testTokenStoreMultipleServers() {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_multi_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let store = MCPTokenStore(fileURL: tmpURL)
        store.save(key: "github:url1", credential: MCPOAuthCredential(
            clientID: "c1", accessToken: "t1"))
        store.save(key: "slack:url2", credential: MCPOAuthCredential(
            clientID: "c2", accessToken: "t2"))

        XCTAssertEqual(store.load(key: "github:url1")?.accessToken, "t1")
        XCTAssertEqual(store.load(key: "slack:url2")?.accessToken, "t2")

        // Clearing one doesn't affect the other.
        store.clear(key: "github:url1")
        XCTAssertNil(store.load(key: "github:url1"))
        XCTAssertEqual(store.load(key: "slack:url2")?.accessToken, "t2")
    }

    func testTokenStoreCorruptFileTreatedAsEmpty() {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_corrupt_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // Write garbage.
        try? "not valid json {{{".write(
            to: tmpURL, atomically: true,
            encoding: .utf8)

        let store = MCPTokenStore(fileURL: tmpURL)
        // Should not crash — treat as empty.
        XCTAssertNil(store.load(key: "any"))
    }

    // MARK: - Token expiry

    func testCredentialNotExpiredNoExpiry() {
        let cred = MCPOAuthCredential(
            clientID: "c", accessToken: "t")
        XCTAssertFalse(cred.isExpired())
    }

    func testCredentialNotExpiredFuture() {
        let cred = MCPOAuthCredential(
            clientID: "c", accessToken: "t",
            expiresAt: Date().timeIntervalSince1970 + 3600)
        XCTAssertFalse(cred.isExpired())
    }

    func testCredentialExpired() {
        let cred = MCPOAuthCredential(
            clientID: "c", accessToken: "t",
            expiresAt: Date().timeIntervalSince1970 - 100)
        XCTAssertTrue(cred.isExpired())
    }

    func testCredentialExpiryWithRefreshBuffer() {
        // Token expires in 20s — with a 30s buffer, it should be
        // considered "expired" for refresh purposes.
        let cred = MCPOAuthCredential(
            clientID: "c", accessToken: "t",
            expiresAt: Date().timeIntervalSince1970 + 20)
        XCTAssertTrue(cred.isExpired(refreshBuffer: 30))
    }

    // MARK: - Cross-process lock

    func testCrossProcessLockSanitizesServerName() {
        XCTAssertEqual(MCPCrossProcessLock.sanitize("github"), "github")
        XCTAssertEqual(MCPCrossProcessLock.sanitize("my-server"), "my-server")
        XCTAssertEqual(MCPCrossProcessLock.sanitize("server_name"), "server_name")

        // Path traversal attempts must be neutralized.
        XCTAssertEqual(MCPCrossProcessLock.sanitize("../../etc/passwd"),
                       "______etc_passwd")
        XCTAssertEqual(MCPCrossProcessLock.sanitize("server;rm -rf /"),
                       "server_rm_-rf__")

        // Empty name gets a placeholder.
        XCTAssertEqual(MCPCrossProcessLock.sanitize(""), "unnamed")
    }

    func testCrossProcessLockFilePath() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecoder_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lock = MCPCrossProcessLock(serverName: "my-server", baseDir: tmpDir)
        XCTAssertTrue(lock.lockFilePath.path.contains("mcp_auth_my-server.lock"),
                      "Lock file path should contain sanitized server name")
        XCTAssertEqual(lock.safeName, "my-server")
    }

    func testCrossProcessLockAcquireRelease() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecoder_lock_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lock = MCPCrossProcessLock(
            serverName: "test-server", baseDir: tmpDir)

        XCTAssertNoThrow(try lock.acquire(timeout: 2))
        lock.release()

        XCTAssertNoThrow(try lock.acquire(timeout: 2))
        lock.release()
    }

    func testCrossProcessLockAcquireTimesOutWhenHeld() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecoder_lock_to_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let holder = MCPCrossProcessLock(serverName: "held", baseDir: tmpDir)
        let waiter = MCPCrossProcessLock(serverName: "held", baseDir: tmpDir)
        try holder.acquire(timeout: 2)
        defer { holder.release() }

        let start = Date()
        XCTAssertThrowsError(try waiter.acquire(timeout: 0.25)) { err in
            let msg = (err as? LocalizedError)?.errorDescription ?? "\(err)"
            XCTAssertTrue(msg.lowercased().contains("timed out"), msg)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    // MARK: - OAuth config Codable

    func testOAuthConfigCodableRoundTrip() {
        let config = MCPOAuthConfig(
            clientID: "client-abc",
            authorizationURL: "https://auth.example.com/authorize",
            tokenURL: "https://auth.example.com/token",
            scopes: ["repo", "issues"],
            clientSecret: "secret-xyz",
            callbackPort: 8765)

        let data = try! JSONEncoder().encode(config)
        let decoded = try! JSONDecoder().decode(MCPOAuthConfig.self, from: data)

        XCTAssertEqual(decoded.clientID, "client-abc")
        XCTAssertEqual(decoded.authorizationURL,
                       "https://auth.example.com/authorize")
        XCTAssertEqual(decoded.tokenURL, "https://auth.example.com/token")
        XCTAssertEqual(decoded.scopes, ["repo", "issues"])
        XCTAssertEqual(decoded.clientSecret, "secret-xyz")
        XCTAssertEqual(decoded.callbackPort, 8765)
    }

    func testOAuthConfigCodableSnakeCase() {
        // Verify the JSON uses snake_case keys (matching Grok Build's
        // convention for MCP config files).
        let config = MCPOAuthConfig(
            clientID: "c", authorizationURL: "a", tokenURL: "t")
        let data = try! JSONEncoder().encode(config)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["client_id"] as? String, "c")
        XCTAssertEqual(json["authorization_url"] as? String, "a")
        XCTAssertEqual(json["token_url"] as? String, "t")
    }

    // MARK: - MCPServerConfig with OAuth

    func testMCPServerConfigWithOAuthRoundTrip() {
        let server = MCPServerConfig(
            name: "github",
            transport: .streamableHttp,
            url: "https://mcp.github.com/sse",
            oauth: MCPOAuthConfig(
                clientID: "cid",
                authorizationURL: "https://auth.example.com/authorize",
                tokenURL: "https://auth.example.com/token"))

        let data = try! JSONEncoder().encode(server)
        let decoded = try! JSONDecoder().decode(MCPServerConfig.self, from: data)

        XCTAssertEqual(decoded.name, "github")
        XCTAssertEqual(decoded.transport, .streamableHttp)
        XCTAssertNotNil(decoded.oauth)
        XCTAssertEqual(decoded.oauth?.clientID, "cid")
    }

    func testMCPServerConfigWithoutOAuthBackwardCompat() {
        // A config without an `oauth` field (legacy JSON) should decode
        // with oauth = nil.
        let json = """
        {"name":"old-server","transport":"streamableHttp","url":"https://example.com"}
        """.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(MCPServerConfig.self, from: json)

        XCTAssertEqual(decoded.name, "old-server")
        XCTAssertNil(decoded.oauth)
    }

    // MARK: - Token exchange redirect_uri (Wave B S1 / W04 Critical)

    func testTokenExchangeParametersUsesActualRedirectURI() {
        // Critical: must NOT hard-code http://127.0.0.1:0/callback.
        let actual = "http://127.0.0.1:54321/callback"
        let params = MCPOAuthCoordinator.tokenExchangeParameters(
            code: "auth-code-xyz",
            clientID: "client-1",
            redirectURI: actual,
            codeVerifier: "verifier-abc",
            clientSecret: "sec")
        XCTAssertEqual(params["redirect_uri"], actual,
                       "token exchange must use the authorize-time redirect_uri")
        XCTAssertNotEqual(params["redirect_uri"], "http://127.0.0.1:0/callback")
        XCTAssertEqual(params["grant_type"], "authorization_code")
        XCTAssertEqual(params["code"], "auth-code-xyz")
        XCTAssertEqual(params["client_id"], "client-1")
        XCTAssertEqual(params["code_verifier"], "verifier-abc")
        XCTAssertEqual(params["client_secret"], "sec")
    }

    func testTokenExchangeParametersOmitsSecretWhenNil() {
        let params = MCPOAuthCoordinator.tokenExchangeParameters(
            code: "c",
            clientID: "id",
            redirectURI: "http://127.0.0.1:9999/callback",
            codeVerifier: "v")
        XCTAssertNil(params["client_secret"])
        XCTAssertEqual(params["redirect_uri"], "http://127.0.0.1:9999/callback")
    }

    // MARK: - Coordinator key derivation

    func testCoordinatorTokenKey() {
        let coordinator = MCPOAuthCoordinator()
        let key = coordinator.tokenKey(
            serverName: "github",
            serverURL: "https://mcp.github.com/sse")
        XCTAssertEqual(key, "github:https://mcp.github.com/sse")
    }

    func testCoordinatorIsAuthenticated() {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_coord_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // Use a coordinator with a custom token store URL by checking
        // the shared coordinator's behavior. Since the shared store uses
        // ~/.vibecoder/, we test via a direct MCPTokenStore instead.
        let store = MCPTokenStore(fileURL: tmpURL)
        let key = "test-server:url"

        XCTAssertFalse(store.hasCredential(key: key))
        store.save(key: key, credential: MCPOAuthCredential(
            clientID: "c", accessToken: "t"))
        XCTAssertTrue(store.hasCredential(key: key))
    }

    // MARK: - Wave C bug-hunt: isAuthenticated + invalidate

    func testIsAuthenticatedFalseForDeadExpiredToken() {
        // Shared coordinator uses ~/.vibecoder/ store — isolate via temp store
        // only for credential shape; coordinator API uses shared store.
        // We exercise the credential expiry semantics used by isAuthenticated.
        let dead = MCPOAuthCredential(
            clientID: "c",
            accessToken: "stale",
            refreshToken: nil,
            expiresAt: Date().timeIntervalSince1970 - 3600)
        XCTAssertTrue(dead.isExpired(refreshBuffer: 0),
                      "access without refresh must be expired")
        let refreshable = MCPOAuthCredential(
            clientID: "c",
            accessToken: "stale",
            refreshToken: "r",
            expiresAt: Date().timeIntervalSince1970 - 3600)
        XCTAssertTrue(refreshable.isExpired(refreshBuffer: 0))
        XCTAssertNotNil(refreshable.refreshToken)
    }

    func testInvalidateAccessTokenForcesExpiry() {
        // Write to shared store under a unique key via coordinator APIs.
        let coordinator = MCPOAuthCoordinator.shared
        let name = "w04-invalidate-\(UUID().uuidString.prefix(8))"
        let url = "https://example.test/mcp"
        let key = coordinator.tokenKey(serverName: name, serverURL: url)

        // Save a still-valid token (no expiry).
        MCPTokenStore.shared.save(
            key: key,
            credential: MCPOAuthCredential(
                clientID: "c",
                accessToken: "live-token",
                refreshToken: "r",
                expiresAt: Date().timeIntervalSince1970 + 3600))
        defer { MCPTokenStore.shared.clear(key: key) }

        XCTAssertTrue(coordinator.isAuthenticated(serverName: name, serverURL: url))
        coordinator.invalidateAccessToken(serverName: name, serverURL: url)
        let after = MCPTokenStore.shared.load(key: key)
        XCTAssertNotNil(after)
        XCTAssertTrue(after!.isExpired(refreshBuffer: 0),
                      "invalidate must force access token past expiry for 401 retry path")
        // Still "signed in" for UI because refresh token remains.
        XCTAssertTrue(coordinator.isAuthenticated(serverName: name, serverURL: url),
                      "refreshable sessions stay authenticated in UI")
    }
}