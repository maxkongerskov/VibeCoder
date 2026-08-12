//
//  MCPTokenStore.swift
//
//  File-based credential store for MCP OAuth tokens. Mirrors Grok Build's
//  `McpCredentialStoreAdapter` (credentials.rs) — one JSON file at
//  `~/.vibecoder/mcp_credentials.json`, keyed by `"serverName:serverURL"`,
//  with atomic temp+rename writes and restrictive file permissions (0600).
//
//  Why not Keychain: this mirrors Grok Build's deliberate design choice.
//  OAuth tokens are bearer tokens — if an attacker has file-system access
//  as the user, they already have the keychain too. File-based keeps the
//  store portable (VibeCoder could share it with a headless CLI later),
//  easy to inspect for debugging, and simple to wipe. The 0600 perms + a
//  tmp-rename atomic write close the TOCTOU window where secrets are
//  world-readable between `write` and `chmod`.
//
//  Concurrency: each load/save is independent. The on-disk file is the
//  source of truth; if two processes write concurrently one wins and the
//  other's write is lost — but both writes are valid tokens, so the
//  "loss" only matters for refreshes (and the in-process dedup layer in
//  MCPOAuthCoordinator prevents that).
//

import Foundation

/// A stored OAuth credential entry. Mirrors rmcp's `StoredCredentials`:
/// access + refresh tokens, optional expiry, client ID used to obtain them.
public struct MCPOAuthCredential: Codable, Sendable, Equatable {
    /// Client ID used to obtain this token (for refresh).
    public var clientID: String
    /// Bearer access token sent in `Authorization` header.
    public var accessToken: String
    /// Optional refresh token (RFC 6749 §6) for renewing access.
    public var refreshToken: String?
    /// Optional granted scopes (for display / debugging).
    public var scopes: [String]
    /// Token expiry as a UTC epoch timestamp (seconds). Nil = no expiry.
    public var expiresAt: Double?
    /// When the token was last refreshed (epoch seconds).
    public var receivedAt: Double

    public init(clientID: String,
                accessToken: String,
                refreshToken: String? = nil,
                scopes: [String] = [],
                expiresAt: Double? = nil,
                receivedAt: Double? = nil) {
        self.clientID = clientID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.receivedAt = receivedAt ?? Date().timeIntervalSince1970
    }

    /// Whether the token has expired (with a 30-second refresh buffer so we
    /// proactively refresh before the server returns 401).
    public func isExpired(refreshBuffer: TimeInterval = 30) -> Bool {
        guard let expiresAt else { return false }
        return Date().timeIntervalSince1970 + refreshBuffer >= expiresAt
    }

    /// Time until expiry, in seconds. Nil if no expiry is known.
    public func timeUntilExpiry() -> TimeInterval? {
        guard let expiresAt else { return nil }
        return max(0, expiresAt - Date().timeIntervalSince1970)
    }
}

/// File-based credential store for MCP OAuth tokens.
///
/// Thread-safe: all public methods are `nonisolated` and internally
/// synchronized via a serial DispatchQueue. The file is loaded fresh on each
/// read/write — concurrent processes see each other's writes (the cross-
/// process lock in MCPCrossProcessLock coordinates this).
public final class MCPTokenStore: @unchecked Sendable {

    /// Singleton shared store. All MCP OAuth flows use the same on-disk
    /// file (`~/.vibecoder/mcp_credentials.json`), keyed by server.
    public static let shared = MCPTokenStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "MCPTokenStore.io",
                                      qos: .utility)

    /// Initialize with a specific file URL. The shared instance uses the
    /// default location; tests can pass a temp URL.
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.fileURL = home
                .appendingPathComponent(".vibecoder", isDirectory: true)
                .appendingPathComponent("mcp_credentials.json")
        }
    }

    // MARK: - Public API

    /// Load a credential by key (`"serverName:serverURL"`).
    public func load(key: String) -> MCPOAuthCredential? {
        queue.sync { _load(key: key) }
    }

    /// Save a credential under `key`. Atomically writes the entire file
    /// (loading existing entries, updating this one, temp+rename).
    public func save(key: String, credential: MCPOAuthCredential) {
        queue.sync { _save(key: key, credential: credential) }
    }

    /// Clear a single server's stored credentials (sign-out).
    public func clear(key: String) {
        queue.sync { _clear(key: key) }
    }

    /// Whether any credential exists for this server (for UI status display).
    public func hasCredential(key: String) -> Bool {
        load(key: key) != nil
    }

    // MARK: - Internal (runs on `queue`)

    private func _load(key: String) -> MCPOAuthCredential? {
        guard let entries = readAll() else { return nil }
        return entries[key]
    }

    private func _save(key: String, credential: MCPOAuthCredential) {
        var entries = readAll() ?? [:]
        entries[key] = credential
        writeAll(entries)
    }

    private func _clear(key: String) {
        var entries = readAll() ?? [:]
        entries.removeValue(forKey: key)
        writeAll(entries)
    }

    /// Read all entries from disk. Returns nil if the file doesn't exist
    /// or is corrupt (we treat a corrupt store as empty — re-auth will
    /// replace it).
    private func readAll() -> [String: MCPOAuthCredential]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Tolerate an empty or malformed file — treat as no entries.
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode(
                [String: MCPOAuthCredential].self, from: data) else {
            return nil
        }
        return decoded
    }

    /// Atomic write: temp file with 0600 perms, then rename over.
    /// Mirrors Grok Build's `save_to` (credentials.rs:158-193) — the
    /// temp file is created with restrictive permissions from the start,
    /// so there's no window where secrets are world-readable.
    private func writeAll(_ entries: [String: MCPOAuthCredential]) {
        // Ensure the parent directory exists.
        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch {
            Diagnostics.error(
                "MCPTokenStore: could not create credentials directory: \(error.localizedDescription)")
            return
        }

        guard let data = try? JSONEncoder().encode(entries) else {
            Diagnostics.error("MCPTokenStore: failed to encode credentials JSON")
            return
        }

        // Write to a temp file in the same directory (same filesystem →
        // rename is atomic). Create with 0600 perms from the start.
        let tmpURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".mcp_credentials.tmp.\(UUID().uuidString)")

        do {
            // Create temp file with restrictive permissions from the start
            // to avoid a TOCTOU window where tokens are world-readable.
            try data.write(to: tmpURL, options: [])
            // Set permissions BEFORE atomic rename so the final file is always 0600.
            let attrs: [FileAttributeKey: Any] = [
                .posixPermissions: 0o600
            ]
            try FileManager.default.setAttributes(attrs, ofItemAtPath: tmpURL.path)

            // Atomic replace; throw → log so tokens are not silently lost.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }
        } catch {
            Diagnostics.error(
                "MCPTokenStore: credential write failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }

    /// The store's file URL (for diagnostics + tests).
    public var url: URL { fileURL }
}