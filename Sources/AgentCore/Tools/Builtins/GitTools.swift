//
//  GitTools.swift
//
//  Thin wrappers over git. `git_status` and `git_diff` are the two
//  universal ones; more (`git_log`, `git_show`, `git_blame`) come in
//  P1 as deferred tools so small models don't get distracted by a buffet.
//
//  Wave C W13: run via `/usr/bin/env git` (PATH + Xcode CLT parity with
//  WorktreeService); never report "(clean)" / "(no diff)" on non-zero exit;
//  include stderr in error content; resolve optional path args via resolvePath.
//

import Foundation

public struct GitStatusTool: Tool {
    public static let name = "git_status"
    public static let category: ToolCategory = .git
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "git status -sb in the active working directory (project or worktree). Returns the porcelain summary.",
        parameters: .init(properties: [:])
    )
    public init() {}
    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let r = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "status", "-sb"],
            workingDirectory: context.workingDirectory,
            timeout: 10)
        if r.exitCode != 0 {
            let err = combinedGitOutput(r)
            return ToolResult(
                content: err.isEmpty
                    ? "git status failed (exit \(r.exitCode)). Is \(context.workingDirectory.path) a git repository?"
                    : err,
                isError: true)
        }
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResult(content: out.isEmpty ? "(clean)" : r.stdout, isError: false)
    }
}

public struct GitDiffTool: Tool {
    public static let name = "git_diff"
    public static let category: ToolCategory = .git
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "git diff in the active working directory (project or worktree). Defaults to unstaged changes; pass 'staged: true' for staged.",
        parameters: .init(
            properties: [
                "staged": .init(type: "boolean", description: "Show staged diff. Default false."),
                "path": .init(type: "string", description: "Limit to a path (relative to project/worktree or absolute).")
            ]
        )
    )
    public init() {}
    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        var args = ["git", "diff", "--no-color"]
        if arguments.bool("staged") { args.append("--staged") }
        if let p = arguments.stringOptional("path"), !p.isEmpty {
            // Resolve relative to workingDirectory so worktree mode stays correct;
            // pass absolute path to git so cwd-relative confusion is avoided.
            let resolved = resolvePath(p, base: context.workingDirectory)
            args.append(contentsOf: ["--", resolved.path])
        }
        let r = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: args,
            workingDirectory: context.workingDirectory,
            timeout: 15)
        if r.exitCode != 0 {
            let err = combinedGitOutput(r)
            return ToolResult(
                content: err.isEmpty
                    ? "git diff failed (exit \(r.exitCode))"
                    : err,
                isError: true)
        }
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResult(content: out.isEmpty ? "(no diff)" : r.stdout, isError: false)
    }
}

private func combinedGitOutput(_ r: ShellResult) -> String {
    let s = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    return s
}

// MARK: - Commit / PR workflow (Product S3)

/// Shared commit + PR helpers used by tools and slash handlers.
public enum GitWorkflow: Sendable {

    public struct Result: Sendable, Equatable {
        public let success: Bool
        public let message: String
        public let detail: String?

        public init(success: Bool, message: String, detail: String? = nil) {
            self.success = success
            self.message = message
            self.detail = detail
        }

        public var display: String {
            if let detail, !detail.isEmpty {
                return "\(message)\n\(detail)"
            }
            return message
        }
    }

