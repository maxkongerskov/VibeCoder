//
//  MCPCrossProcessLock.swift
//
//  Cross-process mutual exclusion for MCP OAuth flows, ported from Grok
//  Build's `authenticate_with_fs_lock` (oauth.rs:148-233). When two
//  VibeCoder instances both need to authenticate the same MCP server, we
//  don't want two browser tabs opening for the same OAuth flow — only one
//  process should run the auth, and the other should wait and reuse the
//  resulting token.
//
//  Implementation: a lock file at `~/.vibecoder/mcp_auth_{safe_name}.lock`,
//  held open as a file descriptor, with `flock(2)` (`LOCK_EX`) for mutual
//  exclusion across processes. flock is advisory on macOS — but since all
//  VibeCoder instances use this same wrapper, they all participate.
//
//  Why flock instead of a lock file + unlink: flock is automatically
//  released when the process dies (even on crash), so we never get stuck
//  waiting for a lock held by a dead process. Unlink-based locks can wedge
//  forever if a process crashes between acquiring and releasing.
//
//  The flow (matching Grok Build's "token-before / token-after" pattern):
//
//    1. Snapshot the current access token from disk.
//    2. Acquire LOCK_EX (blocks if another process holds it).
//    3. Re-read the token from disk — if a *different* token appeared,
//       another process completed auth while we waited; reuse it.
//    4. Otherwise, run the actual auth flow (browser + callback).
//
//  This file is `Sendable` because all its state is immutable once
//  initialized; the lock itself is an FD held in a class wrapper.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A cross-process exclusive lock backed by `flock(2)` on a well-known
/// file path. Safe to hold across async suspension points — flock is
/// kernel-level, not tied to the calling thread.
///
/// Usage:
/// ```swift
/// let lock = MCPCrossProcessLock(serverName: "github")
/// try await lock.withLock {
///     // Only one process executes this at a time.
///     // Run the OAuth flow here.
/// }
/// ```
public final class MCPCrossProcessLock: @unchecked Sendable {

    /// The lock file path. `~/.vibecoder/mcp_auth_{safe_name}.lock`.
    public let lockFilePath: URL

    /// Sanitized server name (alphanumerics + `-_` only; other chars
    /// become `_`). Matches Grok Build's `auth_lock_path` sanitization.
    public let safeName: String

    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "MCPCrossProcessLock.fd")

    /// Initialize a lock for the given server name.
    public init(serverName: String, baseDir: URL? = nil) {
        self.safeName = Self.sanitize(serverName)

        let dir = baseDir ?? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return home.appendingPathComponent(".vibecoder", isDirectory: true)
        }()
        self.lockFilePath = dir.appendingPathComponent(
            "mcp_auth_\(safeName).lock")
    }

    /// Sanitize a server name for use in a lock file path.
    /// Per Grok Build: alphanumerics and `-`/`_` pass through; everything
    /// else becomes `_`. This prevents path traversal via `../` in a
    /// server name.
    public static func sanitize(_ name: String) -> String {
        var result = ""
        for char in name {
            if char.isLetter || char.isNumber || char == "-" || char == "_" {
                result.append(char)
            } else {
                result.append("_")
            }
        }
        // Empty name → use a placeholder so we always create a real file.
        return result.isEmpty ? "unnamed" : result
    }

    /// Acquire the lock, run `action`, then release.
    ///
    /// The lock is held for the duration of `action` — including any
    /// async suspension points inside it. flock is kernel-level, so the
    /// lock survives Swift concurrency context switches.
    ///
    /// - Parameter timeout: Fail closed if the lock is not free in time
    ///   (never `flock` forever — that wedged XCTest after MCPOAuthTests).
    /// - Parameter action: The work to do while holding the lock.
    public func withLock<T>(
        timeout: TimeInterval = 30,
        _ action: @escaping () async throws -> T
    ) async throws -> T {
        try acquire(timeout: timeout)
        defer { release() }
        return try await action()
    }

    /// Acquire the exclusive lock. Uses non-blocking `flock` + a deadline
    /// so a stuck peer (or same-process second FD) cannot hang testers or
    /// the agent loop forever.
    public func acquire(timeout: TimeInterval = 30) throws {
        let fd: Int32 = try queue.sync {
            let dir = lockFilePath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let fd = open(lockFilePath.path, O_RDWR | O_CREAT, 0o600)
            guard fd >= 0 else {
                throw MCPOAuthError.lockAcquisitionFailed(
                    "open() failed: \(String(cString: strerror(errno)))")
            }
            return fd
        }

        let budget = max(0.05, timeout)
        let deadline = Date().addingTimeInterval(budget)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                queue.sync {
                    if fileDescriptor >= 0, fileDescriptor != fd {
                        close(fileDescriptor)
                    }
                    fileDescriptor = fd
                }
                return
            }
            let err = errno
            if err != EWOULDBLOCK && err != EAGAIN {
                close(fd)
                throw MCPOAuthError.lockAcquisitionFailed(
                    "flock(LOCK_EX) failed: \(String(cString: strerror(err)))")
            }
            if Date() >= deadline {
                close(fd)
                throw MCPOAuthError.lockAcquisitionFailed(
                    "timed out after \(budget)s waiting for lock")
            }
            usleep(50_000)
        }
    }

    /// Release the lock and close the file descriptor.
    public func release() {
        queue.sync {
            if fileDescriptor >= 0 {
                // flock is released by close(); LOCK_UN isn't needed.
                close(fileDescriptor)
                fileDescriptor = -1
            }
        }
    }

    deinit {
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }
}

/// Errors raised by the cross-process lock.
public enum MCPOAuthError: Error, LocalizedError {
    case lockAcquisitionFailed(String)
    case callbackServerStartFailed(String)
    case tokenExchangeFailed(String)
    case noRefreshToken
    case missingOAuthConfig

    public var errorDescription: String? {
        switch self {
        case .lockAcquisitionFailed(let s):
            return "Could not acquire cross-process lock: \(s)"
        case .callbackServerStartFailed(let s):
            return "Could not start OAuth callback server: \(s)"
        case .tokenExchangeFailed(let s):
            return "OAuth token exchange failed: \(s)"
        case .noRefreshToken:
            return "No refresh token available — user must re-authenticate"
        case .missingOAuthConfig:
            return "Server has no OAuth configuration (client ID, auth/token URLs)"
        }
    }
}