import XCTest
@testable import AgentCore

/// End-to-end authentication tests for the RemoteControlServer password gate.
/// These test the full auth flow: password setup → cookie issuance → verification → revocation.
final class RemoteControlServerAuthTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteControlServerAuthTests.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore(named name: String = "auth.json") -> RemoteAccessPasswordStore {
        RemoteAccessPasswordStore(fileURL: tempDir.appendingPathComponent(name))
    }

    // MARK: - Tests

    /// LAN remote control is shut down: `start()` must not bind or publish
    /// a session URL even when the UI still calls it.
    func testStartRefusesAndDoesNotBindOrPublishURL() async throws {
        XCTAssertFalse(RemoteControlServer.isEnabled)
        let server = RemoteControlServer()
        do {
            _ = try await server.start(port: 18765, lifetime: 120)
            XCTFail("start() must throw .disabled")
        } catch let err as RemoteControlServer.ServerError {
            XCTAssertEqual(err, .disabled)
        }
        let running = await server.isRunning()
        let token = await server.currentToken()
        let url = await server.sessionURL(hostAddress: "192.168.1.10")
        let port = await server.currentPort()
        XCTAssertFalse(running)
        XCTAssertNil(token)
        XCTAssertNil(url)
        XCTAssertEqual(port, 18765)
    }

    /// Test 1: When no password is set, the auth gate allows unauthenticated access.
    /// The store reports isSet()=false and issueSessionCookie returns empty.
    func testPasswordNotSetAllowsUnauthenticatedAccess() async throws {
        let store = makeStore()

        // No password set yet.
        XCTAssertFalse(store.isSet())

        // Without a stored secret, issuing a cookie yields empty string.
        let expiresAt = Date().addingTimeInterval(3600)
        let cookie = store.issueSessionCookie(expiresAt: expiresAt)
        XCTAssertTrue(cookie.isEmpty, "issueSessionCookie should return empty when no password is set")

        // Validating an empty or missing cookie fails.
        XCTAssertFalse(store.validateSessionCookie("", now: Date()))

        // Revoke without a password should not crash.
        try? store.setPassword("initPass123")
        store.clear()
        XCTAssertFalse(store.isSet())
    }

    /// Test 2: When a password is set, unauthenticated requests are rejected (401).
    /// The auth gate should deny any request without a valid session cookie.
    func testPasswordSetRequiresCookieForAPIAccess() async throws {
        let store = makeStore(named: "requires_cookie.json")

        // Set up a password.
        try? store.setPassword("correctPass123")
        XCTAssertTrue(store.isSet())

        // Wrong password is rejected.
        XCTAssertFalse(store.verify("wrongPassword"))
        XCTAssertFalse(store.verify("correctPass12")) // too short to match despite overlap

        // A fake cookie is also rejected.
        XCTAssertFalse(store.validateSessionCookie("somefakecookie", now: Date()))

        // Even a well-formed but unissued cookie (no timestamp prefix) fails.
        XCTAssertFalse(store.validateSessionCookie("1234567890.aabbcc", now: Date()))
    }

    /// Test 3: Correct password issues a valid HMAC-signed session cookie.
    /// The cookie format is "unix_timestamp.hex_mac" and validates within TTL.
    func testCorrectPasswordIssuesValidCookie() async throws {
        let store = makeStore(named: "issues_cookie.json")

        // Set password and verify.
        try? store.setPassword("correctPass123")
        XCTAssertTrue(store.verify("correctPass123"))

        // Issue a cookie that expires in 1 hour.
        let expiresAt = Date().addingTimeInterval(3600)
        let cookie = store.issueSessionCookie(expiresAt: expiresAt)

        // Cookie should be non-empty and follow "timestamp.hex_mac" format.
        XCTAssertFalse(cookie.isEmpty)
        let parts = cookie.split(separator: ".", maxSplits: 1)
        XCTAssertEqual(parts.count, 2)
        // Timestamp part should be a valid Double.
        XCTAssertNotNil(Double(parts[0]))
        // MAC part should be hex string with even length.
        let macHex = String(parts[1])
        XCTAssertTrue(macHex.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(macHex.count % 2, 0, "MAC hex should have even length")

        // Cookie validates immediately after issuance.
        XCTAssertTrue(
            store.validateSessionCookie(cookie, now: Date()),
            "cookie issued just now should be valid"
        )

        // Cookie expires after TTL passes.
        let expiredNow = Date(timeIntervalSince1970: expiresAt.timeIntervalSince1970 + 3601)
        XCTAssertFalse(
            store.validateSessionCookie(cookie, now: expiredNow),
            "cookie should be invalid after TTL expires"
        )

        // Tampered cookie is rejected.
        let tampered = String(cookie.prefix(cookie.count / 2)) + "aa" + String(cookie.suffix(10))
        XCTAssertFalse(store.validateSessionCookie(tampered, now: Date()))
    }

    /// Test 4: Logging out (revoke / rotateSecret) invalidates all outstanding cookies.
    /// Password verification still works after rotation, and new cookies are valid.
    func testLogoutInvalidatesCookieViaRevoke() async throws {
        let store = makeStore(named: "logout_rotate.json")

        // Set up password and issue a cookie.
        try? store.setPassword("correctPass123")
        let expiresAt = Date().addingTimeInterval(3600)
        let oldCookie = store.issueSessionCookie(expiresAt: expiresAt)

        // Old cookie is valid before rotation.
        XCTAssertTrue(store.validateSessionCookie(oldCookie, now: Date()))

        // Revoke / logout — rotates the session secret.
        store.rotateSessionSecret()

        // Old cookie should be invalidated.
        XCTAssertFalse(
            store.validateSessionCookie(oldCookie, now: Date()),
            "old cookie must be invalidated after rotation"
        )

        // Password still works (hash is unchanged).
        XCTAssertTrue(store.verify("correctPass123"))

        // New cookie issued after rotation is valid.
        let newCookie = store.issueSessionCookie(expiresAt: expiresAt)
        XCTAssertTrue(store.validateSessionCookie(newCookie, now: Date()))

        // Password rotation does not affect old wrong-password checks.
        XCTAssertFalse(store.verify("wrongPassword"))
    }
}
