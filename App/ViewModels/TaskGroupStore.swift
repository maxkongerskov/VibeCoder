//
//  TaskGroupStore.swift
//
//  App-only sidecar for sidebar task groups + unread markers.
//  Conversation JSON is not touched — membership and last-read live here.
//

import Foundation
import AgentCore

/// ZCode's seven group colors. Swatches map to existing Theme tokens in the view.
enum TaskGroupColor: String, Codable, CaseIterable, Sendable, Equatable {
    case gray, red, orange, yellow, green, blue, purple

    var title: String { rawValue.capitalized }
}

struct TaskGroupRecord: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var color: TaskGroupColor
    var sortIndex: Int

    init(id: UUID = UUID(),
         name: String,
         color: TaskGroupColor = .blue,
         sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.sortIndex = sortIndex
    }
}

struct TaskGroupSnapshot: Codable, Equatable, Sendable {
    var groups: [TaskGroupRecord]
    /// conversationID → groupID
    var membership: [UUID: UUID]
    /// conversationID → last time the user opened the task.
    /// Missing key = never marked; treated as read so existing tasks
    /// are not all unread on first launch.
    var lastReadAt: [UUID: Date]

    static let empty = TaskGroupSnapshot(groups: [], membership: [:], lastReadAt: [:])

    init(groups: [TaskGroupRecord] = [],
         membership: [UUID: UUID] = [:],
         lastReadAt: [UUID: Date] = [:]) {
        self.groups = groups
        self.membership = membership
        self.lastReadAt = lastReadAt
    }

    enum CodingKeys: String, CodingKey {
        case groups, membership, lastReadAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([TaskGroupRecord].self, forKey: .groups) ?? []
        membership = try c.decodeIfPresent([UUID: UUID].self, forKey: .membership) ?? [:]
        lastReadAt = try c.decodeIfPresent([UUID: Date].self, forKey: .lastReadAt) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groups, forKey: .groups)
        try c.encode(membership, forKey: .membership)
        try c.encode(lastReadAt, forKey: .lastReadAt)
    }

    func orderedGroups() -> [TaskGroupRecord] {
        groups.sorted { a, b in
            if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func group(id: UUID) -> TaskGroupRecord? {
        groups.first { $0.id == id }
    }

    func group(for conversationID: UUID) -> TaskGroupRecord? {
        guard let gid = membership[conversationID] else { return nil }
        return group(id: gid)
    }

    /// Groups that have at least one member in `conversationIDs`. Empty groups stay hidden.
    func populatedGroups(among conversationIDs: Set<UUID>) -> [TaskGroupRecord] {
        orderedGroups().filter { group in
            membership.contains { id, gid in gid == group.id && conversationIDs.contains(id) }
        }
    }

    func isUnread(conversationID: UUID, updatedAt: Date) -> Bool {
        guard let read = lastReadAt[conversationID] else { return false }
        return updatedAt > read
    }

    func uniqueGroupName(base: String = "New group") -> String {
        let existing = Set(groups.map { $0.name.lowercased() })
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "New group" : trimmed
        if !existing.contains(root.lowercased()) { return root }
        var n = 2
        while existing.contains("\(root) \(n)".lowercased()) { n += 1 }
        return "\(root) \(n)"
    }

    @discardableResult
    mutating func createGroup(
        name: String = "New group",
        color: TaskGroupColor = .blue,
        id: UUID = UUID(),
        assigning conversationID: UUID? = nil
    ) -> TaskGroupRecord {
        let nextIndex = (groups.map(\.sortIndex).max() ?? -1) + 1
        let record = TaskGroupRecord(
            id: id,
            name: uniqueGroupName(base: name),
            color: color,
            sortIndex: nextIndex
        )
        groups.append(record)
        if let conversationID {
            assign(conversationID: conversationID, to: record.id)
        }
        return record
    }

    @discardableResult
    mutating func renameGroup(id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = groups.firstIndex(where: { $0.id == id }) else {
            return false
        }
        groups[idx].name = trimmed
        return true
    }

    @discardableResult
    mutating func setColor(id: UUID, color: TaskGroupColor) -> Bool {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[idx].color = color
        return true
    }

    @discardableResult
    mutating func deleteGroup(id: UUID) -> Bool {
        guard groups.contains(where: { $0.id == id }) else { return false }
        groups.removeAll { $0.id == id }
        membership = membership.filter { _, gid in gid != id }
        return true
    }

    @discardableResult
    mutating func assign(conversationID: UUID, to groupID: UUID) -> Bool {
        guard groups.contains(where: { $0.id == groupID }) else { return false }
        membership[conversationID] = groupID
        return true
    }

    mutating func unassign(conversationID: UUID) {
        membership.removeValue(forKey: conversationID)
    }

    /// Drop membership / last-read for conversations that no longer exist.
    mutating func prune(existingIDs: Set<UUID>) {
        membership = membership.filter { existingIDs.contains($0.key) }
        lastReadAt = lastReadAt.filter { existingIDs.contains($0.key) }
    }

    mutating func markRead(conversationID: UUID, updatedAt: Date, now: Date = Date()) {
        lastReadAt[conversationID] = max(now, updatedAt)
    }

    mutating func markUnread(conversationID: UUID, updatedAt: Date) {
        lastReadAt[conversationID] = updatedAt.addingTimeInterval(-1)
    }
}

enum TaskGroupCodec {
    static func encode(_ snapshot: TaskGroupSnapshot) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> TaskGroupSnapshot {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(TaskGroupSnapshot.self, from: data)
    }
}

enum TaskGroupLayout {
    struct Section: Identifiable {
        enum Kind: Equatable {
            case namedGroup(id: UUID, name: String, color: TaskGroupColor)
            case timeBucket(label: String)
        }

        var kind: Kind
        var conversations: [Conversation]

        var id: String {
            switch kind {
            case .namedGroup(let id, _, _): return "g-\(id.uuidString)"
            case .timeBucket(let label): return "t-\(label)"
            }
        }
    }

    /// Named groups (with visible members) first, then time buckets for the rest.
    /// Empty groups are omitted. `unpinned` order is preserved inside each section.
    static func sections(
        unpinned: [Conversation],
        snapshot: TaskGroupSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Section] {
        let visibleIDs = Set(unpinned.map(\.id))
        var out: [Section] = []
        for group in snapshot.populatedGroups(among: visibleIDs) {
            let members = unpinned.filter { snapshot.membership[$0.id] == group.id }
            out.append(Section(
                kind: .namedGroup(id: group.id, name: group.name, color: group.color),
                conversations: members
            ))
        }
        let ungrouped = unpinned.filter { snapshot.membership[$0.id] == nil }
        out.append(contentsOf: timeBuckets(ungrouped, now: now, calendar: calendar))
        return out
    }

    static func timeBuckets(
        _ convs: [Conversation],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Section] {
        guard !convs.isEmpty else { return [] }
        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var week: [Conversation] = []
        var month: [Conversation] = []
        var older: [Conversation] = []

        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now)

        for c in convs {
            if calendar.isDate(c.updatedAt, inSameDayAs: now) {
                today.append(c)
            } else if let yesterdayDate, calendar.isDate(c.updatedAt, inSameDayAs: yesterdayDate) {
                yesterday.append(c)
            } else if let d = calendar.dateComponents([.day], from: c.updatedAt, to: now).day, d < 7 {
                week.append(c)
            } else if let d = calendar.dateComponents([.day], from: c.updatedAt, to: now).day, d < 30 {
                month.append(c)
            } else {
                older.append(c)
            }
        }

        var result: [Section] = []
        if !today.isEmpty { result.append(Section(kind: .timeBucket(label: "Today"), conversations: today)) }
        if !yesterday.isEmpty { result.append(Section(kind: .timeBucket(label: "Yesterday"), conversations: yesterday)) }
        if !week.isEmpty { result.append(Section(kind: .timeBucket(label: "Past 7 days"), conversations: week)) }
        if !month.isEmpty { result.append(Section(kind: .timeBucket(label: "Past 30 days"), conversations: month)) }
        if !older.isEmpty { result.append(Section(kind: .timeBucket(label: "Older"), conversations: older)) }
        return result
    }
}

