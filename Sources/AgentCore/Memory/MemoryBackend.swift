//
//  MemoryBackend.swift
//  Facade: remember / recall / dream / flush (Grok-class layout, extractive dream).
//
//  Honesty (PC3 + D3):
//  - Search is **keyword/FTS-style** (`MemoryIndex`) — no embeddings / sqlite-vec / MMR vector store.
//  - Dream default is **extractive**. Optional `MemoryConsolidating` (LLM or inject) is
//    opt-in; failures fall back to extractive. AgentLoop wires LLM only when
//    `dreamLLMEnabled` is true (default **false**).
//  - End-of-turn **flush** writes session logs every substantive turn; **dream** is gated
//    (session count, min hours since last consolidate, non-empty durable signal).
//

import Foundation

// MARK: - Capture results (structured for tests + diagnostics)

/// Why a transcript was / was not flushed to a session log.
public struct MemoryFlushDecision: Sendable, Equatable {
    public var shouldFlush: Bool
    /// Machine-readable: `ok`, `trivial_transcript`, `empty_messages`.
    public var reason: String

    public init(shouldFlush: Bool, reason: String) {
        self.shouldFlush = shouldFlush
        self.reason = reason
    }
}

/// Outcome of `endTurnCapture` — flush and dream are independent gates.
public struct EndTurnCaptureResult: Sendable, Equatable {
    public var didFlush: Bool
    public var didDream: Bool
    public var flushReason: String
    public var dreamReason: String

    public init(didFlush: Bool, didDream: Bool, flushReason: String, dreamReason: String) {
        self.didFlush = didFlush
        self.didDream = didDream
        self.flushReason = flushReason
        self.dreamReason = dreamReason
    }
}

/// Outcome of a dream attempt (consolidate session logs → MEMORY.md).
public struct DreamResult: Sendable, Equatable {
    public var didRun: Bool
    /// Machine-readable gate/consolidate reason.
    public var reason: String

    public init(didRun: Bool, reason: String) {
        self.didRun = didRun
        self.reason = reason
    }
}

// MARK: - Backend

public struct MemoryBackend: Sendable {
    public let storage: MemoryStorage
    private let indexBox: IndexBox

    private final class IndexBox: @unchecked Sendable {
        let index: MemoryIndex
        init(_ index: MemoryIndex) { self.index = index }
    }

    public init(workspacePath: URL, root: URL? = nil) {
        let storage = MemoryStorage(workspacePath: workspacePath, root: root)
        try? storage.ensureDirs()
        let index = MemoryIndex(indexURL: storage.indexFile)
        index.reindex(storage: storage)
        self.storage = storage
        self.indexBox = IndexBox(index)
    }

    public init(storage: MemoryStorage, index: MemoryIndex) {
        self.storage = storage
        self.indexBox = IndexBox(index)
    }

    public var index: MemoryIndex { indexBox.index }

    public func recallBlock(query: String, budgetChars: Int = 2_400, maxResults: Int = 6) -> String? {
        index.reindex(storage: storage)
        let hits = index.search(query: query, maxResults: maxResults)
        guard !hits.isEmpty else { return nil }
        var out = """
        # Retrieved project memory (not exhaustive)
        Use if relevant; call `memory_search` for more. Sources are tagged.
        """
        var used = out.count
        for h in hits {
            let line = "\n- [\(h.chunk.source)] \(h.snippet.replacingOccurrences(of: "\n", with: " "))"
            if used + line.count > budgetChars { break }
            out += line
            used += line.count
        }
        return out
    }

    public func remember(text: String, scope: MemoryScope = .workspace) throws {
        try storage.appendMemory(scope: scope, text: text)
        let path = scope == .global
            ? storage.globalMemoryFile.path
            : storage.workspaceMemoryFile.path
        let chunks = MemoryIndex.chunkMarkdown(text, path: path, source: scope.rawValue)
        index.upsertMany(chunks)
    }

    public func rememberToolFact(_ text: String) {
        index.upsert(MemoryChunk(path: "tool://memory", source: "tool", text: text))
    }

    public func writeSessionLog(sessionId: String, content: String) throws {
        _ = try storage.writeSessionLog(sessionId: sessionId, content: content)
        index.reindex(storage: storage)
    }

    public func search(query: String, maxResults: Int = 8) -> [MemorySearchHit] {
        index.search(query: query, maxResults: maxResults)
    }

    public func get(chunkId: String) -> MemoryChunk? {
        index.allChunks().first { $0.id == chunkId }
    }

    public func flushConversation(
        sessionId: String,
        messages: [ChatMessage],
        plantedNote: String? = nil
    ) throws {
        var lines: [String] = ["# Session flush", ""]
        if let plantedNote, !plantedNote.isEmpty {
            lines.append("## Durable note")
            lines.append(plantedNote)
            lines.append("")
        }
        lines.append("## Transcript excerpts")
        for m in messages.suffix(40) {
            let role = m.role.rawValue
            let body = String(m.content.prefix(500))
            if body.isEmpty { continue }
            lines.append("- **\(role):** \(body)")
        }
        try writeSessionLog(sessionId: sessionId, content: lines.joined(separator: "\n"))
    }

