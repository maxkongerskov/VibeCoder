//
//  GitStatusSnapshot.swift
//
//  One-shot `git status` block for the agent-mode system prompt. Captured
//  at conversation start (or first compose) and labeled as frozen —
//  it must not be re-queried mid-conversation. Fail-silent: never throws.
//

import Foundation

public enum GitStatusSnapshot: Sendable {

    public static let commandTimeout: TimeInterval = 1.5
    public static let porcelainLineCap = 40

    /// Preamble from ZCode's live `gitStatus:` block. The snapshot will
    /// not update mid-conversation.
    public static let preamble = """
        gitStatus: This is the git status at the start of the conversation. Note that this status is a snapshot in time, and will not update during the conversation.
        """

    public struct CommandOutput: Sendable, Equatable {
        public var stdout: String
        public var exitCode: Int32

        public init(stdout: String = "", exitCode: Int32 = 0) {
            self.stdout = stdout
            self.exitCode = exitCode
        }
    }

    /// `git` argv (without the executable), working directory, timeout.
    public typealias Runner = @Sendable (
        _ arguments: [String],
        _ workingDirectory: URL,
        _ timeout: TimeInterval
    ) -> CommandOutput

    // MARK: - Cache (one snapshot per conversation)

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UUID: String] = [:]

        func get(_ id: UUID) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return storage[id]
        }

        func set(_ id: UUID, _ value: String) {
            lock.lock()
            defer { lock.unlock() }
            storage[id] = value
        }
    }

    private static let cache = Cache()

    /// Return a cached snapshot, capturing once on miss. Empty string in
    /// the cache means "not a repo / failed" so later composes skip I/O.
    public static func cachedCapture(
        conversationID: UUID,
        workingDirectory: URL,
        runner: Runner? = nil
    ) -> String? {
        if let hit = cache.get(conversationID) {
            return hit.isEmpty ? nil : hit
        }
        let snap = capture(workingDirectory: workingDirectory, runner: runner) ?? ""
        cache.set(conversationID, snap)
        return snap.isEmpty ? nil : snap
    }

    // MARK: - Capture

    /// Run the git probes. Returns `nil` when `workingDirectory` is not a
    /// work tree or every probe fails. Never throws.
    public static func capture(
        workingDirectory: URL,
        runner: Runner? = nil,
        timeout: TimeInterval = commandTimeout,
        porcelainLineCap: Int = porcelainLineCap
    ) -> String? {
        let run = runner ?? defaultRunner
        let deadline = Date().addingTimeInterval(timeout)

        func git(_ args: [String]) -> CommandOutput {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return CommandOutput(stdout: "", exitCode: -1)
            }
            return run(args, workingDirectory, min(timeout, remaining))
        }

        let inside = git(["rev-parse", "--is-inside-work-tree"])
        guard isInsideWorkTree(stdout: inside.stdout, exitCode: inside.exitCode) else {
            return nil
        }

        let branchOut = git(["rev-parse", "--abbrev-ref", "HEAD"])
        let currentBranch: String = {
            let t = branchOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if branchOut.exitCode == 0, !t.isEmpty { return t }
            return "unknown"
        }()

        let originHead = git(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"])
        let originName = originHead.exitCode == 0
            ? parseOriginHead(originHead.stdout)
            : nil
        var mainBranch = originName
        if mainBranch == nil {
            let mainRef = git(["rev-parse", "--verify", "--quiet", "refs/heads/main"])
            if mainRef.exitCode == 0 {
                mainBranch = "main"
            } else {
                let masterRef = git(["rev-parse", "--verify", "--quiet", "refs/heads/master"])
                if masterRef.exitCode == 0 {
                    mainBranch = "master"
                }
            }
        }

        let userOut = git(["config", "user.name"])
        let gitUser: String? = {
            guard userOut.exitCode == 0 else { return nil }
            let t = userOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }()

        let statusOut = git(["status", "--porcelain"])
        let porcelain = statusOut.exitCode == 0 ? statusOut.stdout : ""

        let logOut = git(["log", "-5", "--oneline"])
        let recent = logOut.exitCode == 0 ? logOut.stdout : ""

        return formatSnapshot(
            currentBranch: currentBranch,
            mainBranch: mainBranch,
            gitUser: gitUser,
            porcelain: porcelain,
            recentCommits: recent,
            porcelainLineCap: porcelainLineCap)
    }

    // MARK: - Parse / format (testable without spawning git)

    public static func isInsideWorkTree(stdout: String, exitCode: Int32) -> Bool {
        exitCode == 0
            && stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// `refs/remotes/origin/main`, `origin/main`, or `main` → `main`.
    public static func parseOriginHead(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let last = trimmed.split(separator: "/").last else { return nil }
        let name = String(last)
        if name.isEmpty || name == "HEAD" { return nil }
        return name
    }

    public static func capLines(_ text: String, limit: Int) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        if lines.count <= limit {
            return lines.joined(separator: "\n")
        }
        return lines.prefix(limit).joined(separator: "\n")
    }

    public static func formatSnapshot(
        currentBranch: String,
        mainBranch: String?,
        gitUser: String?,
        porcelain: String,
        recentCommits: String,
        porcelainLineCap: Int = porcelainLineCap
    ) -> String {
        var parts: [String] = [preamble, "", "Current branch: \(currentBranch)"]
        if let main = mainBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
           !main.isEmpty {
            parts.append("")
            parts.append("Main branch (you will usually use this for PRs): \(main)")
        }
        if let user = gitUser?.trimmingCharacters(in: .whitespacesAndNewlines),
           !user.isEmpty {
            parts.append("")
            parts.append("Git user: \(user)")
        }
        parts.append("")
        parts.append("Status:")
        let status = capLines(porcelain, limit: porcelainLineCap)
        if !status.isEmpty {
            parts.append(status)
        }
        let commits = capLines(recentCommits, limit: 5)
        if !commits.isEmpty {
            parts.append("")
            parts.append("Recent commits:")
            parts.append(commits)
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Default runner

    public static let defaultRunner: Runner = { arguments, workingDirectory, timeout in
        let result = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git"] + arguments,
            workingDirectory: workingDirectory,
            timeout: timeout)
        return CommandOutput(stdout: result.stdout, exitCode: result.exitCode)
    }
}
