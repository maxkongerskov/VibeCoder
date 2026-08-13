//
//  ApplyPatchTool.swift
//
//  Patch-based editing for multi-file unified diffs.
//
//  Format: unified diff (the same `diff -u` output everyone speaks).
//  Multiple file hunks are allowed in a single patch — we route each to
//  the right file. Each hunk's preceding context lines must match
//  exactly. A failed match fails the whole plan with a diagnostic that
//  tells the model which line couldn't be located, so it can recover
//  rather than retry blindly.
//
//  Wave B (S5):
//  - Plan phase remains all-or-nothing (no writes if any apply fails).
//  - On I/O failure mid-write batch, already-written files are restored
//    to pre-patch content (disk honesty for multi-file).
//  - Existing patch targets require read-before-edit.
//  - Full TrackedHunk recorded per successful file write.
//

import Foundation

public struct ApplyPatchTool: Tool {
    public static let name = "apply_patch"
    public static let category: ToolCategory = .filesystem
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Apply a unified diff to one or more files. Prefer edit_file for single-file SEARCH/REPLACE edits.

        Plan phase is all-or-nothing: if any hunk fails to match, no files are modified. \
        Writes then apply per accepted file; if a write fails mid-batch, already-written files \
        are restored to their pre-patch content. When a reviewer is present, the user may reject \
        individual files (those are skipped intentionally — not a plan failure).

