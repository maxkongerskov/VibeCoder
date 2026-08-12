//
//  RemoteAccessPasswordStore.swift
//
//  File-based password store for remote access authentication.
//  PBKDF2-HMAC-SHA256 hash at `~/.vibecoder/remote_access_password.json`
//  with atomic temp+rename writes and restrictive file permissions (0600).
//
//  Session cookies are HMAC-SHA256 signed payloads (not encrypted) that
//  encode the issuing time and expiry. Rotation of the HMAC secret
//  invalidates all outstanding cookies — no per-cookie bookkeeping needed.
//
//  NOTE: Swift 6.3 removed PBKDF2 / KeyDerivation / Password from CryptoKit,
//  so we implement PBKDF2-HMAC-SHA256 manually here using only HMAC<SHA256>
//  and SHA256 which remain stable.
//

import Foundation
import CryptoKit

// MARK: - Manual PBKDF2-HMAC-SHA256 (Swift 6.3 CryptoKit workaround)

/// Derive key material using PBKDF2 with HMAC-SHA256.
/// - Parameters:
///   - password: The plaintext password.
///   - salt:     Random salt bytes (16+ bytes recommended).
///   - iterations: Number of PBKDF2 rounds (600 000 for production).
///   - keyLength: Desired output length in bytes.
private func pbkdf2HMACSHA256(
    password: String,
    salt: [UInt8],
    iterations: Int,
    keyLength: Int
) -> [UInt8] {
    let hmacKey = SymmetricKey(data: Data(password.utf8))
    let hLen = 32 // SHA-256 digest length
    let blockCount = (keyLength + hLen - 1) / hLen
    var keyBytes = [UInt8](repeating: 0, count: keyLength)

    for blockIndex in 1...blockCount {
        // U_1 = HMAC(password, salt || INT(i))
        var blockBytes = salt
        blockBytes.append(UInt8((blockIndex >> 24) & 0xFF))
        blockBytes.append(UInt8((blockIndex >> 16) & 0xFF))
        blockBytes.append(UInt8((blockIndex >> 8) & 0xFF))
        blockBytes.append(UInt8(blockIndex & 0xFF))

        var u: [UInt8] = hmacSymmetric(key: hmacKey, message: blockBytes)
        // T_i = U_1 XOR U_2 XOR ... XOR U_c
        var t = u

        for _ in 1..<iterations {
            u = hmacSymmetric(key: hmacKey, message: u)
            for j in 0..<u.count {
                t[j] ^= u[j]
            }
        }

        let offset = (blockIndex - 1) * hLen
        let copyLen = min(hLen, keyLength - offset)
        keyBytes[offset..<(offset + copyLen)] = t[..<copyLen]
    }

    return keyBytes
}

/// HMAC-SHA256 over `message` using the given symmetric key, returning raw bytes.
private func hmacSymmetric(key: SymmetricKey, message: [UInt8]) -> [UInt8] {
    let mac = HMAC<SHA256>.authenticationCode(
        for: Data(message),
        using: key
    )
    // Use raw MAC bytes — never parse `CustomStringConvertible` (unstable).
    return Array(Data(mac))
}

// MARK: - RemoteAccessPasswordStore

