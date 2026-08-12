//
//  PatchPreviewAdapter.swift
//
//  Translates AgentCore's `PatchPreview` (UnifiedDiff-flavoured) into
//  the UI-side `FilePatch` shape `PatchReviewSheetV2` renders. The
//  mapping is mechanical: each `UnifiedDiff.Hunk` becomes a
//  `PatchHunk`; each `UnifiedDiff.Line` becomes a `DiffLine`. The
//  hunk header string is built from the hunk's line range so the
//  sheet's "@@ -X,Y +A,B @@" chip carries real coordinates.
//
//  Identity: UI `FilePatch.id` is a fresh local UUID — it does NOT
//  equal `PatchPreview.id`. The host (`ChatView`) keeps a
//  `[path: PatchPreview.id]` lookup on the side so per-file
//  decisions can be translated back to AgentCore IDs at apply time.
//  Paths inside a single `apply_patch` call are unique by the tool's
//  contract (one file header per file).
//
//  Phase A PA1: if a preview arrives with empty hunks but differing
//  original/updated content (legacy callers), synthesize display hunks
//  so the Ask sheet never shows a blank accept.
//

import Foundation
import AgentCore

extension FilePatch {
    /// Build a UI-side `FilePatch` value from an AgentCore preview.
    static func from(preview: PatchPreview) -> FilePatch {
        let sourceHunks: [UnifiedDiff.Hunk]
        if !preview.hunks.isEmpty {
            sourceHunks = preview.hunks
        } else if preview.originalContent != preview.updatedContent {
            // Defense in depth: MutationReview should already populate
            // hunks; recover if a caller still passes empty.
            sourceHunks = MutationReview.hunksFromContents(
                original: preview.originalContent,
                updated: preview.updatedContent
            )
        } else {
            sourceHunks = []
        }

        return FilePatch(
            path: preview.path,
            hunks: sourceHunks.enumerated().map { idx, h in
                PatchHunk(
                    id: "\(preview.id.uuidString)_\(idx)",
                    header: "@@ -\(h.oldStart),\(h.oldLen) +\(h.newStart),\(h.newLen) @@",
                    lines: h.lines.map { line in
                        switch line {
                        case .context(let s): return DiffLine(kind: .context, text: s)
                        case .removed(let s): return DiffLine(kind: .removed, text: s)
                        case .added(let s):   return DiffLine(kind: .added,   text: s)
                        }
                    }
                )
            }
        )
    }
}
