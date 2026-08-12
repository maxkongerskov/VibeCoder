//
//  RemoteAccessPasswordStoreTests.swift
//
//  Tests for `RemoteAccessPasswordStore`: PBKDF2 verify, cookie lifecycle,
//  file corruption tolerance, and minimum password length enforcement.
//

import XCTest
@testable import AgentCore

final class RemoteAccessPasswordStoreTests: XCTestCase {

    // Temporary file used by all tests so the singleton writes to an isolated location.
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAccessPasswordStoreTests.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - testRoundTrip

    func testRoundTrip() {
        let store = RemoteAccessPasswordStore(fileURL: tempDir.appendingPathComponent("password.json"))
        XCTAssertFalse(store.isSet())

        try? store.setPassword("MyP@ssw0rd!")
        XCTAssertTrue(store.isSet())

        XCTAssertTrue(store.verify("MyP@ssw0rd!"))
        XCTAssertFalse(store.verify("wrong-password"))
    }

    // MARK: - testWrongPassword

    func testWrongPassword() {
        let store = RemoteAccessPasswordStore(fileURL: tempDir.appendingPathComponent("password.json"))
        try? store.setPassword("correctPassword1")
        XCTAssertTrue(store.isSet())

        // Various wrong passwords should all return false.
        let wrongPasswords = ["wrong", "Wrong1!", "correctPassword2", " ", ""]
        for pw in wrongPasswords {
            XCTAssertFalse(store.verify(pw), "verify(\"\(pw)\") should be false")
        }
    }

    // MARK: - testCorruptFileTreatedAsUnset

    func testCorruptFileTreatedAsUnset() {
        let fileURL = tempDir.appendingPathComponent("password.json")

        // Write garbage bytes.
        try? Data([0xFF, 0xFE, 0xFD]).write(to: fileURL)

        let store = RemoteAccessPasswordStore(fileURL: fileURL)
        // A corrupt file must be treated as empty — no crash, isSet() == false.
        XCTAssertFalse(store.isSet(), "corrupt file should be treated as no password set")

        // Setting a new password should overwrite gracefully.
        try? store.setPassword("MyP@ssw0rd!")
        XCTAssertTrue(store.isSet())
        XCTAssertTrue(store.verify("MyP@ssw0rd!"))

        // Also try an empty file.
        try? Data().write(to: fileURL)
        XCTAssertFalse(store.isSet(), "empty file should be treated as no password set")

        // And a partial JSON.
        try? Data("{{{{".utf8).write(to: fileURL)
        XCTAssertFalse(store.isSet(), "partial JSON should be treated as no password set")
    }

    // MARK: - testSessionCookieRoundTrip

    func testSessionCookieRoundTrip() {
        let store = RemoteAccessPasswordStore(fileURL: tempDir.appendingPathComponent("password.json"))
        try? store.setPassword("MyP@ssw0rd!")

        let expiresAt = Date().addingTimeInterval(3600)
        let cookie = store.issueSessionCookie(expiresAt: expiresAt)
        XCTAssertFalse(cookie.isEmpty, "issueSessionCookie should produce a non-empty cookie")

        XCTAssertTrue(store.validateSessionCookie(cookie, now: Date()),
                      "cookie issued just now should be valid")

        // Tamper with the cookie.
        let tampered = String(cookie.prefix(cookie.count / 2)) + "AAAA" + String(cookie.suffix(10))
        XCTAssertFalse(store.validateSessionCookie(tampered, now: Date()),
                       "tampered cookie should be invalid")
    }

    // MARK: - testRotateSessionSecretInvalidatesOldCookies

    func testRotateSessionSecretInvalidatesOldCookies() {
        let store = RemoteAccessPasswordStore(fileURL: tempDir.appendingPathComponent("password.json"))
        try? store.setPassword("MyP@ssw0rd!")

        let expiresAt = Date().addingTimeInterval(3600)
        let oldCookie = store.issueSessionCookie(expiresAt: expiresAt)

        // Rotate the HMAC secret.
        store.rotateSessionSecret()

        // The old cookie should now be invalid because the HMAC key changed.
        XCTAssertFalse(store.validateSessionCookie(oldCookie, now: Date()),
                       "old cookie must be invalidated after session secret rotation")

        // A newly issued cookie should work.
        let newCookie = store.issueSessionCookie(expiresAt: expiresAt)
        XCTAssertTrue(store.validateSessionCookie(newCookie, now: Date()),
                      "newly issued cookie should be valid after rotation")

        // The password itself must still verify correctly.
        XCTAssertTrue(store.verify("MyP@ssw0rd!"))
    }

    // MARK: - testMinimumPasswordLength

    func testMinimumPasswordLength() {
        let store = RemoteAccessPasswordStore(fileURL: tempDir.appendingPathComponent("password.json"))

        // Empty and short passwords should throw PasswordError.tooShort.
        let failures = ["", "abcde", "12345"]
        for pw in failures {
            do {
                try store.setPassword(pw)
                XCTFail("setPassword(\"\(pw)\") should throw PasswordError.tooShort")
            } catch let error as PasswordError {
                XCTAssertEqual(error, .tooShort, "expected tooShort error for \"\(pw)\"")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        // A 6-character password should succeed.
        XCTAssertNoThrow(try store.setPassword("123456"), "6-char password should be accepted")
        XCTAssertTrue(store.isSet())

        // Clear and try again with a longer password.
        store.clear()
        XCTAssertFalse(store.isSet())

        try? store.setPassword("longEnough123")
        XCTAssertTrue(store.isSet())
    }
}
