// SessionLog.swift
// AgentCore
//
// Always-on lightweight session log written to an injectable file URL.
//
// Purpose: when the app crashes, we want a human-readable trail of the
// last things that happened — which conversation was active, what tool
// was last invoked, what error banner fired, whether an uncaught
// exception was raised. The OS-generated crash report tells us WHERE
// the crash happened in the binary; this log tells us WHAT the user
// was doing.
//
// Writes are serialised through the actor's isolation and the file is
// auto-truncated to ~5 MB on startup to prevent runaway growth across
// long sessions.
//
// The persistence path is injectable so callers (app, CLI, tests) can
// decide where the log goes rather than hardcoding `~/Library/...`.

import Foundation

/// Serial append-only text log for post-mortem inspection.
///
/// All public mutating API is actor-isolated so log lines stay in order
/// even when callers fire from multiple concurrency domains.
public actor SessionLog {

    // MARK: - Default location

    /// Default log URL: `~/Library/Logs/VibeCoder/session.log`.
    /// Callers may pass a different URL to ``init(fileURL:maxBytes:headerLine:)``.
    public static func defaultFileURL() -> URL {
        let logsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/VibeCoder", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("session.log")
    }

    /// Shared instance writing to the default location. Optional — callers
    /// that need a custom path should construct their own.
    public static let shared = SessionLog()

    // MARK: - State

    /// Cap the log size. When exceeded we keep the back half and drop
    /// the front, with a marker line indicating the truncation.
    private let maxBytes: Int64

    private let fileURL: URL
    private let isoFormatter: ISO8601DateFormatter
    private let headerLine: String?
    private var didWriteHeader = false

    // MARK: - Init

    /// - Parameters:
    ///   - fileURL: File to append lines to. Parent directory must exist
    ///     or be creatable. Defaults to ``defaultFileURL()``.
    ///   - maxBytes: Soft cap; checked on first write per session.
    ///   - headerLine: Optional line written once on the first append
    ///     (typically a "session start — vX.Y" banner). Set `nil` to skip.
    public init(
        fileURL: URL = SessionLog.defaultFileURL(),
        maxBytes: Int64 = 5_000_000,
        headerLine: String? = "=== Session start ==="
    ) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.headerLine = headerLine

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = f
    }

    // MARK: - Public API

    /// Append a line. Format: `[ISO timestamp] <message>`.
    public func write(_ message: String) {
        ensureHeader()
        let line = format(message)
        Self.appendLine(line, to: fileURL)
    }

    /// Path the log is being written to. Useful for `open -R` reveal in
    /// the app shell and for tests.
    public func currentFileURL() -> URL { fileURL }

    /// Force the rotation check. Normally called implicitly on first write.
    public func rotateNow() { rotateIfNeeded() }

    // MARK: - Internal

    private func ensureHeader() {
        guard !didWriteHeader else { return }
        didWriteHeader = true
        rotateIfNeeded()
        if let header = headerLine {
            Self.appendLine(format(header), to: fileURL)
        }
    }

    private func format(_ message: String) -> String {
        "[\(isoFormatter.string(from: Date()))] \(message)\n"
    }

    private static func appendLine(_ line: String, to url: URL) {
        guard let data = line.data(using: .utf8) else { return }
        // Best-effort directory creation in case caller passed a fresh path.
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url)
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int64,
              size > maxBytes else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let half = data.suffix(data.count / 2)
        try? half.write(to: fileURL)
        let marker = "=== (log truncated at session start to keep size under \(maxBytes / 1_000_000) MB) ===\n"
        if let mdata = marker.data(using: .utf8),
           let h = try? FileHandle(forWritingTo: fileURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: mdata)
        }
    }
}
