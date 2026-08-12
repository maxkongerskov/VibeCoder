//
//  Note.swift
//
//  A user-authored markdown note. Replaces the much larger `Skill` type
//  from earlier passes — auto-attach is gone, the bundled-procedure
//  library is gone, triggers/category/source are gone. A note is just
//  a title + body the user wrote and wants to come back to.
//
//  The note is plain markdown so the existing `MarkdownTextView` keeps
//  rendering headings, code fences, lists, etc. — users who want
//  formatting get it for free; users who don't can write plain text
//  and never notice.
//
//  Why this exists at all (vs deleting the pane entirely): the sidebar
//  list + search + edit-sheet UI is already built, and a scratch pad
//  for paths, snippets, and reminders is a feature every dev actually
//  uses. Skills as a concept implied the model would *do something*
//  with them — which would have created cross-model variance (see the
//  pre-launch decision to push specific models, not skills). Notes
//  make no such promise; they're purely for the human.
//

import Foundation

public struct Note: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// Short header shown in the list view. No format constraints —
    /// the user picks whatever helps them find it again.
    public var title: String
    /// Markdown body. Empty string is a valid note (the user is
    /// thinking; we don't gate on minimum length).
    public var body: String
    /// First write timestamp. Persisted so the list can show "Created"
    /// alongside "Edited" if needed; sort defaults to `updatedAt`.
    public var createdAt: Date
    /// Last write timestamp. The list is sorted desc on this so the
    /// most-recently-touched note floats to the top — matches Apple
    /// Notes / Bear / most note apps.
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                title: String = "",
                body: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// First non-empty line of the body, capped to ~80 chars, used as
    /// the preview snippet in the list when the title is empty or
    /// duplicates the body's first line. Pure derivation — no
    /// persistence cost.
    public var previewSnippet: String {
        let firstLine = body
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if firstLine.count > 80 {
            return String(firstLine.prefix(80)) + "…"
        }
        return firstLine
    }

    /// Display title falls back to a placeholder when the user hasn't
    /// typed one yet, so the list never shows a blank row.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let preview = previewSnippet
        return preview.isEmpty ? "New note" : preview
    }
}
