//
//  MutationReview.swift
//
//  Shared gate for write/edit/delete tools when the host installs a
//  PatchReviewer (Ask / build execution mode). Reuses the same review
//  sheet as apply_patch so every mutating tool is confirmed.
//
//  Does NOT touch RememberedGrants — one-shot Accept/Reject must not
//  become permanent allow/never. Hosts may call RememberedGrants only
//  on an explicit "Always allow" / "Never allow" UI action.
//
//  Phase A PA1: previews carry real line-based hunks synthesized from
//  original/updated content so the Ask sheet is never empty when the
//  file actually changes (edit_file / write_file / delete / move).
//

import Foundation

public enum MutationReview {

    /// Present a one-file change to the user when a reviewer is installed.
    /// No-op when `context.patchReviewer` is nil (Auto / Full modes).
    ///
    /// - Throws: `ToolError.permissionDenied` if the user rejects.
    public static func requireApproval(
        path: String,
        original: String,
        updated: String,
        context: ToolContext,
        toolName: String = "__path__"
    ) async throws {
        // Durable / session directory grants skip the sheet (user already
        // chose Always allow for this folder or an ancestor).
        // Use path/dir grants only — never treat tool-level Always for
        // write_file as covering edit/delete/move.
        if await pathIsCoveredByGrant(path, context: context, toolName: toolName) {
            return
        }

        guard let reviewer = context.patchReviewer else { return }
        let preview = PatchPreview(
            path: path,
            originalContent: original,
            updatedContent: updated,
            hunks: hunksFromContents(original: original, updated: updated)
        )
        switch await reviewer.review([preview]) {
        case .acceptAll:
            return
        case .rejectAll:
            throw ToolError.permissionDenied(
                "User rejected changes to \(path). No files modified.")
        case .partial(let ids):
            guard ids.contains(preview.id) else {
                throw ToolError.permissionDenied(
                    "User rejected changes to \(path). No files modified.")
            }
        }
    }

    /// True when a durable or in-memory **path/dir** grant covers this path.
    /// Tool-level Always for a specific mutator does not cover other tools.
    public static func pathIsCoveredByGrant(
        _ rawPath: String,
        context: ToolContext,
        toolName: String = "__path__"
    ) async -> Bool {
        let resolved = resolvePath(rawPath, base: context.workingDirectory)
        let projectKey = RememberedGrants.projectKey(from: context)
        var grants = context.authorization.remembered
        if !context.authorization.useInlineRememberedOnly {
            let snap = await RememberedGrants.shared.snapshot(projectKey: projectKey)
            for (k, v) in snap { grants[k] = v }
            // Also pull durable entries for this project (path fingerprints).
            let durable = await DurableGrantStore.shared.snapshot(projectKey: projectKey)
            for (k, v) in durable { grants[k] = v }
        }
        // Only path:/dir: grants (and optional same-tool Always). Do not
        // hardcode write_file so Always-write does not skip edit/delete.
        return RememberedGrants.allowsPath(
            resolved,
            toolName: toolName,
            projectKey: projectKey,
            grants: grants
        )
    }

    // MARK: - Preview hunk synthesis (PA1)

    /// Build display hunks from before/after file contents.
    /// Returns `[]` when contents are identical (no change to show).
    /// Used by MutationReview and as a fallback for UI adapters when a
    /// `PatchPreview` arrives with empty `hunks` but differing content.
    public static func hunksFromContents(
        original: String,
        updated: String,
        contextLines: Int = 3
    ) -> [UnifiedDiff.Hunk] {
        if original == updated { return [] }

        let oldLines = splitLines(original)
        let newLines = splitLines(updated)

        // New file: all additions.
        if oldLines.isEmpty || (oldLines.count == 1 && oldLines[0].isEmpty && !updated.isEmpty) {
            // Treat pure-empty original as create when updated has content.
            let pureEmpty = original.isEmpty
            if pureEmpty {
                let lines: [UnifiedDiff.Line] = newLines.map { .added($0) }
                let newLen = newLines.isEmpty ? 0 : newLines.count
                return [
                    UnifiedDiff.Hunk(
                        oldStart: 0,
                        oldLen: 0,
                        newStart: newLen == 0 ? 0 : 1,
                        newLen: newLen,
                        lines: lines
                    )
                ]
            }
        }

        // Delete file: all removals (updated empty, original not).
        if updated.isEmpty && !original.isEmpty {
            let lines: [UnifiedDiff.Line] = oldLines.map { .removed($0) }
            return [
                UnifiedDiff.Hunk(
                    oldStart: 1,
                    oldLen: oldLines.count,
                    newStart: 0,
                    newLen: 0,
                    lines: lines
                )
            ]
        }

        let edits = lineEditScript(old: oldLines, new: newLines)
        return packHunks(edits: edits, contextLines: max(0, contextLines))
    }

