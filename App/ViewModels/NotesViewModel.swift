//
//  NotesViewModel.swift
//
//  MainActor ObservableObject that fronts the `NoteStore` actor for
//  the Notes SwiftUI surface (NotesLandingView). Successor to
//  SkillsViewModel — stripped of bundled-content seeding and the
//  bundled-vs-user distinction.
//
//  Responsibilities:
//    * Own the `NoteStore` handle pointed at
//      `~/Library/Application Support/AgentOS/notes/`.
//    * Publish the current `[Note]` snapshot for SwiftUI binding.
//    * Funnel UI mutations (create / save / delete / deleteAll) through
//      the actor and refresh after each.
//
//  Swift 6 strict concurrency: VM is @MainActor, all actor-crossing
//  closures are @Sendable / structured await.
//

import Foundation
import SwiftUI
import AgentCore

@MainActor
final class NotesViewModel: ObservableObject {

    // MARK: Published state

    /// Latest snapshot from the NoteStore. Sorted by `updatedAt` desc.
    @Published private(set) var notes: [Note] = []

    /// Most recent user-visible error, if any. Surfaced as plain text.
    @Published var lastError: String?

    /// True once `bootstrap()` has run to completion at least once.
    /// Views can gate a placeholder/spinner off this if they want to.
    @Published private(set) var isLoaded: Bool = false

    // MARK: Internals

    private let store: NoteStore
    private let folderURL: URL

    // MARK: Init

    /// Default initialiser: persists to
    /// `~/Library/Application Support/AgentOS/notes/`.
    convenience init() {
        self.init(folderURL: Self.defaultNotesFolderURL())
    }

    /// Test seam — pass a custom folder URL (e.g. a temp directory).
    init(folderURL: URL) {
        self.folderURL = folderURL
        try? FileManager.default.createDirectory(at: folderURL,
                                                 withIntermediateDirectories: true)
        self.store = NoteStore(folderURL: folderURL)
        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    // MARK: Folder URL

    static func defaultNotesFolderURL() -> URL {
        AppSupport.directory("notes")
    }

    // MARK: Bootstrap

    /// Load whatever is on disk. No seeding step (unlike the old
    /// SkillsViewModel) — every note is the user's own.
    private func bootstrap() async {
        await refresh()
        self.isLoaded = true
    }

    // MARK: Refresh

    func refresh() async {
        let snapshot = await store.loadAll()
        self.notes = snapshot
    }

    // MARK: Mutations

    /// Create a fresh empty note and return it so the caller can
    /// immediately push the user into the edit sheet. Persists right
    /// away so an interrupted edit (force-quit, crash) doesn't lose
    /// the new row.
    @discardableResult
    func createBlank() async -> Note {
        let note = Note()
        await store.save(note)
        await refresh()
        return note
    }

    /// Save (insert OR update — same UUID overwrites). Bumps
    /// `updatedAt` so the list re-sorts and the row floats up.
    func save(_ note: Note) async {
        var stamped = note
        stamped.updatedAt = Date()
        await store.save(stamped)
        await refresh()
    }

    /// Apply field edits to an existing note. Looks up the current
    /// value in the in-memory snapshot, applies the edits, bumps
    /// `updatedAt`, and writes back. If the id is not currently in
    /// the snapshot (stale UI), this is a no-op.
    func updateNote(id: UUID, title: String, body: String) async {
        guard let current = notes.first(where: { $0.id == id }) else { return }
        var updated = current
        updated.title = title
        updated.body = body
        updated.updatedAt = Date()
        await store.save(updated)
        await refresh()
    }

    /// Delete a note.
    func delete(_ note: Note) async {
        await store.delete(note)
        await refresh()
    }

    /// Delete every note. Triggered by the "Delete all" footer button.
    func deleteAll() async {
        await store.deleteAll()
        await refresh()
    }

    // MARK: Folder accessor

    /// Exposed so a future "Reveal in Finder" affordance can target
    /// the actual on-disk folder.
    var notesFolderURL: URL { folderURL }
}