    /// Commit staged (or stage-all) changes with `message`.
    /// - Does not push. Refuses empty message. Honest error if not a git repo / nothing to commit.
    public static func commit(
        message: String,
        workingDirectory: URL,
        stageAll: Bool = true,
        paths: [String] = []
    ) -> Result {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else {
            return Result(success: false, message: "Commit message is empty. Provide a non-empty message.")
        }

        // Always refuse secret-ish paths (stageAll, explicit paths, or already staged).
        let status = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "status", "--porcelain"],
            workingDirectory: workingDirectory,
            timeout: 15)
        if status.exitCode != 0 {
            return gitFail("git status", status, cwd: workingDirectory)
        }
        let porcelain = status.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if stageAll, porcelain.isEmpty {
            return Result(success: false, message: "Nothing to commit (working tree clean).")
        }
        let secretHits = secretPathsInPorcelain(porcelain)
        let explicitSecrets = paths.filter { pathLooksSecret($0) }
        let blocked = Array(Set(secretHits + explicitSecrets))
        if !blocked.isEmpty {
            return Result(
                success: false,
                message: "Refusing commit: secret-ish paths present (\(blocked.prefix(6).joined(separator: ", "))). Remove secrets from the index/working tree before committing.",
                detail: blocked.joined(separator: "\n"))
        }

        if stageAll {
            let add = ShellRunner.run(
                executable: "/usr/bin/env",
                arguments: ["git", "add", "-A"],
                workingDirectory: workingDirectory,
                timeout: 30)
            if add.exitCode != 0 {
                return gitFail("git add -A", add, cwd: workingDirectory)
            }
        } else if !paths.isEmpty {
            var args = ["git", "add", "--"]
            args.append(contentsOf: paths)
            let add = ShellRunner.run(
                executable: "/usr/bin/env",
                arguments: args,
                workingDirectory: workingDirectory,
                timeout: 30)
            if add.exitCode != 0 {
                return gitFail("git add", add, cwd: workingDirectory)
            }
        }

        // Write message via stdin-free -m (multi -m joins paragraphs).
        // Avoid shell interpolation; message is a single argv.
        let commit = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "commit", "-m", msg],
            workingDirectory: workingDirectory,
            timeout: 60)
        if commit.exitCode != 0 {
            let combined = combinedGitOutput(commit)
            if combined.lowercased().contains("nothing to commit") {
                return Result(success: false, message: "Nothing to commit (no staged changes).")
            }
            return gitFail("git commit", commit, cwd: workingDirectory)
        }

        let sha = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "rev-parse", "--short", "HEAD"],
            workingDirectory: workingDirectory,
            timeout: 10)
        let short = sha.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = commit.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(
            success: true,
            message: short.isEmpty
                ? "Committed."
                : "Committed \(short).",
            detail: out.isEmpty ? msg : out
        )
    }

    /// Path fragments that should not be bulk-staged via `git add -A`.
    public static let secretPathPatterns: [String] = [
        ".env", ".env.local", ".env.production", ".env.development",
        "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
        ".pem", ".p12", ".pfx", ".key",
        "credentials.json", "service-account", "secrets.json",
        "auth.json", ".npmrc", ".pypirc",
        "google-services.json", "GoogleService-Info.plist",
        "keystore", ".jks", "private_key", "secret_key",
    ]

    /// True when a path string looks like secret material.
    public static func pathLooksSecret(_ path: String) -> Bool {
        let base = (path as NSString).lastPathComponent.lowercased()
        let fullLower = path.lowercased()
        for pattern in secretPathPatterns {
            let p = pattern.lowercased()
            if base == p || base.hasSuffix(p) || fullLower.contains("/\(p)")
                || fullLower.hasSuffix(p) || fullLower.contains(p + ".") {
                return true
            }
        }
        return false
    }

    /// Parse `git status --porcelain` paths and return those matching secret patterns.
    /// Rename/copy lines check **both** origin and destination.
    public static func secretPathsInPorcelain(_ porcelain: String) -> [String] {
        var hits: [String] = []
        for line in porcelain.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            guard raw.count >= 4 else { continue }
            // Format: XY path  or  XY origin -> path
            let path = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var candidates: [String] = []
            if let arrow = path.range(of: " -> ") {
                let origin = String(path[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
                let dest = String(path[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
                candidates = [origin, dest]
            } else {
                candidates = [path]
            }
            for var c in candidates {
                if c.hasPrefix("\"") && c.hasSuffix("\"") && c.count >= 2 {
                    c = String(c.dropFirst().dropLast())
                }
                if pathLooksSecret(c) {
                    hits.append(c)
                }
            }
        }
        return hits
    }

    /// Open a pull request via GitHub CLI (`gh`). Honest errors if gh/remote missing.
    /// When `pushIfRemote` is true (default) and a remote exists, pushes the
    /// current branch (`git push -u` when no upstream) before `gh pr create`.
    public static func createPullRequest(
        title: String,
        body: String? = nil,
        base: String? = nil,
        head: String? = nil,
        draft: Bool = false,
        pushIfRemote: Bool = true,
        workingDirectory: URL
    ) -> Result {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            return Result(success: false, message: "PR title is empty.")
        }

        // Verify git repo
        let rev = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "rev-parse", "--is-inside-work-tree"],
            workingDirectory: workingDirectory,
            timeout: 10)
        if rev.exitCode != 0 {
            return Result(
                success: false,
                message: "Not a git repository: \(workingDirectory.path)")
        }

        guard let ghPath = resolveGH() else {
            return Result(
                success: false,
                message: "GitHub CLI (`gh`) not found on PATH. Install: https://cli.github.com/ — then `gh auth login`.")
        }

        // Remote check (honest if missing)
        let remote = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "remote"],
            workingDirectory: workingDirectory,
            timeout: 10)
        if remote.exitCode != 0
            || remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Result(
                success: false,
                message: "No git remote configured. Add a remote (e.g. `git remote add origin <url>`) before opening a PR.")
        }

        var pushNote: String?
        if pushIfRemote {
            let pushResult = pushCurrentBranch(workingDirectory: workingDirectory)
            if !pushResult.success {
                return Result(
                    success: false,
                    message: "git push failed before opening PR: \(pushResult.message)",
                    detail: pushResult.detail)
            }
            pushNote = pushResult.detail
        }

        var args = ["pr", "create", "--title", t]
        let b = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        args.append(contentsOf: ["--body", b.isEmpty ? t : b])
        if let base, !base.isEmpty {
            args.append(contentsOf: ["--base", base])
        }
        if let head, !head.isEmpty {
            args.append(contentsOf: ["--head", head])
        }
        if draft {
            args.append("--draft")
        }

        let r = ShellRunner.run(
            executable: ghPath,
            arguments: args,
            workingDirectory: workingDirectory,
            timeout: 120)
        if r.exitCode != 0 {
            let err = combinedGitOutput(r)
            var msg = "gh pr create failed (exit \(r.exitCode))."
            let lower = err.lowercased()
            if lower.contains("not logged") || lower.contains("auth") || lower.contains("401") {
                msg += " Try `gh auth login`."
            } else if lower.contains("no remote") || lower.contains("could not resolve") {
                msg += " Check remote and branch upstream."
            }
            return Result(success: false, message: msg, detail: err.isEmpty ? nil : err)
        }
        let out = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        var detailParts: [String] = []
        if let pushNote, !pushNote.isEmpty { detailParts.append(pushNote) }
        if !out.isEmpty { detailParts.append(out) }
        return Result(
            success: true,
            message: "Pull request created.",
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: "\n")
        )
    }

    /// Push the current branch to its upstream remote when configured.
    /// Uses `git push -u origin HEAD` when no upstream is set.
    public static func pushCurrentBranch(workingDirectory: URL) -> Result {
        let upstream = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            workingDirectory: workingDirectory,
            timeout: 10)
        let hasUpstream = upstream.exitCode == 0
            && !upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let args: [String]
        if hasUpstream {
            args = ["push"]
        } else {
            // Prefer origin when present; otherwise first remote name.
            let remotes = ShellRunner.run(
                executable: "/usr/bin/env",
                arguments: ["git", "remote"],
                workingDirectory: workingDirectory,
                timeout: 10)
            let names = remotes.stdout
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let remoteName = names.first(where: { $0 == "origin" }) ?? names.first else {
                return Result(success: false, message: "No git remote configured.")
            }
            args = ["push", "-u", remoteName, "HEAD"]
        }

        let r = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git"] + args,
            workingDirectory: workingDirectory,
            timeout: 120)
        if r.exitCode != 0 {
            let err = combinedGitOutput(r)
            return Result(
                success: false,
                message: "git \(args.joined(separator: " ")) failed (exit \(r.exitCode)).",
                detail: err.isEmpty ? nil : err)
        }
        let out = combinedGitOutput(r)
        return Result(
            success: true,
            message: "Pushed current branch.",
            detail: out.isEmpty ? "git \(args.joined(separator: " "))" : out)
    }

    /// Absolute path to `gh` if available.
    public static func resolveGH(
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> String? {
        // Prefer `which` via env for PATH parity with user shell.
        let which = ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["which", "gh"],
            workingDirectory: nil,
            timeout: 5)
        if which.exitCode == 0 {
            let p = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        // Common install locations on macOS.
        for candidate in [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "\(NSHomeDirectory())/.local/bin/gh",
        ] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func gitFail(_ label: String, _ r: ShellResult, cwd: URL) -> Result {
        let err = combinedGitOutput(r)
        return Result(
            success: false,
            message: err.isEmpty
                ? "\(label) failed (exit \(r.exitCode)) in \(cwd.path)"
                : "\(label) failed (exit \(r.exitCode))",
            detail: err.isEmpty ? nil : err
        )
    }
}

public struct GitCommitTool: Tool {
    public static let name = "git_commit"
    public static let category: ToolCategory = .git
    public static let permission: ToolPermission = .executes
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Create a git commit in the project/worktree with the given message. \
        By default stages all changes (git add -A) then commits. Does not push. \
        Refuses empty messages and clean trees.
        """,
        parameters: .init(
            properties: [
                "message": .init(type: "string", description: "Commit message (required)."),
                "stage_all": .init(
                    type: "boolean",
                    description: "If true (default), run git add -A before commit."),
                "paths": .init(
                    type: "array",
                    description: "Optional paths to stage instead of -A when stage_all is false.",
                    items: .init(type: "string")),
            ],
            required: ["message"]
        )
    )
    public init() {}
    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let message = arguments.stringOptional("message")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stageAll = arguments.bool("stage_all", default: true)
        let paths = arguments.stringArray("paths")
        let result = GitWorkflow.commit(
            message: message,
            workingDirectory: context.workingDirectory,
            stageAll: stageAll,
            paths: paths)
        return ToolResult(content: result.display, isError: !result.success)
    }
}

public struct CreatePullRequestTool: Tool {
    public static let name = "create_pull_request"
    public static let category: ToolCategory = .git
    public static let permission: ToolPermission = .executes
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Open a GitHub pull request using the `gh` CLI for the current project/worktree. \
        Requires `gh` on PATH and an authenticated remote. By default pushes the current \
        branch first when a remote exists. Does not create a PR if gh is missing — \
        returns an honest error instead.
        """,
        parameters: .init(
            properties: [
                "title": .init(type: "string", description: "PR title (required)."),
                "body": .init(type: "string", description: "PR body markdown."),
                "base": .init(type: "string", description: "Base branch (default: remote default)."),
                "head": .init(type: "string", description: "Head branch (default: current)."),
                "draft": .init(type: "boolean", description: "Create as draft PR. Default false."),
                "push": .init(
                    type: "boolean",
                    description: "Push current branch before opening the PR when a remote exists. Default true."),
            ],
            required: ["title"]
        )
    )
    public init() {}
    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let title = arguments.stringOptional("title")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = arguments.stringOptional("body")
        let base = arguments.stringOptional("base")
        let head = arguments.stringOptional("head")
        let draft = arguments.bool("draft", default: false)
        let push = arguments.bool("push", default: true)
        let result = GitWorkflow.createPullRequest(
            title: title,
            body: body,
            base: base,
            head: head,
            draft: draft,
            pushIfRemote: push,
            workingDirectory: context.workingDirectory)
        return ToolResult(content: result.display, isError: !result.success)
    }
}