    // MARK: Line split

    /// Split on `\n`, preserving a trailing empty line when content ends with `\n`.
    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: LCS edit script

    private enum Tag {
        case equal(String)
        case insert(String)
        case delete(String)
    }

    /// O(n·m) LCS backtrace — fine for review previews (typical source files).
    /// Caps work on huge buffers by falling back to a single whole-file hunk.
    private static let maxLCSCells = 2_000_000

    private static func lineEditScript(old: [String], new: [String]) -> [Tag] {
        let n = old.count
        let m = new.count
        if n == 0 {
            return new.map { .insert($0) }
        }
        if m == 0 {
            return old.map { .delete($0) }
        }
        if n * m > maxLCSCells {
            // Fail open for display: one hunk with full replace (still truthful).
            return old.map { .delete($0) } + new.map { .insert($0) }
        }

        // dp[i][j] = LCS length of old[0..<i], new[0..<j]
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                if old[i - 1] == new[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var tags: [Tag] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, old[i - 1] == new[j - 1] {
                tags.append(.equal(old[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0, (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                tags.append(.insert(new[j - 1]))
                j -= 1
            } else {
                tags.append(.delete(old[i - 1]))
                i -= 1
            }
        }
        return tags.reversed()
    }

    // MARK: Pack into unified hunks

    private static func packHunks(edits: [Tag], contextLines: Int) -> [UnifiedDiff.Hunk] {
        // Walk edit stream; collect change islands with surrounding context.
        // Precompute which indices are "change" vs equal.
        let isChange: [Bool] = edits.map {
            switch $0 {
            case .equal: return false
            case .insert, .delete: return true
            }
        }
        guard isChange.contains(true) else { return [] }

        var hunks: [UnifiedDiff.Hunk] = []
        var idx = 0
        while idx < edits.count {
            // Skip pure-equal runs until next change.
            while idx < edits.count, !isChange[idx] { idx += 1 }
            if idx >= edits.count { break }

            // Expand [start, end) to include contextLines of equal neighbors,
            // and merge nearby change islands that fall within 2*context.
            let start = max(0, idx - contextLines)
            var end = idx
            while end < edits.count {
                if isChange[end] {
                    end += 1
                    continue
                }
                // Peek ahead for another change within merge distance.
                var look = end
                var gap = 0
                while look < edits.count, !isChange[look] {
                    gap += 1
                    look += 1
                    if gap > contextLines * 2 { break }
                }
                if look < edits.count, isChange[look], gap <= contextLines * 2 {
                    end = look
                    continue
                }
                // Trailing context only.
                end = min(edits.count, end + contextLines)
                break
            }

            // Build hunk lines + old/new coordinates.
            // oldStart/newStart are 1-based line numbers of the first
            // context/removed (old) or context/added (new) line in the hunk.
            var oldLine = 1
            var newLine = 1
            // Advance counters for tags before `start`.
            for k in 0..<start {
                switch edits[k] {
                case .equal: oldLine += 1; newLine += 1
                case .delete: oldLine += 1
                case .insert: newLine += 1
                }
            }

            var lines: [UnifiedDiff.Line] = []
            var oldLen = 0
            var newLen = 0
            let hunkOldStart = oldLine
            let hunkNewStart = newLine

            for k in start..<end {
                switch edits[k] {
                case .equal(let s):
                    lines.append(.context(s))
                    oldLen += 1
                    newLen += 1
                case .delete(let s):
                    lines.append(.removed(s))
                    oldLen += 1
                case .insert(let s):
                    lines.append(.added(s))
                    newLen += 1
                }
            }

            // Unified-diff convention: empty file sides use start 0.
            let oldStartOut = oldLen == 0 ? 0 : hunkOldStart
            let newStartOut = newLen == 0 ? 0 : hunkNewStart
            hunks.append(UnifiedDiff.Hunk(
                oldStart: oldStartOut,
                oldLen: oldLen,
                newStart: newStartOut,
                newLen: newLen,
                lines: lines
            ))
            idx = end
        }
        return hunks
    }
}