        Existing files require a prior read_file in this conversation (read-before-edit). \
        Patch must match the current file contents exactly (whitespace-sensitive).
        """,
        parameters: .init(
            properties: [
                "patch": .init(type: "string",
                               description: "Unified diff. Multiple file headers (--- a/path / +++ b/path) are supported in a single call.")
            ],
            required: ["patch"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let patchText = try arguments.string("patch")
        let patches = UnifiedDiff.parse(patchText)
        guard !patches.isEmpty else {
            return ToolResult(content: "Patch parsed to zero hunks. Check that --- a/path and +++ b/path headers are present.", isError: true)
        }

        // ── Path policy: project/worktree confinement always (even when
        // safeMode == nil), then optional Safe Mode allow-list. Paths live
        // inside the patch body so ToolAuthorization also parses them; this
        // is defense-in-depth before any write planning.
        for filePatch in patches {
            let url = resolvePath(filePatch.path, base: context.workingDirectory)
            try await PathConfinement.requireInsideWorkspaceAsync(
                path: filePatch.path, resolved: url, context: context)
            if let safe = context.safeMode, !safe.isPathAllowed(url) {
                throw ToolError.permissionDenied(
                    "Patch target '\(filePatch.path)' resolves to '\(url.path)', "
                    + "which is outside the Safe Mode allow-list. No files modified.")
            }
        }

        // ── Step 1: project every file patch to its post-apply content
        // BEFORE writing. Failures short-circuit — no files modified.
        struct Planned {
            let preview: PatchPreview
            let url: URL
            let fileExisted: Bool
        }
        var planned: [Planned] = []
        for filePatch in patches {
            let url = resolvePath(filePatch.path, base: context.workingDirectory)
            let fileExisted = FileManager.default.fileExists(atPath: url.path)
            let original: String
            if fileExisted {
                // Read-before-edit for existing targets (new-file patches OK).
                let sessionOk = await SessionReadTracker.shared.hasSessionRead(
                    path: url.path,
                    conversationID: context.conversationID,
                    sessionReadPaths: context.sessionReadPaths)
                if !sessionOk {
                    return ToolResult(
                        content: "apply_patch: read-before-edit required for existing file \(filePatch.path). "
                            + "Call `read_file` on each existing target before applying. No files modified.",
                        isError: true
                    )
                }
                // Fail closed: unreadable existing file must not be treated as empty
                // (would allow a full-file overwrite via patch against "").
                do {
                    original = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    return ToolResult(
                        content: "apply_patch: failed to read \(filePatch.path) — \(error.localizedDescription). No files modified.",
                        isError: true
                    )
                }
            } else {
                original = ""
            }

            switch UnifiedDiff.apply(filePatch: filePatch, to: original) {
            case .success(let newContent):
                let preview = PatchPreview(
                    path: filePatch.path,
                    originalContent: original,
                    updatedContent: newContent,
                    hunks: filePatch.hunks
                )
                planned.append(Planned(preview: preview, url: url, fileExisted: fileExisted))
            case .failure(let reason):
                return ToolResult(
                    content: "Patch failed on \(filePatch.path): \(reason). No files modified.",
                    isError: true
                )
            }
        }

        // ── Step 2: optionally consult the host's PatchReviewer.
        let decision: PatchDecision = await {
            guard let reviewer = context.patchReviewer else { return .acceptAll }
            var needsReview: [PatchPreview] = []
            var preGrantedIDs = Set<UUID>()
            for p in planned {
                if await MutationReview.pathIsCoveredByGrant(p.preview.path, context: context) {
                    preGrantedIDs.insert(p.preview.id)
                } else {
                    needsReview.append(p.preview)
                }
            }
            if needsReview.isEmpty {
                return .acceptAll
            }
            switch await reviewer.review(needsReview) {
            case .acceptAll:
                return .partial(acceptedFileIDs: preGrantedIDs.union(Set(needsReview.map(\.id))))
            case .rejectAll:
                if preGrantedIDs.isEmpty { return .rejectAll }
                return .partial(acceptedFileIDs: preGrantedIDs)
            case .partial(let ids):
                return .partial(acceptedFileIDs: preGrantedIDs.union(ids))
            }
        }()

        switch decision {
        case .rejectAll:
            return ToolResult(
                content: "Patch rejected by user. No files modified.",
                isError: true
            )

        case .acceptAll, .partial:
            let acceptedIDs: Set<UUID>? = {
                if case .partial(let ids) = decision { return ids }
                return nil
            }()

            // Track successful writes for mid-batch I/O rollback.
            var committed: [(url: URL, original: String, path: String, fileExisted: Bool)] = []
            var recordedHunkIDs: [UUID] = []
            var mutated: [String] = []
            var summary: [String] = []
            var skipped: [String] = []

            for p in planned {
                if let acceptedIDs, !acceptedIDs.contains(p.preview.id) {
                    skipped.append(p.preview.path)
                    continue
                }
                do {
                    try FileManager.default.createDirectory(
                        at: p.url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try p.preview.updatedContent.write(to: p.url, atomically: true, encoding: .utf8)
                } catch {
                    // Restore any files already written in this batch.
                    var restoreFailed: [String] = []
                    for prior in committed.reversed() {
                        do {
                            if !prior.fileExisted {
                                if FileManager.default.fileExists(atPath: prior.url.path) {
                                    try FileManager.default.removeItem(at: prior.url)
                                }
                            } else {
                                try prior.original.write(to: prior.url, atomically: true, encoding: .utf8)
                            }
                        } catch {
                            restoreFailed.append(prior.path)
                        }
                    }
                    // Drop ghost hunks for restored (or half-restored) files so
                    // Ask-mode reject cannot re-apply a rollback state.
                    for id in recordedHunkIDs {
                        await HunkTracker.shared.discard(id: id)
                    }
                    let restored = committed.map(\.path).joined(separator: ", ")
                    var restoreNote = restored.isEmpty
                        ? "No prior files needed restore."
                        : "Restored pre-patch content for: \(restored)."
                    if !restoreFailed.isEmpty {
                        restoreNote += " WARNING: restore failed for: \(restoreFailed.joined(separator: ", "))."
                    }
                    return ToolResult(
                        content: "apply_patch: write failed on \(p.preview.path): \(error.localizedDescription). "
                            + "\(restoreNote) No net multi-file changes left applied.",
                        isError: true
                    )
                }

                committed.append((url: p.url, original: p.preview.originalContent, path: p.preview.path, fileExisted: p.fileExisted))
                mutated.append(p.preview.path)

                let hunk = TrackedHunk(
                    conversationID: context.conversationID,
                    path: p.url.path,
                    originalContent: p.preview.originalContent,
                    updatedContent: p.preview.updatedContent)
                await HunkTracker.shared.record(hunk)
                recordedHunkIDs.append(hunk.id)
                // Surface hunk_id so Chat Undo can call HunkTracker.reject.
                summary.append(
                    "Patched \(p.preview.path) (\(p.preview.hunks.count) hunks). hunk_id=\(hunk.id.uuidString)")
            }

            if !skipped.isEmpty {
                summary.append("Skipped (user rejected): \(skipped.joined(separator: ", "))")
            }
            if mutated.isEmpty {
                return ToolResult(
                    content: summary.isEmpty
                        ? "Patch rejected by user. No files modified."
                        : summary.joined(separator: "\n"),
                    isError: true
                )
            }
            return ToolResult(
                content: summary.joined(separator: "\n"),
                mutatedPaths: mutated
            )
        }
    }
}
