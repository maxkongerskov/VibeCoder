//
//  WorktreeService.swift
//
//  Wraps `git worktree` so a conversation can do its work in an isolated
//  sibling checkout. The main repo is never mutated until the user
//  explicitly merges the worktree back, or the worktree is discarded.
//
//  Naming convention:
//    * worktree path = "<projectFolder>-agentcore-<shortid>"
//    * branch name   = "agentcore/<shortid>"
//  Both are derived from the conversation id so re-opening the same
//  conversation can reuse them.
//
//  Concurrency:
//    * Pure value-type `enum` with `public static` functions. Every git
//      call is a fresh `git` Process via `ShellRunner` — no shared
//      mutable state, no actor needed. Swift 6 Sendable-clean.
//
//  Departures from DEV PLAN:
//    * Uses `ShellRunner.run(executable:arguments:workingDirectory:
//      timeout:)` rather than the host-target `ShellTool.run(command:
//      timeoutSeconds:)`. ShellRunner takes `argv` arrays directly, so
//      the DEV PLAN's hand-rolled `shellEscape` helper is no longer
//      needed — argv arrays eliminate the quoting surface entirely.
//    * `ConversationStore`-bound conveniences (the host target's call
//      sites) are dropped. Callers pass primitives: project folder path
//      and a short id.
//

import Foundation

/// Result of a successful worktree creation.
public struct CreatedWorktree: Sendable, Equatable {
    public let path: String
    public let branch: String

    public init(path: String, branch: String) {
        self.path = path
        self.branch = branch
    }
}

public enum WorktreeError: Error, LocalizedError, Equatable {
    case notAGitRepo(String)
    case gitFailed(String)
    case projectFolderMissing

    public var errorDescription: String? {
        switch self {
        case .notAGitRepo(let p):   return "Not a git repository: \(p). Worktree mode requires git."
        case .gitFailed(let msg):   return "git command failed: \(msg)"
        case .projectFolderMissing: return "No project folder is set for this conversation."
        }
    }
}

public enum WorktreeService {

    // MARK: - Predicates