    /// Decide whether end-of-turn should write a session log (independent of dream).
    public static func flushDecision(
        messages: [ChatMessage],
        minUserChars: Int = MemoryDream.defaultMinUserChars
    ) -> MemoryFlushDecision {
        if messages.isEmpty {
            return MemoryFlushDecision(shouldFlush: false, reason: "empty_messages")
        }
        let userChars = messages
            .filter { $0.role == .user }
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).count }
            .reduce(0, +)
        let hasAssistant = messages.contains {
            $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasTool = messages.contains {
            $0.role == .tool && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Substantive: enough user text, or any assistant/tool substance.
        if userChars >= minUserChars || hasAssistant || hasTool {
            return MemoryFlushDecision(shouldFlush: true, reason: "ok")
        }
        return MemoryFlushDecision(shouldFlush: false, reason: "trivial_transcript")
    }

    /// End-of-turn capture (PC3): always **try** flush on substantive turns so dream
    /// has fuel without requiring FullReplace compact first; then optionally dream.
    ///
    /// Default `minHours` is 1 so extractive dream does not append to MEMORY.md on
    /// every micro-turn. Flush still runs every substantive turn. Tests that need
    /// immediate consolidate pass `minHours: 0`.
    @discardableResult
    public func endTurnCapture(
        sessionId: String,
        messages: [ChatMessage],
        dreamEnabled: Bool,
        minUserChars: Int = MemoryDream.defaultMinUserChars,
        minSessions: Int = MemoryDream.defaultMinSessions,
        minHours: Double = MemoryDream.defaultMinHours,
        consolidator: (any MemoryConsolidating)? = nil
    ) async throws -> EndTurnCaptureResult {
        let flushGate = Self.flushDecision(messages: messages, minUserChars: minUserChars)
        var didFlush = false
        if flushGate.shouldFlush {
            let durable = messages
                .filter { $0.role == .assistant }
                .suffix(3)
                .map { String($0.content.prefix(200)) }
                .joined(separator: "\n")
            try flushConversation(
                sessionId: sessionId,
                messages: messages,
                plantedNote: durable.isEmpty ? nil : durable)
            didFlush = true
        }

        guard dreamEnabled else {
            return EndTurnCaptureResult(
                didFlush: didFlush,
                didDream: false,
                flushReason: flushGate.reason,
                dreamReason: "dream_disabled")
        }

        let dream = try await dreamIfNeeded(
            minSessions: minSessions,
            minHours: minHours,
            consolidator: consolidator)
        return EndTurnCaptureResult(
            didFlush: didFlush,
            didDream: dream.didRun,
            flushReason: flushGate.reason,
            dreamReason: dream.reason)
    }

    @discardableResult
    public func dreamIfNeeded(
        minSessions: Int = MemoryDream.defaultMinSessions,
        minHours: Double = 0,
        consolidator: (any MemoryConsolidating)? = nil
    ) async throws -> DreamResult {
        let sessionCount = storage.listSessionLogs().count
        let gate = MemoryDream.evaluate(
            lockURL: storage.dreamLockFile,
            sessionCount: sessionCount,
            minSessions: minSessions,
            minHours: minHours)
        guard gate.shouldRun else {
            return DreamResult(didRun: false, reason: gate.reason)
        }
        let logs = storage.listSessionLogs()
        guard !logs.isEmpty else {
            return DreamResult(didRun: false, reason: "no_session_logs")
        }
        var blob = ""
        var contentChars = 0
        for u in logs.suffix(MemoryDream.maxSessionLogsPerDream) {
            if let t = storage.readFile(u) {
                contentChars += t.trimmingCharacters(in: .whitespacesAndNewlines).count
                blob += "\n\n--- \(u.lastPathComponent) ---\n" + t
            }
        }
        // Gate on log *bodies* only (exclude filename banners from the threshold).
        if contentChars < MemoryDream.minSessionBlobChars {
            // Do not stamp the dream lock — a thin/cancelled turn must
            // not block a later substantive consolidation for minHours.
            return DreamResult(didRun: false, reason: "logs_too_thin")
        }
        let existing = storage.readMemory(scope: .workspace) ?? ""
        let promptInput = String((existing + "\n\n# Sessions\n" + blob).prefix(32_000))

        let (consolidated, reasonTag) = await Self.runConsolidate(
            promptInput: promptInput,
            consolidator: consolidator)

        if consolidated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || consolidated.contains("NO_REPLY") {
            return DreamResult(didRun: false, reason: reasonTag == "extractive"
                ? "extractive_no_signal"
                : "no_signal_after_fallback")
        }
        try storage.appendMemory(scope: .workspace, text: consolidated)
        // Only delete session logs that were included in the consolidation
        // blob — older logs beyond maxSessionLogsPerDream must not be wiped.
        let consumed = Array(logs.suffix(MemoryDream.maxSessionLogsPerDream))
        for u in consumed {
            try? FileManager.default.removeItem(at: u)
        }
        index.reindex(storage: storage)
        MemoryDream.recordConsolidation(lockURL: storage.dreamLockFile)
        let successReason: String
        switch reasonTag {
        case "llm": successReason = "consolidated_llm"
        case "llm_empty_extractive_fallback", "llm_error_extractive_fallback":
            successReason = reasonTag
        default:
            successReason = "consolidated_extractive"
        }
        return DreamResult(didRun: true, reason: successReason)
    }

    /// Apply optional consolidator with extractive fail-open.
    /// - Returns: (text, tag) where tag is `llm` | `extractive` | `llm_*_fallback`
    static func runConsolidate(
        promptInput: String,
        consolidator: (any MemoryConsolidating)?
    ) async -> (String, String) {
        guard let consolidator else {
            return (MemoryDream.extractiveConsolidate(promptInput), "extractive")
        }
        do {
            let out = try await consolidator.consolidate(sessionBlob: promptInput)
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("NO_REPLY") {
                return (trimmed, "llm")
            }
            // Empty / NO_REPLY → extractive fallback
            return (MemoryDream.extractiveConsolidate(promptInput), "llm_empty_extractive_fallback")
        } catch {
            return (MemoryDream.extractiveConsolidate(promptInput), "llm_error_extractive_fallback")
        }
    }

    public func injectRecovery(query: String) -> String? {
        let recovery = index.allChunks().filter { $0.source == "compaction_recovery" }
        if !recovery.isEmpty {
            let body = recovery.suffix(5).map(\.text).joined(separator: "\n\n")
            return "# Memory recovery after compaction\n\n" + body
        }
        return recallBlock(query: query)
    }

    public func markCompactionRecovery(_ text: String) {
        index.upsert(MemoryChunk(
            path: "compaction://recovery",
            source: "compaction_recovery",
            text: text))
    }
}

