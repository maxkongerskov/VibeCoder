//
//  ComposerQueueStore.swift
//
//  Pure follow-up queue: enqueue / reorder / pause / flush.
//  ChatViewModel owns hooks, InterjectionBuffer Steer, and send().
//

import Foundation

public struct ComposerQueueItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// `/compact` is Run now (slash), not Steer.
public enum ComposerQueueDispatch: Equatable, Sendable {
    case compactSlash
    case followUp
}

/// Outcome of `runNow` — ChatViewModel performs slash / send side effects.
public enum ComposerQueueRunNow: Equatable, Sendable {
    /// `/compact`/`/compress` — caller runs slash immediately (not a user bubble).
    case compactSlash(command: String)
    /// Dequeued because the turn is idle — caller `send`s.
    case send(String)
    /// Moved to front but turn still running.
    case reorderedOnly
}

public struct ComposerQueueStore: Equatable, Sendable {
    public var items: [ComposerQueueItem] = []
    public var paused: Bool = false

    public init(items: [ComposerQueueItem] = [], paused: Bool = false) {
        self.items = items
        self.paused = paused
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    // MARK: Status copy (ChatViewModel status chip)

    /// Chip after a successful enqueue.
    public static func enqueuedStatusLine(count: Int) -> String {
        count <= 1
            ? "Queued — will send after this turn"
            : "\(count) messages queued"
    }

    /// Chip while Stop is in-flight.
    public static func cancellingStatusLine(queuePaused: Bool) -> String {
        queuePaused ? "Cancelling… queue paused" : "Cancelling…"
    }

    /// Chip after a cancelled turn fully unwinds.
    public static func cancelledStatusLine(queuePaused: Bool) -> String {
        queuePaused
            ? "Task ended by user — queue paused"
            : "Task ended by user"
    }

    // MARK: Mutating

    /// Trim, reject empty. Does not run hooks — ChatViewModel does that first.
    @discardableResult
    public mutating func enqueue(_ text: String, id: UUID = UUID(), createdAt: Date = Date()) -> ComposerQueueItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = ComposerQueueItem(id: id, text: trimmed, createdAt: createdAt)
        items.append(item)
        return item
    }

    @discardableResult
    public mutating func remove(id: UUID) -> ComposerQueueItem? {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: idx)
        if items.isEmpty { paused = false }
        return item
    }

    /// SwiftUI-style move: `to` is the destination index before removal.
    @discardableResult
    public mutating func move(from: Int, to: Int) -> Bool {
        guard items.indices.contains(from) else { return false }
        guard to >= 0, to <= items.count else { return false }
        if from == to || from + 1 == to { return true }
        let item = items.remove(at: from)
        let dest = to > from ? to - 1 : to
        items.insert(item, at: dest)
        return true
    }

    @discardableResult
    public mutating func moveUp(id: UUID) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }), idx > 0 else { return false }
        items.swapAt(idx, idx - 1)
        return true
    }

    @discardableResult
    public mutating func moveDown(id: UUID) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              idx + 1 < items.count else { return false }
        items.swapAt(idx, idx + 1)
        return true
    }

    @discardableResult
    public mutating func moveToFront(id: UUID) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        guard idx > 0 else { return true }
        let item = items.remove(at: idx)
        items.insert(item, at: 0)
        return true
    }

    /// Steer = drop from the visible queue (caller injects via InterjectionBuffer).
    @discardableResult
    public mutating func takeForSteer(id: UUID) -> ComposerQueueItem? {
        remove(id: id)
    }

    @discardableResult
    public mutating func dequeueFirst() -> ComposerQueueItem? {
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        if items.isEmpty { paused = false }
        return item
    }

    /// Stop while items remain — hold until Continue.
    @discardableResult
    public mutating func pauseIfNonEmpty() -> Bool {
        guard !items.isEmpty else { return false }
        paused = true
        return true
    }

    /// Unpause. When idle, dequeue the next prompt (caller `send`s it).
    public mutating func continuePaused(isRunning: Bool) -> String? {
        paused = false
        guard !isRunning else { return nil }
        return dequeueFirst()?.text
    }

    /// After a successful turn: next item, or nil when paused / empty.
    public mutating func takeNextAfterTurn() -> String? {
        guard !paused else { return nil }
        return dequeueFirst()?.text
    }

    /// `/compact`/`/compress` run immediately. Other items move to the front
    /// and dequeue when the turn is idle.
    public mutating func runNow(id: UUID, isRunning: Bool) -> ComposerQueueRunNow? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        if Self.isCompactSlash(item.text) {
            _ = remove(id: id)
            return .compactSlash(command: Self.normalizedCompactCommand(item.text))
        }
        _ = moveToFront(id: id)
        guard !isRunning else { return .reorderedOnly }
        guard let first = dequeueFirst() else { return .reorderedOnly }
        return .send(first.text)
    }

    // MARK: Classification

    public static func dispatch(for text: String) -> ComposerQueueDispatch {
        isCompactSlash(text) ? .compactSlash : .followUp
    }

    /// `/compact` or `/compress`, optional instructions after the token.
    public static func isCompactSlash(_ text: String) -> Bool {
        let token = firstSlashToken(text)
        return token == "/compact" || token == "/compress"
    }

    /// Map `/compress [args]` → `/compact [args]` for `handleSlashCommand`.
    public static func normalizedCompactCommand(_ text: String) -> String {
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
    public static let compactConversationRequested = Notification.Name("agentos.compactConversation")
}
