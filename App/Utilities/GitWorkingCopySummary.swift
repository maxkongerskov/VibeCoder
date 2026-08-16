//
//  GitWorkingCopySummary.swift
//
//  App-side git probe for the chat status capsule: current branch +
//  dirty-file count. Injectable runner so tests never spawn `git`.
//

import Foundation
import AgentCore

struct GitWorkingCopySummary: Sendable, Equatable {
    var branch: String
    var dirtyCount: Int

    static let commandTimeout: TimeInterval = 1.5

    struct CommandOutput: Sendable, Equatable {
        var stdout: String
        var exitCode: Int32

        init(stdout: String = "", exitCode: Int32 = 0) {
            self.stdout = stdout
            self.exitCode = exitCode
        }
    }

    /// `git` argv (without the executable), working directory, timeout.
    typealias Runner = @Sendable (
        _ arguments: [String],
        _ workingDirectory: URL,
        _ timeout: TimeInterval
    ) -> CommandOutput

    // MARK: - Capture

    /// Probe `cwd`. Returns `nil` when the path is not a git work tree
    /// (exit 128) or every probe fails. Never throws.
    static func capture(
        workingDirectory: URL,
        runner: Runner? = nil,
        timeout: TimeInterval = commandTimeout
    ) -> GitWorkingCopySummary? {
        let run = runner ?? defaultRunner
        let deadline = Date().addingTimeInterval(timeout)

        func git(_ args: [String]) -> CommandOutput {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return CommandOutput(stdout: "", exitCode: -1)
            }
            return run(args, workingDirectory, min(timeout, remaining))
        }

        let branchOut = git(["rev-parse", "--abbrev-ref", "HEAD"])
        if branchOut.exitCode == 128 { return nil }

        let statusOut = git(["status", "--porcelain"])
        if statusOut.exitCode == 128 { return nil }

        if branchOut.exitCode != 0 && statusOut.exitCode != 0 {
            return nil
        }

        let branch = trimmedBranch(branchOut.stdout) ?? ""
        let dirty = statusOut.exitCode == 0
            ? dirtyCount(fromPorcelain: statusOut.stdout)
            : 0
        return GitWorkingCopySummary(branch: branch, dirtyCount: dirty)
    }

    // MARK: - Parse / format

    /// Trim `rev-parse --abbrev-ref HEAD`. Detached HEAD still yields `"HEAD"`.
    static func trimmedBranch(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Count dirty paths in `git status --porcelain` (modified, staged,
    /// deleted, renamed, untracked). Ignored (`!!`) and blank lines omitted.
    static func dirtyCount(fromPorcelain porcelain: String) -> Int {
        var count = 0
        for line in porcelain.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.count >= 2 else { continue }
            if s.hasPrefix("!!") { continue }
            count += 1
        }
        return count
    }

    /// Collapsed one-liner. Empty segments (no branch, 0 dirty, 0 files,
    /// no plan) are omitted. Example: `main · 3 dirty · 2 files · 1/4 todos`.
    static func collapsedLabel(
        branch: String?,
        dirtyCount: Int,
        fileCount: Int,
        todoDone: Int,
        todoTotal: Int
    ) -> String {
        var parts: [String] = []
        if let name = trimmedBranch(branch ?? "") {
            parts.append(name)
        }
        if dirtyCount > 0 {
            parts.append("\(dirtyCount) dirty")
        }
        if let files = filesSegment(fileCount: fileCount) {
            parts.append(files)
        }
        if let todos = todoFraction(done: todoDone, total: todoTotal) {
            parts.append(todos)
        }
        return parts.joined(separator: " · ")
    }

    static func filesSegment(fileCount: Int) -> String? {
        if fileCount == 1 { return "1 file" }
        if fileCount > 1 { return "\(fileCount) files" }
        return nil
    }

    static func todoFraction(done: Int, total: Int) -> String? {
        guard total > 0 else { return nil }
        return "\(max(0, done))/\(total) todos"
    }

    // MARK: - Default runner

    static let defaultRunner: Runner = { arguments, workingDirectory, timeout in
        let result = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git"] + arguments,
            workingDirectory: workingDirectory,
            timeout: timeout)
        return CommandOutput(stdout: result.stdout, exitCode: result.exitCode)
    }
}
