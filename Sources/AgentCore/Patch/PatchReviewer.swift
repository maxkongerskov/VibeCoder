//
//  PatchReviewer.swift
//
//  Plumbing for surfacing `apply_patch` to the UI before files are
//  written. The agent's edit primitive is unified diffs; when the
//  conversation is operating under Safe Mode (or the host app
//  otherwise wants confirmation), the tool builds a `PatchPreview`
//  per file and awaits a `PatchReviewer`'s decision instead of
//  writing straight to disk.
//
//  Design:
//    * Sendable struct rather than protocol so a `ToolContext` value
//      can carry it across actor boundaries without per-conformer
//      boilerplate. The struct wraps a single async closure — host
//      apps build one over a MainActor coordinator (see
//      `PatchReviewCoordinator` in the App target).
//    * File-level accept/reject in v1. Per-hunk granularity is a
//      P3-polish follow-up (the UI sheet already renders per-hunk
//      decisions visually; only the wire format changes).
//
//  This file lives next to `UnifiedDiff.swift` because the preview
//  type leans on `UnifiedDiff.Hunk` for the diff lines.
//

import Foundation

/// One file's worth of pending change. Carries enough context for a
/// diff viewer to render side-by-side or inline without re-parsing.
public struct PatchPreview: Sendable, Identifiable {
    /// Stable ID for the file. Used as the key in `PatchDecision.partial`.
    public let id: UUID
    /// Path as written in the patch header. Relative paths are
    /// resolved against `ToolContext.workingDirectory` by the tool.
    public let path: String
    /// File contents *before* the patch is applied. Empty string for
    /// files the patch would create.
    public let originalContent: String
    /// File contents *after* the patch is applied, computed by
    /// `UnifiedDiff.apply`. The reviewer can display this verbatim.
    public let updatedContent: String
    /// Raw hunks — for UI that renders inline diffs.
    public let hunks: [UnifiedDiff.Hunk]

    public init(id: UUID = UUID(),
                path: String,
                originalContent: String,
                updatedContent: String,
                hunks: [UnifiedDiff.Hunk]) {
        self.id = id
        self.path = path
        self.originalContent = originalContent
        self.updatedContent = updatedContent
        self.hunks = hunks
    }
}

/// The reviewer's verdict on a batch.
public enum PatchDecision: Sendable, Equatable {
    /// Apply every file. Equivalent to no-Safe-Mode behaviour.
    case acceptAll
    /// Apply nothing. Tool returns an `isError` result so the agent
    /// sees "patch rejected" and can decide what to do next.
    case rejectAll
    /// Apply only the file previews whose `id` appears in the set.
    /// Files not in the set are silently dropped from this turn —
    /// the tool result lists which.
    case partial(acceptedFileIDs: Set<UUID>)
}

/// Sendable handle the tool calls into. The host app constructs one
/// of these from its MainActor coordinator using a `@Sendable`
/// closure — see `PatchReviewCoordinator` in the App target.
public struct PatchReviewer: Sendable {
    public let review: @Sendable ([PatchPreview]) async -> PatchDecision

    public init(review: @escaping @Sendable ([PatchPreview]) async -> PatchDecision) {
        self.review = review
    }
}
