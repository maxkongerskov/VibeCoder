//
//  NotesLandingView.swift
//
//  Notes tab landing view. Two-column layout: searchable list of
//  notes on the left, full editor on the right when a row is
//  selected. Replaces the old SkillsLandingView / SkillsManagerWindow
//  pair — the conceptual model is simpler now, so one view is plenty.
//
//  Wired to `NotesViewModel` which fronts the AgentCore `NoteStore`
//  actor. Persisted notes live at
//  ~/Library/Application Support/AgentOS/notes/<uuid>.json — one
//  file per note, JSON, hand-editable.
//

import SwiftUI
import AgentCore

struct NotesLandingView: View {

    @StateObject private var vm = NotesViewModel()

    /// Currently selected note ID. Tracking by id (not by Note value)
    /// keeps the editor stable when the underlying note mutates from
    /// outside (e.g., a save bumping updatedAt re-sorts the list).
    @State private var selectedID: UUID?

    /// Live search query. Filters by title + body substring,
    /// case-insensitive. Empty string = show everything.
    @State private var search: String = ""

    /// Drives the destructive confirmation before "Delete all" wipes
    /// every note. Defaults to false; the footer button flips it on.
    @State private var showDeleteAllConfirm = false

    // MARK: - Filtered list (derived)

    private var filtered: [Note] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return vm.notes }
        return vm.notes.filter {
            $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q)
        }
    }

    private var selectedNote: Note? {
        guard let id = selectedID else { return nil }
        return vm.notes.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                listColumn
                if let note = selectedNote {
                    Divider()
                    NoteEditor(
                        note: note,
                        onSave: { title, body in
                            Task { await vm.updateNote(id: note.id, title: title, body: body) }
                        },
                        onDelete: {
                            Task {
                                await vm.delete(note)
                                selectedID = nil
                            }
                        },
                        onClose: { selectedID = nil }
                    )
                    .id(note.id)  // Force editor remount when the selection changes
                }
            }
        }
        .background(Theme.Palette.canvas)
        .animation(.easeOut(duration: 0.18), value: selectedID)
        .confirmationDialog(
            "Delete all notes?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                Task {
                    await vm.deleteAll()
                    selectedID = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every note. There's no undo.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Notes")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.Palette.primary)
            Text("\(vm.notes.count) total")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
            Spacer()

            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 180)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.Palette.subtle)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.Palette.divider, lineWidth: 0.5))

            // New note button
            Button {
                Task {
                    let fresh = await vm.createBlank()
                    selectedID = fresh.id
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text("New").font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.Palette.accent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Create a new note")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Left column — note list

    private var listColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filtered.isEmpty {
                        emptyState
                    } else {
                        ForEach(filtered) { note in
                            row(note)
                            Divider().opacity(0.3).padding(.leading, 14)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Footer with "Delete all" — only when there's something to delete
            if !vm.notes.isEmpty {
                Divider().opacity(0.5)
                HStack {
                    Spacer()
                    Button {
                        showDeleteAllConfirm = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash").font(.system(size: 10))
                            Text("Delete all").font(.system(size: 11))
                        }
                        .foregroundColor(Theme.Palette.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Permanently delete every note")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 280, idealWidth: 360, maxWidth: selectedID == nil ? .infinity : 380)
    }

    private func row(_ note: Note) -> some View {
        let isSelected = selectedID == note.id
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedID = (selectedID == note.id) ? nil : note.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(note.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.Palette.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(relativeTimestamp(note.updatedAt))
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Palette.tertiary)
                }
                if !note.previewSnippet.isEmpty,
                   note.previewSnippet != note.displayTitle {
                    Text(note.previewSnippet)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.Palette.accent.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Task {
                    if selectedID == note.id { selectedID = nil }
                    await vm.delete(note)
                }
            } label: {
                Label("Delete note", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 28))
                .foregroundColor(Theme.Palette.tertiary.opacity(0.6))
            Text(search.isEmpty ? "No notes yet" : "No matches")
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.tertiary)
            Text(search.isEmpty
                 ? "Click + to create one. Notes are markdown — paste snippets, jot reminders, anything."
                 : "Try a different search term.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.mutedFg)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    /// "Just now" / "5 min ago" / "2 hours ago" / "Yesterday" / dated.
    /// Single line, optimised for the row footer — width-constrained,
    /// so we cap to short forms.
    private func relativeTimestamp(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 {
            let mins = Int(elapsed / 60)
            return "\(mins) min ago"
        }
        if elapsed < 86_400 {
            let hours = Int(elapsed / 3600)
            return "\(hours)h ago"
        }
        if elapsed < 172_800 {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

// MARK: - Editor (right column)
//
// Inline editor — title field on top, multiline body below. Save fires
// on every keystroke via a debounced binding (so the user never loses
// work to a forgotten Cmd+S). The "Close" arrow returns to the
// list-only layout; "Delete" wipes the note after confirmation.

private struct NoteEditor: View {
    let note: Note
    let onSave: (String, String) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var title: String
    /// Note body text. Renamed from `body` because that collides with
    /// SwiftUI's required `var body: some View` property.
    @State private var bodyText: String
    @State private var showDeleteConfirm = false

    /// Debounce: the editor commits the latest title+body to disk
    /// after the user pauses typing for `saveDebounceMS`
    /// milliseconds. Without this, every keystroke would hit the
    /// NoteStore actor.
    @State private var saveTask: Task<Void, Never>?
    private let saveDebounceMS: UInt64 = 400_000_000  // 0.4s

    init(note: Note,
         onSave: @escaping (String, String) -> Void,
         onDelete: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.note = note
        self.onSave = onSave
        self.onDelete = onDelete
        self.onClose = onClose
        _title    = State(initialValue: note.title)
        _bodyText = State(initialValue: note.body)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            editor
        }
        .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity)
        .background(Theme.Palette.canvas)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .confirmationDialog(
            "Delete this note?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the note. There's no undo.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.Palette.secondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.Palette.subtle.opacity(0.6))
                    .clipShape(Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close note")

            // Title field — borderless, sized to look like a heading
            TextField("Note title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.Palette.primary)
                .onChange(of: title) { _, _ in scheduleSave() }

            Spacer()

            Button {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Palette.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete this note")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.Palette.subtle.opacity(0.4))
    }

    private var editor: some View {
        TextEditor(text: $bodyText)
            .font(.system(size: 13))
            .foregroundColor(Theme.Palette.primary)
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.canvas)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .onChange(of: bodyText) { _, _ in scheduleSave() }
    }

    /// Cancel any in-flight save Task and schedule a fresh one.
    /// Net effect: only the LAST edit within `saveDebounceMS` makes
    /// it to disk — perfect for typing flows.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: saveDebounceMS)
            if Task.isCancelled { return }
            onSave(title, bodyText)
        }
    }
}
