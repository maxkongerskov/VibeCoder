//
//  SubagentSessionStore.swift
//
//  On-disk child-agent artifacts (ZCode-shaped, VibeCoder paths):
//  ~/Library/Application Support/VibeCoder/subagents/<parentConversationUUID>/<agent_id>/
//    transcript.jsonl  — append-only committed ChatMessage lines
//    metadata.json     — usage / tool count / duration / finishReason
//    output.txt        — last-run final text
//
//  Draft / in-flight stream snapshots are not written. IO never throws
//  into the runner.
//

import Foundation

/// Token totals for one child run (or the session baseline + this run).
public struct SubagentUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int

    public var totalTokens: Int { inputTokens + outputTokens }

    public static let zero = SubagentUsage(
        inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0
    ) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
    }

    public mutating func add(prompt: Int, completion: Int) {
        inputTokens += max(0, prompt)
        outputTokens += max(0, completion)
    }

    public static func + (lhs: SubagentUsage, rhs: SubagentUsage) -> SubagentUsage {
        SubagentUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens
        )
    }
}

/// Snapshot written to `metadata.json`.
public struct SubagentSessionMetadata: Sendable, Equatable, Codable {
    public var agentId: String
    public var parentConversationId: UUID
    public var taskId: UUID?
    public var modelId: String?
    public var status: String
    public var finishReason: String?
    public var iterations: Int
    public var totalDurationMs: Int
    public var totalTokens: Int
    public var totalToolUseCount: Int
    public var usage: SubagentUsage
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        agentId: String,
        parentConversationId: UUID,
        taskId: UUID? = nil,
        modelId: String? = nil,
        status: String,
        finishReason: String? = nil,
        iterations: Int = 0,
        totalDurationMs: Int = 0,
        totalTokens: Int = 0,
        totalToolUseCount: Int = 0,
        usage: SubagentUsage = .zero,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.agentId = agentId
        self.parentConversationId = parentConversationId
        self.taskId = taskId
        self.modelId = modelId
        self.status = status
        self.finishReason = finishReason
        self.iterations = iterations
        self.totalDurationMs = totalDurationMs
        self.totalTokens = totalTokens
        self.totalToolUseCount = totalToolUseCount
        self.usage = usage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

/// Append-only JSONL + metadata writer keyed by parent conversation + agent id.
public actor SubagentSessionStore {

    public static let shared = SubagentSessionStore()
    public static let directoryName = "subagents"

    private var directoryOverride: URL?
    private var lives: [String: Live] = [:]

    private struct Live {
        var baselineUsage: SubagentUsage
        var baselineToolCount: Int
        var baselineDurationMs: Int
        var writtenIDs: Set<UUID>
        var createdAt: Date
        var taskId: UUID?
        var modelId: String?
    }

    public init() {}

    /// Test seam. When set, artifacts land here instead of Application Support.
    public func setDirectoryOverride(_ url: URL?) {
        directoryOverride = url
    }

    public func resetForTests() {
        lives.removeAll()
        directoryOverride = nil
    }

    public func resolvedRoot() -> URL {
        directoryOverride ?? AppSupport.directory(Self.directoryName)
    }

    public func sessionDirectory(parentConversationID: UUID, agentId: String) -> URL {
        resolvedRoot()
            .appendingPathComponent(parentConversationID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.sanitize(agentId), isDirectory: true)
    }

    public func transcriptURL(parentConversationID: UUID, agentId: String) -> URL {
        sessionDirectory(parentConversationID: parentConversationID, agentId: agentId)
            .appendingPathComponent("transcript.jsonl")
    }

    public func metadataURL(parentConversationID: UUID, agentId: String) -> URL {
        sessionDirectory(parentConversationID: parentConversationID, agentId: agentId)
            .appendingPathComponent("metadata.json")
    }

    public func outputURL(parentConversationID: UUID, agentId: String) -> URL {
        sessionDirectory(parentConversationID: parentConversationID, agentId: agentId)
            .appendingPathComponent("output.txt")
    }

    /// Open (or resume) a session. Loads existing metadata / JSONL ids.
    /// Does not write `metadata.json` — call `updateProgress` for mid-run
    /// inspector telemetry or `finish` for the terminal snapshot.
    public func begin(
        parentConversationID: UUID,
        agentId: String,
        taskId: UUID? = nil,
        modelId: String? = nil
    ) {
        _ = ensureLive(
            parentConversationID: parentConversationID,
            agentId: agentId,
            taskId: taskId,
            modelId: modelId
        )
    }

    /// Append newly committed messages. Skips ids already on disk.
    public func appendCommitted(
        parentConversationID: UUID,
        agentId: String,
        messages: [ChatMessage]
    ) {
        begin(parentConversationID: parentConversationID, agentId: agentId)
        let key = Self.key(parentConversationID, agentId)
        guard var live = lives[key] else { return }
        let fresh = messages.filter { !live.writtenIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }

        let dir = sessionDirectory(parentConversationID: parentConversationID, agentId: agentId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = transcriptURL(parentConversationID: parentConversationID, agentId: agentId)
        let encoder = Self.jsonlEncoder()
        for msg in fresh {
            guard var payload = try? encoder.encode(msg) else { continue }
            payload.append(0x0A)
            if Self.appendLine(payload, to: url) {
                live.writtenIDs.insert(msg.id)
            }
        }
        lives[key] = live
    }

    /// Rewrite `metadata.json` mid-run (status stays `running`, no `completedAt`).
    /// Totals are session baseline + this run so resume keeps prior usage.
    public func updateProgress(
        parentConversationID: UUID,
        agentId: String,
        usage: SubagentUsage,
        toolCount: Int,
        durationMs: Int,
        finishReason: String?,
        iterations: Int,
        status: String = "running",
        taskId: UUID? = nil,
        modelId: String? = nil
    ) {
        writeSnapshot(
            parentConversationID: parentConversationID,
            agentId: agentId,
            usage: usage,
            toolCount: toolCount,
            durationMs: durationMs,
            finishReason: finishReason,
            iterations: iterations,
            status: status,
            taskId: taskId,
            modelId: modelId,
            completed: false
        )
    }

    /// Rewrite metadata (session totals = baseline + this run) and `output.txt`.
    public func finish(
        parentConversationID: UUID,
        agentId: String,
        output: String,
        usage: SubagentUsage,
        toolCount: Int,
        durationMs: Int,
        finishReason: String?,
        iterations: Int,
        status: String,
        taskId: UUID? = nil,
        modelId: String? = nil,
        messages: [ChatMessage] = []
    ) {
        if !messages.isEmpty {
            appendCommitted(
                parentConversationID: parentConversationID,
                agentId: agentId,
                messages: messages
            )
        }
        let meta = writeSnapshot(
            parentConversationID: parentConversationID,
            agentId: agentId,
            usage: usage,
            toolCount: toolCount,
            durationMs: durationMs,
            finishReason: finishReason,
            iterations: iterations,
            status: status,
            taskId: taskId,
            modelId: modelId,
            completed: true
        )
        writeOutput(output, parentConversationID: parentConversationID, agentId: agentId)
        let key = Self.key(parentConversationID, agentId)
        if var live = lives[key] {
            live.baselineUsage = meta.usage
            live.baselineToolCount = meta.totalToolUseCount
            live.baselineDurationMs = meta.totalDurationMs
            live.taskId = meta.taskId
            live.modelId = meta.modelId
            lives[key] = live
        }
    }

    /// Delete `subagents/<parentConversationUUID>/` and drop live handles.
    /// ConversationStore is not owned here — Persistence can call this on chat delete.
    @discardableResult
    public func pruneConversation(_ parentConversationID: UUID) -> Bool {
        let prefix = parentConversationID.uuidString.lowercased() + "|"
        lives = lives.filter { !$0.key.hasPrefix(prefix) }
        let dir = conversationDirectory(parentConversationID: parentConversationID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        do {
            try FileManager.default.removeItem(at: dir)
            return true
        } catch {
            return false
        }
    }

    public func conversationDirectory(parentConversationID: UUID) -> URL {
        resolvedRoot().appendingPathComponent(
            parentConversationID.uuidString, isDirectory: true)
    }

    public func loadMetadata(
        parentConversationID: UUID,
        agentId: String
    ) -> SubagentSessionMetadata? {
        let url = metadataURL(parentConversationID: parentConversationID, agentId: agentId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso8601.decode(SubagentSessionMetadata.self, from: data)
    }

    public func loadTranscript(
        parentConversationID: UUID,
        agentId: String
    ) -> [ChatMessage] {
        let url = transcriptURL(parentConversationID: parentConversationID, agentId: agentId)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder.iso8601
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(ChatMessage.self, from: data)
        }
    }

    public func loadOutput(parentConversationID: UUID, agentId: String) -> String? {
        let url = outputURL(parentConversationID: parentConversationID, agentId: agentId)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Private

    @discardableResult
    private func ensureLive(
        parentConversationID: UUID,
        agentId: String,
        taskId: UUID?,
        modelId: String?
    ) -> Live {
        let key = Self.key(parentConversationID, agentId)
        if var existing = lives[key] {
            if let taskId { existing.taskId = taskId }
            if let modelId { existing.modelId = modelId }
            lives[key] = existing
            return existing
        }
        let meta = loadMetadata(parentConversationID: parentConversationID, agentId: agentId)
        let written = loadWrittenIDs(from: transcriptURL(
            parentConversationID: parentConversationID, agentId: agentId))
        let live = Live(
            baselineUsage: meta?.usage ?? .zero,
            baselineToolCount: meta?.totalToolUseCount ?? 0,
            baselineDurationMs: meta?.totalDurationMs ?? 0,
            writtenIDs: written,
            createdAt: meta?.createdAt ?? Date(),
            taskId: taskId ?? meta?.taskId,
            modelId: modelId ?? meta?.modelId
        )
        lives[key] = live
        return live
    }

    @discardableResult
    private func writeSnapshot(
        parentConversationID: UUID,
        agentId: String,
        usage: SubagentUsage,
        toolCount: Int,
        durationMs: Int,
        finishReason: String?,
        iterations: Int,
        status: String,
        taskId: UUID?,
        modelId: String?,
        completed: Bool
    ) -> SubagentSessionMetadata {
        let live = ensureLive(
            parentConversationID: parentConversationID,
            agentId: agentId,
            taskId: taskId,
            modelId: modelId
        )
        let combinedUsage = live.baselineUsage + usage
        let combinedTools = live.baselineToolCount + max(0, toolCount)
        let combinedDuration = live.baselineDurationMs + max(0, durationMs)
        let now = Date()
        let meta = SubagentSessionMetadata(
            agentId: AgentMailbox.normalizeAgentId(agentId),
            parentConversationId: parentConversationID,
            taskId: taskId ?? live.taskId,
            modelId: modelId ?? live.modelId,
            status: status,
            finishReason: finishReason,
            iterations: iterations,
            totalDurationMs: combinedDuration,
            totalTokens: combinedUsage.totalTokens,
            totalToolUseCount: combinedTools,
            usage: combinedUsage,
            createdAt: live.createdAt,
            updatedAt: now,
            completedAt: completed ? now : nil
        )
        writeMetadata(meta, parentConversationID: parentConversationID, agentId: agentId)
        return meta
    }

    private func writeMetadata(
        _ meta: SubagentSessionMetadata,
        parentConversationID: UUID,
        agentId: String
    ) {
        let dir = sessionDirectory(parentConversationID: parentConversationID, agentId: agentId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = metadataURL(parentConversationID: parentConversationID, agentId: agentId)
        guard let data = try? JSONEncoder.iso8601Pretty.encode(meta) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func writeOutput(
        _ text: String,
        parentConversationID: UUID,
        agentId: String
    ) {
        let dir = sessionDirectory(parentConversationID: parentConversationID, agentId: agentId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = outputURL(parentConversationID: parentConversationID, agentId: agentId)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func loadWrittenIDs(from url: URL) -> Set<UUID> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder.iso8601
        var ids: Set<UUID> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? decoder.decode(ChatMessage.self, from: data)
            else { continue }
            ids.insert(msg.id)
        }
        return ids
    }

    private static func key(_ parent: UUID, _ agentId: String) -> String {
        "\(parent.uuidString.lowercased())|\(AgentMailbox.normalizeAgentId(agentId))"
    }

    static func sanitize(_ agentId: String) -> String {
        let normalized = AgentMailbox.normalizeAgentId(agentId)
        let scalars = normalized.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_" || scalar == "-" || scalar == "." {
                return Character(scalar)
            }
            return "_"
        }
        let name = String(scalars)
        return name.isEmpty ? "agent" : name
    }

    private static func jsonlEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = []
        return e
    }

    private static func appendLine(_ line: Data, to url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return false }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                return true
            } catch {
                return false
            }
        } else {
            do {
                try line.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }
}
