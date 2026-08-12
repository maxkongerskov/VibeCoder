//
//  LSPClientSessionPool.swift
//  Persistent LSP session cache keyed by project root.
//  Replaces spawn-per-find_symbol-call with reuse + idle eviction.
//  Honesty: SourceKit-oriented partial host — not a multi-language IDE pool.
//

import Foundation

/// Process/session pool for `LSPClient` instances.
///
/// - One client per project root path (standardized).
/// - Reused across sequential `find_symbol` / CodeNav calls.
/// - Idle timeout shuts down unused sessions (default 120s).
/// - Optional factory for tests (mock transport).
public actor LSPClientSessionPool {
    public static let shared = LSPClientSessionPool()

    public struct Stats: Sendable, Equatable {
        public var sessionCount: Int
        public var createCount: Int
        public var reuseCount: Int
        public var idleEvictCount: Int
    }

    private struct Entry {
        let client: LSPClient
        var lastUsed: Date
    }

    private var sessions: [String: Entry] = [:]
    private var createCount = 0
    private var reuseCount = 0
    private var idleEvictCount = 0
    /// Idle seconds before shutdown (default 2 minutes).
    public var idleTimeout: TimeInterval = 120
    /// How often to sweep idle sessions.
    public var idleSweepInterval: TimeInterval = 30
    private var sweepTask: Task<Void, Never>?

    /// Test/production factory. When nil, uses `SourceKitLSPHost.makeClient`.
    public var clientFactory: (@Sendable (URL) async -> LSPClient?)?

    public init() {}

    public func setClientFactory(_ factory: (@Sendable (URL) async -> LSPClient?)?) {
        clientFactory = factory
    }

    public func setIdleTimeout(_ seconds: TimeInterval) {
        idleTimeout = seconds
    }

    /// Acquire a live client for `projectRoot`, creating if needed.
    public func client(for projectRoot: URL) async -> LSPClient? {
        let key = Self.key(for: projectRoot)
        if let entry = sessions[key] {
            let alive = await entry.client.isInitialized
            if alive {
                sessions[key] = Entry(client: entry.client, lastUsed: Date())
                reuseCount += 1
                ensureSweepRunning()
                return entry.client
            }
            // Dead session — drop and recreate.
            sessions.removeValue(forKey: key)
            await entry.client.shutdown()
        }

        let created: LSPClient?
        if let factory = clientFactory {
            created = await factory(projectRoot.standardizedFileURL)
        } else {
            created = await SourceKitLSPHost.makeClient(projectRoot: projectRoot.standardizedFileURL)
        }
        guard let client = created else { return nil }
        createCount += 1
        sessions[key] = Entry(client: client, lastUsed: Date())
        ensureSweepRunning()
        return client
    }

    /// Touch last-used without creating (no-op if missing).
    public func touch(projectRoot: URL) {
        let key = Self.key(for: projectRoot)
        guard let entry = sessions[key] else { return }
        sessions[key] = Entry(client: entry.client, lastUsed: Date())
    }

    /// Forward agent edits so the pooled server sees didChange.
    public func notifyFileChanged(
        projectRoot: URL,
        file: URL,
        content: String?
    ) async {
        let key = Self.key(for: projectRoot)
        guard let entry = sessions[key] else { return }
        sessions[key] = Entry(client: entry.client, lastUsed: Date())
        let text = content ?? (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? await entry.client.notifyDocumentDidChange(file: file, text: text)
    }

    public func shutdown(projectRoot: URL) async {
        let key = Self.key(for: projectRoot)
        guard let entry = sessions.removeValue(forKey: key) else { return }
        await entry.client.shutdown()
    }

    public func shutdownAll() async {
        let all = sessions
        sessions.removeAll()
        for (_, entry) in all {
            await entry.client.shutdown()
        }
        sweepTask?.cancel()
        sweepTask = nil
    }

    public func stats() -> Stats {
        Stats(
            sessionCount: sessions.count,
            createCount: createCount,
            reuseCount: reuseCount,
            idleEvictCount: idleEvictCount
        )
    }

    /// Reset pool state for XCTest isolation.
    public func resetForTests() async {
        await shutdownAll()
        createCount = 0
        reuseCount = 0
        idleEvictCount = 0
        clientFactory = nil
        idleTimeout = 120
        idleSweepInterval = 30
    }

    // MARK: - Idle eviction

    private func ensureSweepRunning() {
        guard sweepTask == nil else { return }
        let interval = idleSweepInterval
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                let ns = UInt64(max(1, interval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                guard !Task.isCancelled else { break }
                await self?.evictIdleSessions()
            }
        }
    }

    public func evictIdleSessions(now: Date = Date()) async {
        let timeout = idleTimeout
        var toRemove: [(String, LSPClient)] = []
        for (key, entry) in sessions {
            if now.timeIntervalSince(entry.lastUsed) >= timeout {
                toRemove.append((key, entry.client))
            }
        }
        for (key, client) in toRemove {
            sessions.removeValue(forKey: key)
            idleEvictCount += 1
            await client.shutdown()
        }
        if sessions.isEmpty {
            sweepTask?.cancel()
            sweepTask = nil
        }
    }

    private static func key(for projectRoot: URL) -> String {
        projectRoot.standardizedFileURL.path
    }
}
