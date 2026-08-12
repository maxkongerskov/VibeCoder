// AgentTraceService.swift
// AgentCore
//
// Append-only per-iteration trace of the agent loop. One JSONL line per
// iteration, written to `<directoryURL>/<conversation-id>.jsonl`.
//
// The motivating bug class: model loops, picks the wrong tool, ignores an
// instruction — and the user has only the rendered chat to debug from.
// NotificationService says WHAT happened (turn complete / cap hit / looped).
// Trace says WHY: which tools were on the table this turn, which the model
// picked, what arguments it chose, what came back. Hashes the system
// prompt so the user can detect "did the prompt change mid-conversation?"
// without bloating the file with the full prompt every iteration.
//
// Integration with `DiagnosticsHub`:
//   Every append also emits a `DiagnosticEvent` at `.info` severity to the
//   shared hub, so the in-app diagnostics panel surfaces traces alongside
//   warnings and errors. Encode/IO failures emit `.warning` events rather
//   than silently dropping — tracing must never break the agent loop, but
//   we shouldn't lose the signal that traces are failing to land on disk.
//
// Default off at the call site (gate behind a settings flag). When on,
// write cost is one small JSON line per turn — negligible compared to
// the model call itself.

import Foundation
import CryptoKit

/// One trace line. JSON-encoded as a single JSONL row.
public struct AgentTraceEntry: Codable, Equatable, Sendable {
    public let ts: String
    public let turn: Int
    public let modelId: String
    public let preset: String
    public let systemPromptChars: Int
    public let systemPromptHash: String
    public let messagesCount: Int
    public let lastUserMessage: String
    public let toolsOffered: [String]
    public let assistantContent: String
    public let toolCalls: [ToolCallSummary]
    public let error: String?
    public let durationMs: Int

    public struct ToolCallSummary: Codable, Equatable, Sendable {
        public let name: String
        public let argumentsPreview: String

        public init(name: String, argumentsPreview: String) {
            self.name = name
            self.argumentsPreview = argumentsPreview
        }
    }

    public init(
        ts: String,
        turn: Int,
        modelId: String,
        preset: String,
        systemPromptChars: Int,
        systemPromptHash: String,
        messagesCount: Int,
        lastUserMessage: String,
        toolsOffered: [String],
        assistantContent: String,
        toolCalls: [ToolCallSummary],
        error: String?,
        durationMs: Int
    ) {
        self.ts = ts
        self.turn = turn
        self.modelId = modelId
        self.preset = preset
        self.systemPromptChars = systemPromptChars
        self.systemPromptHash = systemPromptHash
        self.messagesCount = messagesCount
        self.lastUserMessage = lastUserMessage
        self.toolsOffered = toolsOffered
        self.assistantContent = assistantContent
        self.toolCalls = toolCalls
        self.error = error
        self.durationMs = durationMs
    }
}

/// Per-conversation JSONL trace writer.
///
/// Actor-isolated: all writes go through one concurrency domain so
/// JSONL lines never interleave even when the agent loop is parallel.
public actor AgentTraceService {

    // MARK: - Default location

    /// Default directory: `~/Library/Application Support/VibeCoder/traces`.
    public static func defaultDirectoryURL() -> URL {
        AppSupport.directory("traces")
    }

    /// Production singleton writing to the default location. Tests should
    /// construct their own instance with a temporary directory rather
    /// than reusing this.
    public static let shared = AgentTraceService()

    // MARK: - State

    public let directoryURL: URL
    private let hub: DiagnosticsHub

    // MARK: - Init

    /// - Parameters:
    ///   - directoryURL: Folder to write JSONL files into. Created on
    ///     demand. Defaults to ``defaultDirectoryURL()``.
    ///   - hub: Diagnostics sink. Defaults to `DiagnosticsHub.shared` so
    ///     traces flow into the same panel as everything else.
    public init(
        directoryURL: URL = AgentTraceService.defaultDirectoryURL(),
        hub: DiagnosticsHub = .shared
    ) {
        self.directoryURL = directoryURL
        self.hub = hub
    }

    // MARK: - Public API

    /// Append one entry to the conversation's JSONL file. Creates the
    /// directory + file on first call. Encode/IO failures emit a
    /// diagnostic warning but never throw — tracing must never break the
    /// agent loop.
    public func append(conversationId: UUID, entry: AgentTraceEntry) async {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = fileURL(for: conversationId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [] // JSONL — one entry per line.

        guard let payload = try? encoder.encode(entry) else {
            await hub.report(.init(
                severity: .warning,
                source: "AgentTraceService",
                message: "Failed to encode trace entry",
                detail: "conversation=\(conversationId.uuidString) turn=\(entry.turn)"
            ))
            return
        }

        var line = payload
        line.append(0x0A) // newline terminator

        let wrote = Self.appendLine(line, to: url)

        if wrote {
            await hub.report(.init(
                severity: .info,
                source: "AgentTraceService",
                message: "trace turn=\(entry.turn) model=\(entry.modelId) tools=\(entry.toolCalls.count) dur=\(entry.durationMs)ms",
                detail: "conversation=\(conversationId.uuidString) file=\(url.path)"
            ))
        } else {
            await hub.report(.init(
                severity: .warning,
                source: "AgentTraceService",
                message: "Failed to write trace entry to disk",
                detail: "conversation=\(conversationId.uuidString) file=\(url.path)"
            ))
        }
    }

    /// Read all entries for a conversation in arrival order. Skips lines
    /// that fail to decode (e.g. older schema) — better to surface what
    /// we can than to fail outright when the user is mid-debugging.
    public func entries(for conversationId: UUID) -> [AgentTraceEntry] {
        let url = fileURL(for: conversationId)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AgentTraceEntry.self, from: d)
        }
    }

    /// Full path to the JSONL file for a conversation. Public so callers
    /// can reveal it in the system file browser for inspection.
    public nonisolated func fileURL(for conversationId: UUID) -> URL {
        directoryURL.appendingPathComponent("\(conversationId.uuidString).jsonl")
    }

    /// Wipe traces for a single conversation. No-op if no file.
    public func clear(conversationId: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: conversationId))
    }

    // MARK: - Hashing

    /// Short 8-byte SHA256 prefix as hex. Used to fingerprint the system
    /// prompt per iteration so the user can detect "did the prompt change
    /// between turn 3 and turn 4?" without storing 30 KB twice over.
    public static func shortHash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - File IO

    /// Returns true on apparent success.
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
