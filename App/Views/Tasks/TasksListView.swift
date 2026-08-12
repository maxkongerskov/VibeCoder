//
//  TasksListView.swift
//  AgentOS — NEW DAY
//
//  Full Tasks landing — opened via the sidebar's Recents-row "View All".
//  Header: title + framed "New Task".
//  Filter strip: Active | Archived | All | search field | bulk-delete
//  affordances.
//  List: per-row selection checkbox + task icon + name + right-aligned
//  creation date + context menu for archive/delete.
//
//  Ported from DEV PLAN's TasksListView into the Claude Edition theme
//  system. Geist removed (system font), cobalt accent, semantic error
//  red, Swift 6 @MainActor.
//
//  Phase 3 wiring: the `@State` mock array is gone — the view now reads
//  from `ScheduledTasksViewModel`, which mirrors the on-disk
//  `ScheduledTaskStore` actor. The archive sidecar (`Set<UUID>`) lives
//  in the view model and persists to a separate JSON file. Bulk-delete
//  and archive actions route through the view model so disk stays in
//  sync. FS watcher on the store reloads when files change externally.
//

import SwiftUI
import AgentCore

// MARK: - Root view

@MainActor
struct TasksListView: View {

    // MARK: Filter enum

    enum Filter: String, CaseIterable, Identifiable {
        case active, archived, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .active:   return "Active"
            case .archived: return "Archived"
            case .all:      return "All"
            }
        }
    }

    // MARK: View model

    @StateObject private var model: ScheduledTasksViewModel

    // MARK: View-local UI state

    @State private var filter: Filter = .active
    @State private var searchQuery: String = ""
    @State private var selected: Set<UUID> = []
    @State private var showDeleteAllAlert: Bool = false
    @State private var showDeleteSelectedAlert: Bool = false
    @State private var showNewSheet: Bool = false

    // MARK: Init

    init(model: ScheduledTasksViewModel? = nil) {
        // Default to a fresh, on-disk-backed view model. Tests/previews
        // can inject a model pointing at a temp directory.
        _model = StateObject(wrappedValue: model ?? ScheduledTasksViewModel())
    }

    // MARK: Derived

    private var filteredTasks: [ScheduledTask] {
        let byFilter: [ScheduledTask]
        switch filter {
        case .active:   byFilter = model.tasks.filter { !model.archivedIds.contains($0.id) }
        case .archived: byFilter = model.tasks.filter {  model.archivedIds.contains($0.id) }
        case .all:      byFilter = model.tasks
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return byFilter }
        return byFilter.filter { $0.name.lowercased().contains(q) }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Palette.divider)
            filterStrip
            Divider().background(Theme.Palette.divider)
            content
        }
        .background(Theme.Palette.canvas)
        .task { await model.refresh() }
        .alert("Delete all tasks?",
               isPresented: $showDeleteAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                Task {
                    await model.deleteAll()
                    selected.removeAll()
                }
            }
        } message: {
            Text("This will permanently remove all \(model.tasks.count) tasks.")
        }
        .alert("Delete \(selected.count) task(s)?",
               isPresented: $showDeleteSelectedAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await model.delete(ids: selected)
                    selected.removeAll()
                }
            }
        } message: {
            Text("Selected tasks will be permanently removed.")
        }
        .sheet(isPresented: $showNewSheet) {
            NewScheduleSheet(isPresented: $showNewSheet) { task in
                Task { await model.add(task) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.s + 2) {
            Image(systemName: "checklist")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)

            Text("Tasks")
                .font(.system(size: 22, weight: .semibold, design: .default))
                .foregroundStyle(Theme.Palette.primary)

            Spacer()

            Button {
                showNewSheet = true
            } label: {
                Label("New task", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(Theme.Palette.primary)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.xs + 2)
                    .background(Theme.Palette.subtle)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.button,
                                         style: .continuous)
                            .stroke(Theme.Palette.divider, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button,
                                                style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.m)
    }

    // MARK: Filter strip

    private var filterStrip: some View {
        HStack(spacing: Theme.Spacing.s) {
            ForEach(Filter.allCases) { f in
                filterPill(f)
            }

            Button {
                showDeleteAllAlert = true
            } label: {
                Text("Delete All")
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(Theme.Palette.error)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.xs + 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.button,
                                         style: .continuous)
                            .stroke(Theme.Palette.error.opacity(0.40), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(model.tasks.isEmpty)
            .opacity(model.tasks.isEmpty ? 0.45 : 1.0)

            Spacer()

            // Inline search field
            searchField

            // Selected-delete affordance — only when a selection exists.
            if !selected.isEmpty {
                Button {
                    showDeleteSelectedAlert = true
                } label: {
                    Text("Delete Selected (\(selected.count))")
                        .font(.system(size: 12, weight: .medium, design: .default))
                        .foregroundStyle(Theme.Palette.error)
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.vertical, Theme.Spacing.xs + 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.button,
                                             style: .continuous)
                                .stroke(Theme.Palette.error.opacity(0.40), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(Theme.Motion.quick, value: selected.isEmpty)
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.m)
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.xs + 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.Palette.tertiary)
            TextField("Search…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(Theme.Palette.primary)
                .frame(width: 160)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.xs)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
    }

    private func filterPill(_ f: Filter) -> some View {
        let isOn = filter == f
        return Button {
            filter = f
        } label: {
            Text(f.label)
                .font(.system(size: 12, weight: isOn ? .semibold : .medium, design: .default))
                .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.secondary)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                        .fill(isOn ? Theme.Palette.accentSubtle : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                        .stroke(isOn ? Theme.Palette.accent.opacity(0.35)
                                     : Theme.Palette.divider,
                                lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Content (list)

    @ViewBuilder
    private var content: some View {
        if filteredTasks.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredTasks) { row in
                        TasksListRow(
                            row: row,
                            isArchived: model.archivedIds.contains(row.id),
                            isSelected: selected.contains(row.id),
                            onToggleSelection: { toggleSelection(row.id) },
                            onArchiveToggle:   { model.toggleArchived(row) },
                            onDelete:          { Task { await model.delete(row) } }
                        )
                        Divider()
                            .background(Theme.Palette.divider)
                            .opacity(0.6)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.s)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.m) {
            Spacer()
            Image(systemName: filter == .archived ? "archivebox" : "checklist")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.Palette.tertiary)
            Text(emptyLabel)
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(Theme.Palette.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLabel: String {
        switch filter {
        case .active:   return searchQuery.isEmpty ? "No active tasks."   : "No active tasks match your search."
        case .archived: return searchQuery.isEmpty ? "No archived tasks." : "No archived tasks match your search."
        case .all:      return searchQuery.isEmpty ? "No tasks yet."      : "No tasks match your search."
        }
    }

    // MARK: Selection

    private func toggleSelection(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) }
        else                     { selected.insert(id) }
    }
}

// MARK: - Row

@MainActor
fileprivate struct TasksListRow: View {

    let row: ScheduledTask
    /// Passed in from the parent's `archivedIds` sidecar — `ScheduledTask`
    /// itself has no `archived` field, see TasksListView comments above.
    let isArchived: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onArchiveToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {

            // Selection checkbox
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Task icon
            Image(systemName: "checklist")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 18, height: 18)

            // Title
            Text(row.name)
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(Theme.Palette.primary)
                .lineLimit(1)

            if isArchived {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .help("Archived")
            }

            Spacer()

            // Right-aligned date
            Text(row.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(Theme.Palette.tertiary)
        }
        .padding(.vertical, Theme.Spacing.s)
        .padding(.horizontal, Theme.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .fill(isHovered ? Theme.Palette.hover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                onArchiveToggle()
            } label: {
                if isArchived {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                } else {
                    Label("Archive", systemImage: "archivebox")
                }
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
