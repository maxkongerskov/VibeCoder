//
//  DurableGrantStore.swift
//  Persist RememberedGrants across process restarts.
//

import Foundation

public actor DurableGrantStore {
    public static let shared = DurableGrantStore()

    private let fileURL: URL
    private var cache: [String: GrantDecision] = [:]
    /// Last disk write/load failure (nil when last persist succeeded).
    /// Wave C2: stop silent durability loss without failing the agent hard.
    private var lastPersistErrorStorage: String?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = AppSupport.file("durable-grants.json")
        }
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            var out: [String: GrantDecision] = [:]
            for (k, v) in decoded {
                if let d = GrantDecision(rawValue: v) { out[k] = d }
            }
            self.cache = out
            self.lastPersistErrorStorage = nil
        } else if let data = try? Data(contentsOf: self.fileURL),
                  let decoded = try? JSONDecoder().decode([String: GrantDecision].self, from: data) {
            self.cache = decoded
            self.lastPersistErrorStorage = nil
        } else {
            self.cache = [:]
            // Missing file on first run is normal; only flag if path exists but unreadable.
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                self.lastPersistErrorStorage = "Failed to decode durable-grants.json at \(self.fileURL.path)"
            } else {
                self.lastPersistErrorStorage = nil
            }
        }
    }

    /// Diagnostics for hosts/tests when Always/Never may not have reached disk.
    public func lastPersistError() -> String? { lastPersistErrorStorage }

    /// True when the last `persist()` completed without error.
    public func lastPersistSucceeded() -> Bool { lastPersistErrorStorage == nil }

    public func decision(for key: GrantKey) -> GrantDecision? {
        cache[Self.encodeKey(key)]
    }

    /// All grants for a project key (tool-level and path/dir fingerprints).
    public func snapshot(projectKey: String) -> [GrantKey: GrantDecision] {
        var out: [GrantKey: GrantDecision] = [:]
        for (encoded, decision) in cache {
            guard let key = Self.decodeKey(encoded), key.projectKey == projectKey else { continue }
            out[key] = decision
        }
        return out
    }

    /// Disk + in-memory (for tests / explicit Always-allow path).
    public func remember(_ decision: GrantDecision, for key: GrantKey) {
        cache[Self.encodeKey(key)] = decision
        persist()
        Task { await RememberedGrants.shared.rememberInMemoryOnly(decision, for: key) }
    }

    /// Called from RememberedGrants to avoid re-entrancy loops.
    public func rememberProcessMirror(_ decision: GrantDecision, for key: GrantKey) {
        cache[Self.encodeKey(key)] = decision
        persist()
    }

    public func loadIntoRememberedGrants() async {
        for (k, d) in cache {
            if let key = Self.decodeKey(k) {
                await RememberedGrants.shared.rememberInMemoryOnly(d, for: key)
            }
        }
    }

    /// Remove durable entries (whole store or one project). Used when
    /// `RememberedGrants.clear` runs so tests / "forget grants" don't leave
    /// disk state that rehydrates on the next ToolRegistry check.
    public func clear(projectKey: String? = nil) {
        if let projectKey {
            cache = cache.filter { encoded, _ in
                guard let key = Self.decodeKey(encoded) else { return true }
                return key.projectKey != projectKey
            }
        } else {
            cache.removeAll()
        }
        persist()
    }

    /// Remove a single Always/Never grant from durable disk (Polish P1).
    /// Returns true when the key was present and removed.
    @discardableResult
    public func forget(_ key: GrantKey) -> Bool {
        let encoded = Self.encodeKey(key)
        guard cache.removeValue(forKey: encoded) != nil else { return false }
        persist()
        return true
    }

    public static func encodeKey(_ key: GrantKey) -> String {
        let fp = key.commandFingerprint ?? ""
        return [key.projectKey, key.toolName, fp].joined(separator: "\u{1e}")
    }

    public static func decodeKey(_ s: String) -> GrantKey? {
        let parts = s.components(separatedBy: "\u{1e}")
        guard parts.count >= 2 else { return nil }
        let fp = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : nil
        return GrantKey(projectKey: parts[0], toolName: parts[1], commandFingerprint: fp)
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var raw: [String: String] = [:]
            for (k, v) in cache { raw[k] = v.rawValue }
            let data = try JSONEncoder().encode(raw)
            try data.write(to: fileURL, options: .atomic)
            lastPersistErrorStorage = nil
            return true
        } catch {
            lastPersistErrorStorage = error.localizedDescription
            return false
        }
    }
}