@MainActor
final class TaskGroupStore: ObservableObject {
    static let shared = TaskGroupStore()

    @Published private(set) var snapshot: TaskGroupSnapshot

    private let fileURL: URL
    private let autosave: Bool

    init(fileURL: URL? = nil, autosave: Bool = true) {
        self.fileURL = fileURL ?? AppSupport.file("sidebarTaskGroups.json")
        self.autosave = autosave
        self.snapshot = Self.load(from: self.fileURL)
    }

    @discardableResult
    func createGroup(
        name: String = "New group",
        color: TaskGroupColor = .blue,
        assigning conversationID: UUID? = nil
    ) -> TaskGroupRecord {
        var next = snapshot
        let record = next.createGroup(name: name, color: color, assigning: conversationID)
        apply(next)
        return record
    }

    @discardableResult
    func renameGroup(id: UUID, to name: String) -> Bool {
        var next = snapshot
        guard next.renameGroup(id: id, to: name) else { return false }
        apply(next)
        return true
    }

    @discardableResult
    func setColor(id: UUID, color: TaskGroupColor) -> Bool {
        var next = snapshot
        guard next.setColor(id: id, color: color) else { return false }
        apply(next)
        return true
    }

    @discardableResult
    func deleteGroup(id: UUID) -> Bool {
        var next = snapshot
        guard next.deleteGroup(id: id) else { return false }
        apply(next)
        return true
    }

    @discardableResult
    func assign(conversationID: UUID, to groupID: UUID) -> Bool {
        var next = snapshot
        guard next.assign(conversationID: conversationID, to: groupID) else { return false }
        apply(next)
        return true
    }

    func unassign(conversationID: UUID) {
        var next = snapshot
        next.unassign(conversationID: conversationID)
        apply(next)
    }

    func prune(existingIDs: Set<UUID>) {
        var next = snapshot
        next.prune(existingIDs: existingIDs)
        guard next != snapshot else { return }
        apply(next)
    }

    func markRead(conversationID: UUID, updatedAt: Date, now: Date = Date()) {
        var next = snapshot
        next.markRead(conversationID: conversationID, updatedAt: updatedAt, now: now)
        apply(next)
    }

    func markUnread(conversationID: UUID, updatedAt: Date) {
        var next = snapshot
        next.markUnread(conversationID: conversationID, updatedAt: updatedAt)
        apply(next)
    }

    func isUnread(conversationID: UUID, updatedAt: Date) -> Bool {
        snapshot.isUnread(conversationID: conversationID, updatedAt: updatedAt)
    }

    private func apply(_ next: TaskGroupSnapshot) {
        snapshot = next
        guard autosave else { return }
        persist()
    }

    func persist() {
        do {
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = try TaskGroupCodec.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Diagnostics.warn("TaskGroupStore: write failed: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> TaskGroupSnapshot {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return .empty
        }
        do {
            return try TaskGroupCodec.decode(data)
        } catch {
            Diagnostics.warn("TaskGroupStore: read failed: \(error.localizedDescription)")
            return .empty
        }
    }
}
