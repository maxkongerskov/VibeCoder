//
//  AgentMailbox.swift
//
//  In-memory + optional disk inbox keyed by `agent_<uuid>`.
//  Wave-2 SubAgentRunner drains; send_message enqueues.
//

import Foundation

/// Inter-agent inbox. Thread-safe via actor isolation.
public actor AgentMailbox {

    public static let shared = AgentMailbox()

    public static let extrasResumeKey = "mailbox_resume"

    /// One queued note from parent (or another agent) to `to`.
    public struct Message: Sendable, Equatable, Codable, Identifiable {
        public let id: UUID
        public let to: String
        public let from: String?
        public let summary: String
        public let message: String
        public let createdAt: Date

        public init(
            id: UUID = UUID(),
            to: String,
            from: String? = nil,
            summary: String,
            message: String,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.to = to
            self.from = from
            self.summary = summary
            self.message = message
            self.createdAt = createdAt
        }
    }

    public struct SendResult: Sendable, Equatable {
        public let message: Message
        /// True when the target was already marked completed (resume requested).
        public let resumeRequested: Bool
    }

    public struct AgentState: Sendable, Equatable {
        public var messages: [Message]
        public var completed: Bool
        public var resumeRequested: Bool

        public static let empty = AgentState(messages: [], completed: false, resumeRequested: false)
    }

    private struct Box: Sendable, Equatable, Codable {
        var messages: [Message]
        var completed: Bool
        var resumeRequested: Bool

        static let empty = Box(messages: [], completed: false, resumeRequested: false)

        var state: AgentState {
            AgentState(messages: messages, completed: completed, resumeRequested: resumeRequested)
        }
    }

    private var boxes: [String: Box]
    private var diskRoot: URL?

    public init(diskRoot: URL? = nil) {
        self.diskRoot = diskRoot
        self.boxes = diskRoot.map { Self.loadAll(from: $0) } ?? [:]
    }

    /// Enable or move optional JSON persistence (`<diskRoot>/<agentId>.json`).
    public func setDiskRoot(_ url: URL?) {
        diskRoot = url
        if let url {
            let disk = Self.loadAll(from: url)
            for (id, box) in disk {
                boxes[id] = box
            }
        }
    }

    /// Queue a message. If the target is marked completed, sets `resumeRequested`.
    @discardableResult
    public func send(
        to: String,
        summary: String,
        message: String,
        from: String? = nil
    ) -> SendResult {
        let agentId = Self.normalizeAgentId(to)
        let item = Message(
            to: agentId,
            from: from.flatMap { AgentProfileSettings.nonEmpty($0) },
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            message: message
        )
        var box = boxes[agentId] ?? .empty
        box.messages.append(item)
        if box.completed {
            box.resumeRequested = true
        }
        boxes[agentId] = box
        persist(agentId: agentId, box: box)
        return SendResult(message: item, resumeRequested: box.resumeRequested)
    }

    /// Pop and return pending messages (completion / resume flags stay).
    public func drain(agentId: String) -> [Message] {
        let id = Self.normalizeAgentId(agentId)
        guard var box = boxes[id], !box.messages.isEmpty else { return [] }
        let out = box.messages
        box.messages = []
        boxes[id] = box
        persist(agentId: id, box: box)
        return out
    }

    public func peek(agentId: String) -> [Message] {
        state(agentId: agentId).messages
    }

    public func state(agentId: String) -> AgentState {
        let id = Self.normalizeAgentId(agentId)
        return boxes[id]?.state ?? .empty
    }

    public func resumeRequested(agentId: String) -> Bool {
        state(agentId: agentId).resumeRequested
    }

    public func isCompleted(agentId: String) -> Bool {
        state(agentId: agentId).completed
    }

    public func markCompleted(_ agentId: String) {
        setCompleted(agentId, completed: true)
    }

    public func markRunning(_ agentId: String) {
        setCompleted(agentId, completed: false)
        clearResumeRequested(agentId)
    }

    public func setCompleted(_ agentId: String, completed: Bool) {
        let id = Self.normalizeAgentId(agentId)
        var box = boxes[id] ?? .empty
        box.completed = completed
        boxes[id] = box
        persist(agentId: id, box: box)
    }

    public func clearResumeRequested(_ agentId: String) {
        let id = Self.normalizeAgentId(agentId)
        guard var box = boxes[id], box.resumeRequested else { return }
        box.resumeRequested = false
        boxes[id] = box
        persist(agentId: id, box: box)
    }

    /// Return and clear the resume flag (wave-2 spawn consumes it).
    public func consumeResumeRequest(agentId: String) -> Bool {
        let id = Self.normalizeAgentId(agentId)
        guard var box = boxes[id], box.resumeRequested else { return false }
        box.resumeRequested = false
        boxes[id] = box
        persist(agentId: id, box: box)
        return true
    }

    public func reset() {
        boxes.removeAll()
        if let diskRoot {
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(
                at: diskRoot, includingPropertiesForKeys: nil
            ) {
                for f in files where f.pathExtension == "json" {
                    try? fm.removeItem(at: f)
                }
            }
        }
    }

    public static func makeAgentId(_ uuid: UUID = UUID()) -> String {
        "agent_\(uuid.uuidString.lowercased())"
    }

    /// Trim; prefix a bare UUID with `agent_`.
    public static func normalizeAgentId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: trimmed) != nil {
            return "agent_\(trimmed.lowercased())"
        }
        return trimmed
    }

    // MARK: - Disk

    private func persist(agentId: String, box: Box) {
        guard let diskRoot else { return }
        Self.write(box: box, agentId: agentId, to: diskRoot)
    }

    private static func loadAll(from root: URL) -> [String: Box] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [:] }
        var out: [String: Box] = [:]
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let persisted = try? JSONDecoder.iso8601.decode(Persisted.self, from: data)
            else { continue }
            out[persisted.agentId] = Box(
                messages: persisted.messages,
                completed: persisted.completed,
                resumeRequested: persisted.resumeRequested
            )
        }
        return out
    }

    private static func write(box: Box, agentId: String, to root: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let persisted = Persisted(
            agentId: agentId,
            messages: box.messages,
            completed: box.completed,
            resumeRequested: box.resumeRequested
        )
        guard let data = try? JSONEncoder.iso8601Pretty.encode(persisted) else { return }
        let url = root.appendingPathComponent(fileName(for: agentId))
        try? data.write(to: url, options: .atomic)
    }

    private static func fileName(for agentId: String) -> String {
        let scalars = agentId.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
                || scalar == "-" || scalar == "." {
                return Character(scalar)
            }
            return "_"
        }
        return String(scalars) + ".json"
    }

    private struct Persisted: Codable {
        var agentId: String
        var messages: [Message]
        var completed: Bool
        var resumeRequested: Bool
    }
}