// MARK: - Dream gates + extractive consolidate

public enum MemoryDream {
    /// Default minimum hours between MEMORY.md consolidations (end-of-turn path).
    public static let defaultMinHours: Double = 1
    /// Default minimum session log files before dream may run.
    public static let defaultMinSessions: Int = 1
    /// Default min user chars for flush (assistant/tool substance still flushes).
    public static let defaultMinUserChars: Int = 16
    /// Cap session logs read into one dream pass.
    public static let maxSessionLogsPerDream: Int = 12
    /// Skip dream when combined session blob is thinner than this (chars).
    public static let minSessionBlobChars: Int = 48

    public struct Gate: Sendable, Equatable {
        public var shouldRun: Bool
        /// `ok` | `not_enough_sessions` | `too_soon`
        public var reason: String

        public init(shouldRun: Bool, reason: String) {
            self.shouldRun = shouldRun
            self.reason = reason
        }
    }

    /// Time + volume gates only (does not read log bodies).
    public static func evaluate(
        lockURL: URL,
        sessionCount: Int,
        minSessions: Int,
        minHours: Double,
        now: Date = Date()
    ) -> Gate {
        if sessionCount < minSessions {
            return Gate(shouldRun: false, reason: "not_enough_sessions")
        }
        if minHours > 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: lockURL.path),
           let mtime = attrs[.modificationDate] as? Date {
            let hours = now.timeIntervalSince(mtime) / 3600
            if hours < minHours {
                return Gate(shouldRun: false, reason: "too_soon")
            }
        }
        return Gate(shouldRun: true, reason: "ok")
    }

    public static func recordConsolidation(lockURL: URL) {
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "".write(to: lockURL, atomically: true, encoding: .utf8)
    }

    /// Extractive consolidate — **not** an embedding/LLM dream.
    /// Returns `NO_REPLY` when no durable signals so callers can skip MEMORY append.
    public static func extractiveConsolidate(_ input: String) -> String {
        let lines = input.split(separator: "\n").map(String.init)
        var decisions: [String] = []
        var facts: [String] = []
        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            let lower = l.lowercased()
            if lower.contains("decision") || lower.contains("decided") || lower.contains("avoid") {
                decisions.append(String(l.prefix(200)))
            } else if l.hasPrefix("- **") || l.hasPrefix("**Decision") {
                facts.append(String(l.prefix(200)))
            }
        }
        if decisions.isEmpty && facts.isEmpty {
            let userish = lines.filter { $0.contains("**user:**") || $0.contains("- **user:**") }
            if userish.isEmpty { return "NO_REPLY" }
            return "Session notes:\n" + userish.suffix(5).map { "- \($0)" }.joined(separator: "\n")
        }
        var out = "Consolidated memory\n"
        if !decisions.isEmpty {
            out += "\n### Decisions\n" + decisions.suffix(8).map { "- \($0)" }.joined(separator: "\n")
        }
        if !facts.isEmpty {
            out += "\n### Facts\n" + facts.suffix(8).map { "- \($0)" }.joined(separator: "\n")
        }
        return out
    }
}
