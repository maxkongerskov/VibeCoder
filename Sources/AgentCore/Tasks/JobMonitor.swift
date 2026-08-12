//
//  JobMonitor.swift
//
//  PC7 / polish P9 — Lightweight listing of **in-app** background shell and
//  subagent jobs via `BackgroundJobManager`.
//
//  Honesty (not a Grok Build monitor product):
//  - No long-lived stdout event stream / watchers
//  - Agent-callable list_background_jobs / monitor_jobs list **in-app** jobs only
//  - No cross-session history; process-lifetime only
//  - Scheduled tasks are a separate surface (SchedulerService) — this lists
//    running shell/subagent jobs, not cron schedules
//
//  Output is plain text for status lines, headless dumps, or logs.
//

import Foundation

/// Read-only facade over `BackgroundJobManager` for listing live work.
public enum JobMonitor: Sendable {

    /// One row in a monitor listing.
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: UUID { snapshot.id }
        public let snapshot: BackgroundJobSnapshot
        /// Wall-clock seconds since `startedAt` (capped display use).
        public let elapsedSeconds: Int

        public init(snapshot: BackgroundJobSnapshot, now: Date = Date()) {
            self.snapshot = snapshot
            self.elapsedSeconds = max(0, Int(now.timeIntervalSince(snapshot.startedAt)))
        }
    }

    // MARK: - Queries

    /// All currently **running** background jobs (shell + subagent).
    public static func listRunning(
        manager: BackgroundJobManager = .shared,
        now: Date = Date()
    ) async -> [Entry] {
        let snaps = await manager.listRunning()
        return snaps
            .map { Entry(snapshot: $0, now: now) }
            .sorted { $0.snapshot.startedAt < $1.snapshot.startedAt }
    }

    /// Jobs associated with a conversation (any status still retained).
    public static func list(
        conversationID: UUID,
        manager: BackgroundJobManager = .shared,
        now: Date = Date()
    ) async -> [Entry] {
        let snaps = await manager.list(conversationID: conversationID)
        return snaps
            .map { Entry(snapshot: $0, now: now) }
            .sorted { $0.snapshot.startedAt < $1.snapshot.startedAt }
    }

    // MARK: - Formatting

    /// Human-readable multi-line status for logs / headless / diagnostics.
    /// Empty list → an honest empty line (not silence, not product oversell).
    public static func formatList(
        _ entries: [Entry],
        maxOutputChars: Int = 160
    ) -> String {
        guard !entries.isEmpty else {
            // Keep "none running" + Grok disclaimer — honesty tests and tool UX depend on both.
            return """
            Background jobs: none running
            (In-app shell/subagent list only — not a full Grok-style monitor.)
            """
        }

        let n = entries.count
        let runningN = entries.filter { $0.snapshot.status == .running }.count
        var lines: [String] = [
            "Background jobs: \(n) listed (\(runningN) running)",
            "(In-app process list — not a Grok monitor event stream.)",
        ]
        for (i, e) in entries.enumerated() {
            let s = e.snapshot
            let kind = friendlyKind(s.kind)
            let status = friendlyStatus(s.status)
            let elapsed = formatElapsed(e.elapsedSeconds)
            let shortID = String(s.id.uuidString.prefix(8)).lowercased()
            let cmd = truncate(
                s.command
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                max: 72
            )
            lines.append("\(i + 1). \(kind) · \(status) · \(elapsed) · id \(shortID)")
            if !cmd.isEmpty {
                lines.append("   \(cmd)")
            }
            let outPreview = truncate(
                s.output
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                max: maxOutputChars
            )
            if !outPreview.isEmpty {
                lines.append("   … \(outPreview)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Convenience: format currently running jobs.
    public static func formatRunning(
        manager: BackgroundJobManager = .shared,
        now: Date = Date()
    ) async -> String {
        let entries = await listRunning(manager: manager, now: now)
        return formatList(entries)
    }

    // MARK: - Copy helpers (testable)

    public static func friendlyKind(_ kind: BackgroundJobKind) -> String {
        switch kind {
        case .shell: return "Shell"
        case .subagent: return "Subagent"
        }
    }

    public static func friendlyStatus(_ status: BackgroundJobStatus) -> String {
        switch status {
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .killed: return "stopped"
        case .timedOut: return "timed out"
        }
    }

    /// Compact elapsed: `12s`, `3m 05s`, `1h 02m`.
    public static func formatElapsed(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 {
            let m = s / 60
            let r = s % 60
            return String(format: "%dm %02ds", m, r)
        }
        let h = s / 3600
        let m = (s % 3600) / 60
        return String(format: "%dh %02dm", h, m)
    }

    // MARK: - Helpers

    private static func truncate(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx]) + "…"
    }
}
