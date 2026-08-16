//
//  ComposerQueueStore.swift
//
//  Pure follow-up queue: enqueue / reorder / pause / flush.
//  ChatViewModel owns hooks, InterjectionBuffer Steer, and send().
//

import Foundation

struct ComposerQueueItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// `/compact` is Run now (slash), not Steer.
enum ComposerQueueDispatch: Equatable, Sendable {
    case compactSlash
    case followUp
}

struct ComposerQueueStore: Equatable, Sendable {
    var items: [ComposerQueueItem] = []
    var paused: Bool = false

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    // MARK: Mutating

    /// Trim, reject empty. Does not run hooks — ChatViewModel does that first.
    @discardableResult
    mutating func enqueue(_ text: String, id: UUID = UUID(), createdAt: Date = Date()) -> ComposerQueueItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = ComposerQueueItem(id: id, text: trimmed, createdAt: createdAt)
        items.append(item)
        return item
    }

    @discardableResult
    mutating func remove(id: UUID) -> ComposerQueueItem? {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: idx)
        if items.isEmpty { paused = false }
        return item
    }

    /// SwiftUI-style move: `to` is the destination index before removal.
    @discardableResult
    mutating func move(from: Int, to: Int) -> Bool {
        guard items.indices.contains(from) else { return false }
        guard to >= 0, to <= items.count else { return false }
        if from == to || from + 1 == to { return true }
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to)
        return true
    }

    @discardableResult
    mutating func moveUp(id: UUID) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }), idx > 0 else { return false }
        items.swapAt(idx, idx - 1)
        return true
    }

    @discardableResult
    mutating func moveDown(id: UUID) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              idx + 1 < items.count else { return false }
        items.swapAt(idx, idx + 1)
        return true
    }

    @discardableResult
    mutating func moveToFront(id: UUID) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        guard idx > 0 else { return true }
        let item = items.remove(at: idx)
        items.insert(item, at: 0)
        return true
    }

    /// Steer = drop from the visible queue (caller injects via InterjectionBuffer).
    @discardableResult
    mutating func takeForSteer(id: UUID) -> ComposerQueueItem? {
        remove(id: id)
    }

    @discardableResult
    mutating func dequeueFirst() -> ComposerQueueItem? {
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        if items.isEmpty { paused = false }
        return item
    }

    /// Stop while items remain — hold until Continue.
    @discardableResult
    mutating func pauseIfNonEmpty() -> Bool {
        guard !items.isEmpty else { return false }
        paused = true
        return true
    }

    /// Unpause. When idle, dequeue the next prompt (caller `send`s it).
    mutating func continuePaused(isRunning: Bool) -> String? {
        paused = false
        guard !isRunning else { return nil }
        return dequeueFirst()?.text
    }

    /// After a successful turn: next item, or nil when paused / empty.
    mutating func takeNextAfterTurn() -> String? {
        guard !paused else { return nil }
        return dequeueFirst()?.text
    }

    // MARK: Classification

    static func dispatch(for text: String) -> ComposerQueueDispatch {
        isCompactSlash(text) ? .compactSlash : .followUp
    }

    /// `/compact` or `/compress`, optional instructions after the token.
    static func isCompactSlash(_ text: String) -> Bool {
        let token = firstSlashToken(text)
        return token == "/compact" || token == "/compress"
    }

    /// Map `/compress [args]` → `/compact [args]` for `handleSlashCommand`.
    static func normalizedCompactCommand(_ text: String) -> String {
        guard isCompactSlash(text) else { return "/compact" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let args = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return args.isEmpty ? "/compact" : "/compact \(args)"
    }

    private static func firstSlashToken(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return "" }
        let token = trimmed.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        ).first.map(String.init) ?? ""
        return token.lowercased()
    }
}

extension Notification.Name {
    static let compactConversationRequested = Notification.Name("agentos.compactConversation")
}