    /// `git rev-parse --is-inside-work-tree` inside `path`. Returns
    /// false for empty paths, missing directories, or anything that
    /// isn't a git checkout.
    public static func isGitRepository(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let expanded = (path as NSString).expandingTildeInPath
        let result = git(["rev-parse", "--is-inside-work-tree"],
                         workingDirectory: expanded,
                         timeout: 5)
        guard result.exitCode == 0 else { return false }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// True if `path` is an existing directory on disk. Used as a
    /// cheap "worktree already there?" probe.
    public static func worktreeExists(at path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Lifecycle

    /// Creates a sibling worktree for `projectFolder`, named after
    /// `conversationShortId`. If a worktree already exists at the
    /// derived path it's reused (idempotent — safe across re-opens of
    /// a conversation).
    public static func createOrReuseWorktree(
        projectFolder: String,
        conversationShortId: String
    ) throws -> CreatedWorktree {
        let project = normalize(projectFolder)
        guard isGitRepository(project) else { throw WorktreeError.notAGitRepo(project) }

        let worktreePath = "\(project)-agentcore-\(conversationShortId)"
        let branch = "agentcore/\(conversationShortId)"

        if worktreeExists(at: worktreePath) {
            // Reuse only a worktree of *this* project. A leftover non-git
            // folder or an unrelated repo at the conventional path must not
            // be treated as a healthy worktree (merge/discard would then
            // operate on the wrong tree or silently adopt foreign history).
            guard isGitRepository(worktreePath) else {
                throw WorktreeError.gitFailed(
                    "Path \(worktreePath) exists but is not a git worktree. "
                    + "Remove that directory (or free the path) and try again.")
            }
            guard isWorktree(worktreePath, ofProject: project) else {
                throw WorktreeError.gitFailed(
                    "Path \(worktreePath) exists but is not a worktree of this project. "
                    + "Remove that directory (or free the path) and try again.")
            }
            // Prefer the actual checked-out branch so merge/discard targets
            // the real tip (C2: reuse used to return the conventional name
            // even when HEAD pointed elsewhere).
            let head = git(["rev-parse", "--abbrev-ref", "HEAD"],
                           workingDirectory: worktreePath, timeout: 5)
            let actual = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if head.exitCode == 0, !actual.isEmpty, actual != "HEAD" {
                return CreatedWorktree(path: worktreePath, branch: actual)
            }
            return CreatedWorktree(path: worktreePath, branch: branch)
        }

        // Try creating a new branch off HEAD. If the branch already
        // exists (left over from a prior session), fall back to
        // attaching to it.
        let create = git(["worktree", "add", "-b", branch, worktreePath, "HEAD"],
                         workingDirectory: project,
                         timeout: 30)
        if create.exitCode == 0 {
            return CreatedWorktree(path: worktreePath, branch: branch)
        }

        let fallback = git(["worktree", "add", worktreePath, branch],
                           workingDirectory: project,
                           timeout: 30)
        if fallback.exitCode != 0 {
            throw WorktreeError.gitFailed(combinedOutput(fallback, fallbackTo: create))
        }
        return CreatedWorktree(path: worktreePath, branch: branch)
    }

    /// `git status --short` plus `git diff --stat` inside the
    /// worktree. Used by the review sheet.
    public static func status(worktreePath: String) -> String {
        let p = normalize(worktreePath)
        let s = git(["status", "--short"], workingDirectory: p, timeout: 10)
        let d = git(["diff", "--stat"], workingDirectory: p, timeout: 10)
        return combinedOutput(s) + "\n---\n" + combinedOutput(d)
    }

    /// Full diff (`git diff HEAD`) inside the worktree. Used by the
    /// review sheet. Does **not** include untracked file bodies — see
    /// `reviewChanges` which synthesizes those from disk (C2 / O3).
    public static func diff(worktreePath: String) -> String {
        let p = normalize(worktreePath)
        let r = git(["diff", "HEAD"], workingDirectory: p, timeout: 30)
        return combinedOutput(r)
    }

    /// `git status --short` only (paths + change letters).
    public static func statusShort(worktreePath: String) -> String {
        let p = normalize(worktreePath)
        return combinedOutput(git(["status", "--short"], workingDirectory: p, timeout: 10))
    }

    /// `git diff --numstat HEAD` for per-file +/- line counts.
    public static func numstat(worktreePath: String) -> String {
        let p = normalize(worktreePath)
        return combinedOutput(git(["diff", "--numstat", "HEAD"], workingDirectory: p, timeout: 15))
    }

    /// Structured worktree review payload for the UI sheet.
    ///
    /// Untracked / newly added files often have empty unified-diff hunks
    /// (`git diff HEAD` ignores untracked). For those, we load UTF-8 file
    /// content from disk so the review sheet can show the body (C1 O3 / C2).
    public static func reviewChanges(worktreePath: String) -> [WorktreeDiffParser.FileChange] {
        let p = normalize(worktreePath)
        let status = statusShort(worktreePath: p)
        let stats = numstat(worktreePath: p)
        let unified = diff(worktreePath: p)
        let parsed = WorktreeDiffParser.parse(statusShort: status, numstat: stats, unified: unified)
        return WorktreeDiffParser.enrichUntrackedContent(parsed, worktreeRoot: p)
    }

    /// Default commit/merge message when callers omit one (CLI / legacy).
    public static let defaultMergeCommitMessage = "AgentCore work"

    /// Merges the worktree's branch back into the main checkout, then
    /// removes the worktree and deletes the temp branch. Uncommitted
    /// changes inside the worktree are committed with `commitMessage`
    /// before merging so they're visible to the merge. The same message
    /// is passed as `git merge -m` so the UI field is not silently dropped.
    public static func mergeAndRemove(
        worktreePath: String,
        branch: String,
        projectFolder: String,
        commitMessage: String = defaultMergeCommitMessage
    ) throws {
        let project = normalize(projectFolder)
        let worktree = normalize(worktreePath)
        let message = Self.resolvedCommitMessage(commitMessage)

        // 1. Commit any uncommitted changes in the worktree.
        if isDirty(worktree: worktree) {
            let status = git(["status", "--porcelain"], workingDirectory: worktree, timeout: 15)
            // Fail closed: cannot verify secrets → refuse auto-commit.
            guard status.exitCode == 0 else {
                throw WorktreeError.gitFailed(
                    "Refusing merge commit: git status failed in worktree — \(combinedOutput(status))")
            }
            let secrets = GitWorkflow.secretPathsInPorcelain(status.stdout)
            if !secrets.isEmpty {
                throw WorktreeError.gitFailed(
                    "Refusing merge commit: secret-ish paths in worktree (\(secrets.prefix(6).joined(separator: ", "))). Remove them before merging.")
            }
            let add = git(["add", "-A"], workingDirectory: worktree, timeout: 15)
            if add.exitCode != 0 { throw WorktreeError.gitFailed(combinedOutput(add)) }
            let commit = git(["commit", "-m", message],
                             workingDirectory: worktree, timeout: 15)
            if commit.exitCode != 0 {
                throw WorktreeError.gitFailed(combinedOutput(commit))
            }
        }

        // 1b. Refuse merge if branch tip already contains secret-ish paths vs main.
        let branchFiles = git(
            ["diff", "--name-only", "HEAD...\(branch)"],
            workingDirectory: project, timeout: 15)
        if branchFiles.exitCode == 0 {
            let secretFiles = branchFiles.stdout
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { GitWorkflow.pathLooksSecret($0) }
            if !secretFiles.isEmpty {
                throw WorktreeError.gitFailed(
                    "Refusing merge: secret-ish paths on branch (\(secretFiles.prefix(6).joined(separator: ", "))).")
            }
        }

        // 2. Merge the branch into the main checkout (honor UI message).
        let merge = git(["merge", "--no-ff", "-m", message, branch],
                        workingDirectory: project, timeout: 30)
        if merge.exitCode != 0 {
            throw WorktreeError.gitFailed(
                "Merge failed:\n\(combinedOutput(merge))\n\n" +
                "The worktree is still intact at \(worktree). Resolve manually or discard.")
        }

        // 3. Best-effort cleanup. Either side failing is non-fatal.
        _ = git(["worktree", "remove", "--force", worktree],
                workingDirectory: project, timeout: 15)
        _ = git(["branch", "-D", branch],
                workingDirectory: project, timeout: 15)
    }

    /// Trims whitespace; empty → `defaultMergeCommitMessage`.
    public static func resolvedCommitMessage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultMergeCommitMessage : trimmed
    }

    /// Removes the worktree without merging — work is discarded.
    /// A missing-worktree error is swallowed (idempotent cleanup).
    public static func discard(
        worktreePath: String,
        branch: String,
        projectFolder: String
    ) throws {
        let project = normalize(projectFolder)
        let worktree = normalize(worktreePath)

        let remove = git(["worktree", "remove", "--force", worktree],
                         workingDirectory: project, timeout: 15)
        let combined = combinedOutput(remove)
        if remove.exitCode != 0 && !combined.contains("not a working tree") {
            throw WorktreeError.gitFailed(combined)
        }
        // Branch delete is best-effort — branch may already be gone.
        _ = git(["branch", "-D", branch],
                workingDirectory: project, timeout: 15)
    }

    // MARK: - Internals

    /// True if the worktree has staged, unstaged, **or untracked** changes.
    ///
    /// `git diff --quiet` / `git diff --cached --quiet` alone miss untracked
    /// files. Without porcelain, `mergeAndRemove` would skip the auto-commit
    /// then `worktree remove --force` and **silently discard** those files.
    public static func isDirty(worktree: String) -> Bool {
        let p = normalize(worktree)
        let porcelain = git(["status", "--porcelain"], workingDirectory: p, timeout: 5)
        if porcelain.exitCode == 0 {
            return !porcelain.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Fallback if status fails (rare): staged/unstaged only.
        let unstaged = git(["diff", "--quiet"], workingDirectory: p, timeout: 5)
        let staged = git(["diff", "--cached", "--quiet"], workingDirectory: p, timeout: 5)
        // `git diff --quiet` exits 1 when there are differences.
        return unstaged.exitCode != 0 || staged.exitCode != 0
    }

    /// Single entry point for invoking git via `ShellRunner`. Keeps
    /// `executable` consistent (`/usr/bin/env git` finds the user's
    /// PATH-resolved git binary, including Xcode Command Line Tools).
    private static func git(_ args: [String],
                            workingDirectory: String,
                            timeout: TimeInterval) -> ShellResult {
        ShellRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git"] + args,
            workingDirectory: URL(fileURLWithPath: workingDirectory),
            timeout: timeout
        )
    }

    /// Concatenates stdout + stderr for user-facing error surfacing.
    /// Optionally folds in an earlier attempt's output (used by the
    /// branch-fallback path so the user sees both failures).
    private static func combinedOutput(_ r: ShellResult,
                                       fallbackTo earlier: ShellResult? = nil) -> String {
        var parts: [String] = []
        if let earlier {
            let e = (earlier.stdout + earlier.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if !e.isEmpty { parts.append(e) }
        }
        let current = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { parts.append(current) }
        return parts.joined(separator: "\n")
    }

    private static func normalize(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// True when `path` is listed as a worktree of `project` (same git dir).
    private static func isWorktree(_ path: String, ofProject project: String) -> Bool {
        let want = resolvedPath(path)
        let list = git(["worktree", "list", "--porcelain"],
                       workingDirectory: project, timeout: 10)
        if list.exitCode == 0 {
            for line in list.stdout.split(whereSeparator: \.isNewline) {
                let s = String(line)
                guard s.hasPrefix("worktree ") else { continue }
                let listed = String(s.dropFirst("worktree ".count))
                if resolvedPath(listed) == want { return true }
            }
        }
        // Fallback: same --git-common-dir as the project (linked worktree).
        guard let projectCommon = gitCommonDir(project),
              let pathCommon = gitCommonDir(path) else { return false }
        return projectCommon == pathCommon
    }

    private static func gitCommonDir(_ path: String) -> String? {
        let r = git(["rev-parse", "--git-common-dir"],
                    workingDirectory: path, timeout: 5)
        guard r.exitCode == 0 else { return nil }
        let raw = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if (raw as NSString).isAbsolutePath {
            return resolvedPath(raw)
        }
        return resolvedPath((path as NSString).appendingPathComponent(raw))
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }
}
