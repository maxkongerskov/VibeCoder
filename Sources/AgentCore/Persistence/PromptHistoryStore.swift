//
//  PromptHistoryStore.swift
//
//  JSON-file persistence for the user's prompt history (the text they've
//  typed into the composer), shared across all conversations. ZCode's parity
//  surface: ↑/↓ arrows in the composer cycle through recent prompts.
//
//  One JSON file at `<baseDirectory>/VibeCoder/prompt-history.json` holds a
//  capped, most-recent-first list of prompts. The store is an actor so every
//  read/write serialises cleanly under Swift 6 strict concurrency.
//

import Foundation

public actor PromptHistoryStore {

    /// Process-wide default instance backed by
    /// `~/Library/Application Support/VibeCoder/prompt-history.json`.
    public static let shared = PromptHistoryStore()

    /// On-disk file this store reads/writes.
    public let fileURL: URL

    /// Maximum number of prompts kept in history. Older entries are
    /// trimmed on load — this is the ZCode-style cap that keeps the file
    /// small and the ↑/↓ cycle productive.
    private let maxEntries = 200

    /// Serializes read-modify-write across PromptHistoryStore instances
    /// that share a file URL (two actors would otherwise clobber each other).
    private static let fileLock = NSLock()

    public init(fileURL: URL? = nil) {
        if let custom = fileURL {
            self.fileURL = custom
        } else {
            self.fileURL = AppSupport.file("prompt-history.json")
        }
    }

    // MARK: - Public API

    /// Load the full prompt history, most-recent first.
    public func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            let prompts = try JSONDecoder().decode([String].self, from: data)
            return Array(prompts.prefix(maxEntries))
        } catch {
            // Corrupt file — start fresh rather than crash.
            return []
        }
    }

    /// Record a prompt. Deduplicates (moves an existing identical entry to
    /// the top) so repeats don't pollute the cycle, then persists.
    public func record(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        var current = load()
        // Remove any existing identical entry so the new one goes to top.
        current.removeAll { $0 == trimmed }
        current.insert(trimmed, at: 0)
        // Trim to cap.
        if current.count > maxEntries {
            current = Array(current.prefix(maxEntries))
        }
        persist(current)
    }

    public func clear() {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        persist([])
    }

    // MARK: - Private

    private func persist(_ prompts: [String]) {
        do {
            let data = try JSONEncoder().encode(prompts)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort — a failed write just means the next session
            // won't see this prompt. No crash.
        }
    }
}