/// Persistent store for the remote-access password hash and session-secret.
public final class RemoteAccessPasswordStore: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = RemoteAccessPasswordStore()

    // MARK: - Internal types

    private struct Stored: Codable, Equatable {
        var hash: String       // base64 PBKDF2 output
        let salt: String       // base64 16-byte salt
        let iterations: Int    // PBKDF2 iteration count
        var sessionSecret: String  // base64 32-byte HMAC key (mutated on rotation)
    }

    // MARK: - Constants

    private static let defaultIterations = 600_000
    private static let saltBytes = 16
    private static let hashBytes = 32
    private static let secretBytes = 32
    private static let cookieTTL: TimeInterval = 3600 // 1 hour

    // MARK: - File system

    private let fileURL: URL
    private let queue = DispatchQueue(label: "RemoteAccessPasswordStore.io", qos: .utility)

    // MARK: - Init

    /// Initialize with a specific file URL. The shared instance uses the
    /// default location; tests can pass a temp URL.
    internal init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("VibeCoder")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("remote_access_password.json")
    }

    // MARK: - Public API

    /// Whether a password hash currently exists on disk.
    public func isSet() -> Bool {
        queue.sync { _loadStored() != nil }
    }

    /// Set (or change) the password. Rejects empty or < 6-char passwords.
    public func setPassword(_ plaintext: String) throws {
        let trimmed = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 6 else {
            throw PasswordError.tooShort
        }

        let salt = Self.randomBytes(count: Self.saltBytes)
        let hash = pbkdf2HMACSHA256(
            password: trimmed,
            salt: salt,
            iterations: Self.defaultIterations,
            keyLength: Self.hashBytes
        )
        let secret = Self.randomBytes(count: Self.secretBytes)

        let stored = Stored(
            hash: Data(hash).base64EncodedString(),
            salt: Data(salt).base64EncodedString(),
            iterations: Self.defaultIterations,
            sessionSecret: Data(secret).base64EncodedString()
        )

        _ = queue.sync {
            _writeStored(stored)
        }
    }

    /// Verify a plaintext password against the stored hash. Constant-time.
    public func verify(_ plaintext: String) -> Bool {
        let stored = queue.sync { _loadStored() }
        guard let stored else { return false }

        guard let saltData = Data(base64Encoded: stored.salt) else { return false }
        let salt = [UInt8](saltData)

        let derived = pbkdf2HMACSHA256(
            password: plaintext,
            salt: salt,
            iterations: stored.iterations,
            keyLength: Self.hashBytes
        )

        guard let hashData = Data(base64Encoded: stored.hash) else { return false }
        let storedHash = [UInt8](hashData)

        // Constant-time comparison to prevent timing attacks.
        guard storedHash.count == derived.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<storedHash.count {
            diff |= storedHash[i] ^ derived[i]
        }
        return diff == 0
    }

    /// Remove the password file.
    public func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Session cookies

    /// Issue an HMAC-signed session cookie string.
    /// Payload is absolute **expiry** epoch (not issue time).
    public func issueSessionCookie(expiresAt: Date) -> String {
        let secret = queue.sync { _loadStored()?.sessionSecret } ?? ""
        guard let keyData = Data(base64Encoded: secret), keyData.count == Self.secretBytes else {
            return ""
        }
        let payload = "\(Int(expiresAt.timeIntervalSince1970))"
        let key = SymmetricKey(data: keyData)

        // HMAC over the payload bytes
        let macBytes = hmacSymmetric(key: key, message: Array(payload.utf8))
        // Encode MAC as hex string for serialization
        let macHex = macBytes.map { String(format: "%02x", $0) }.joined()

        return "\(payload).\(macHex)"
    }

    /// Validate a session cookie string. Returns true if the HMAC is valid and not expired.
    public func validateSessionCookie(_ cookie: String, now: Date = Date()) -> Bool {
        let parts = cookie.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let expiryEpoch = Double(parts[0])
        else { return false }

        let secret = queue.sync { _loadStored()?.sessionSecret } ?? ""
        guard let keyData = Data(base64Encoded: secret), keyData.count == Self.secretBytes else {
            return false
        }

        let key = SymmetricKey(data: keyData)
        let payloadBytes = Array(parts[0].utf8)
        let expectedMacBytes = hmacSymmetric(key: key, message: payloadBytes)
        // Empty MAC must never validate (fail closed).
        guard !expectedMacBytes.isEmpty else { return false }

        // Parse the stored hex mac back to bytes
        let storedHex = String(parts[1])
        guard storedHex.count == expectedMacBytes.count * 2 else { return false }

        var storedMacBytes = [UInt8](repeating: 0, count: expectedMacBytes.count)
        for i in 0..<expectedMacBytes.count {
            let hexStart = storedHex.index(storedHex.startIndex, offsetBy: i * 2)
            let hexEnd = storedHex.index(storedHex.startIndex, offsetBy: i * 2 + 2)
            if let val = UInt8(storedHex[hexStart..<hexEnd], radix: 16) {
                storedMacBytes[i] = val
            } else {
                return false
            }
        }

        // Constant-time comparison to prevent timing attacks.
        guard storedMacBytes.count == expectedMacBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<storedMacBytes.count {
            diff |= storedMacBytes[i] ^ expectedMacBytes[i]
        }
        guard diff == 0 else { return false }

        // Payload is absolute expiry (issueSessionCookie writes expiresAt epoch).
        return now.timeIntervalSince1970 < expiryEpoch
    }

    /// Rotate the HMAC session secret, invalidating all outstanding cookies.
    public func rotateSessionSecret() {
        let newSecret = Self.randomBytes(count: Self.secretBytes)
        _ = queue.sync {
            var stored = _loadStored() ?? Stored(
                hash: "", salt: "", iterations: Self.defaultIterations,
                sessionSecret: ""
            )
            stored.sessionSecret = Data(newSecret).base64EncodedString()
            return _writeStored(stored)
        }
    }

    // MARK: - Private helpers

    private func _loadStored() -> Stored? {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        return stored
    }

    @discardableResult
    private func _writeStored(_ stored: Stored) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(stored) else { return false }

        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmpURL = dir.appendingPathComponent(".remote_access_password.json.tmp")
        // Remove stale temp file that may remain from a crashed previous write.
        try? FileManager.default.removeItem(at: tmpURL)

        do {
            try data.write(to: tmpURL, options: .atomic)

            // If the target already exists (e.g. from a prior write), remove it first
            // so that the atomic rename can replace it cleanly.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }

            // Atomic rename.
            try FileManager.default.moveItem(at: tmpURL, to: fileURL)

            // Ensure the final file also has 0600 (some filesystems reset perms on rename).
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            print("_writeStored: FAILED \(error.localizedDescription) for \(fileURL.path)")
            return false
        }
    }

    private static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes
    }
}

// MARK: - Errors

public enum PasswordError: Error, LocalizedError {
    case tooShort
    public var errorDescription: String? { "Password must be at least 6 characters." }
}
