//
//  ProjectsView.swift
//  AgentOS — Claude Edition
//
//  Projects landing page per Phase 1.5c spec. Each project tile carries a
//  chevron.down menu in its upper-right corner with Rename / Delete — same
//  actions as the sidebar disclosure menu.
//
//  Phase 2 wiring: the local `@State` mock array has been replaced with a
//  `ProjectsViewModel` that owns an `AgentCore.ProjectsService` actor.
//  Projects now live on disk under
//  `~/Library/Application Support/AgentOS/Projects/` and persist across
//  launches. Create / rename / delete forward to the VM, which mutates
//  the actor and re-reads the snapshot.
//
//  FS watcher wired via ProjectsViewModel → ProjectsService.startWatching.
//  is not wired — external folder mutations won't appear until the next
//  explicit refresh. Acceptable while all mutations originate in-app.
//

import SwiftUI
import AppKit
import AgentCore

// MARK: - Projects landing view

@MainActor
struct ProjectsView: View {

    // ── Persistence-backed VM ───────────────────────────────────────────
    //
    // `ProjectsViewModel` owns the `ProjectsService` actor and exposes a
    // `@Published [Project]` snapshot. Constructed with the default
    // application-support root if a parent doesn't inject one.
    @StateObject private var vm: ProjectsViewModel

    // Needed so a double-click on a project card can route through
    // `app.openedProject` and the detail pane swaps to
    // `ProjectFolderLandingView`.
    @EnvironmentObject var app: AppViewModel

    init(viewModel: ProjectsViewModel? = nil) {
        // `@StateObject` requires the underlying storage be wrapped at
        // init time. We accept an optional VM so previews / tests can
        // pass a custom-rooted instance, and fall back to the default
        // application-support folder otherwise.
        _vm = StateObject(wrappedValue: viewModel ?? ProjectsViewModel())
    }

    // ── Sheet / search ──────────────────────────────────────────────────
    @State private var showNewSheet: Bool = false

    @State private var searchQuery: String = ""

    // ── Per-tile menu state ─────────────────────────────────────────────
    @State private var renameTarget: Project? = nil
    @State private var renameDraft: String = ""
    @State private var showRenameAlert: Bool = false
    @State private var renameError: String? = nil

    @State private var deleteTarget: Project? = nil
    @State private var showDeleteAlert: Bool = false

    // ── Body ────────────────────────────────────────────────────────────
    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Theme.Palette.canvas)
        .task {
            // Refresh on first appearance in case the VM was constructed
            // before its initial async refresh completed, or the folder
            // changed since the VM was instantiated.
            await vm.refresh()
        }
        // Palette "New Project" can't reach this @State directly — it posts.
        .onReceive(NotificationCenter.default.publisher(for: .newProjectSheetRequested)) { _ in
            showNewSheet = true
        }
        .sheet(isPresented: $showNewSheet) {
            NewProjectSheet(isPresented: $showNewSheet) { request in
                Task {
                    let result: Result<Project, ProjectsError>
                    switch request {
                    case .scratch(let name, let location, let instructions, let files):
                        result = await vm.createFromScratch(name: name, location: location,
                                                            instructions: instructions, files: files)
                    case .existingFolder(let url):
                        result = await vm.register(folder: url)
                    }
                    // Jump straight into the new project on success — the
                    // user picked a folder to work in, so open it.
                    if case .success(let project) = result {
                        app.openedProject = project
                    }
                }
            }
        }
        .alert("Rename folder", isPresented: $showRenameAlert) {
            TextField("Project name", text: $renameDraft)
            Button("Rename", action: commitRename)
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                renameTarget = nil
                renameError = nil
            }
        } message: {
            if let err = renameError {
                Text(err)
            } else if let t = renameTarget {
                Text("Enter a new name for \"\(t.name)\".")
            } else {
                Text("")
            }
        }
        .alert(
            "Delete this project?",
            isPresented: $showDeleteAlert,
            presenting: deleteTarget
        ) { project in
            Button("Delete", role: .destructive) {
                commitDelete(project)
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: { project in
            Text("\"\(project.name)\" and everything inside it will be moved to the Trash. Any tasks bound to this project will fall back to Recents.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "folder.fill")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
            Text("Projects")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.Palette.primary)
            Spacer()

            Button {
                showNewSheet = true
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New Project")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, Theme.Spacing.s + 2)
                .padding(.vertical, Theme.Spacing.xs + 2)
                .foregroundStyle(Theme.Palette.primary)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.button + 1, style: .continuous)
                        .stroke(Theme.Palette.divider, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.ml + 2)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.projects.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.08))
                    .frame(width: 140, height: 140)
                Image(systemName: "folder.fill.badge.plus")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(Theme.Palette.accent)
            }
            .padding(.bottom, Theme.Spacing.l - 4)

            Text("Looking to start a project?")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Palette.primary)

            Text("Point \(AppBranding.displayName) at a folder on your machine. The agent picks up your code, MEMORY.md, and DECISIONS.md so every chat starts grounded.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Palette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.top, Theme.Spacing.xs + 2)

            Button { showNewSheet = true } label: {
                HStack(spacing: Theme.Spacing.xs + 2) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New Project")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Theme.Palette.accent)
                .padding(.horizontal, Theme.Spacing.ml - 2)
                .padding(.vertical, Theme.Spacing.s)
                .background(Theme.Palette.accent.opacity(0.10))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.Palette.accent.opacity(0.35), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Spacing.ml + 2)

            // 2026-06-01 Pass 8a polish: "What you get" feature grid below
            // the primary CTA. Concrete capabilities a project unlocks —
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: Theme.Spacing.m)],
                spacing: Theme.Spacing.m
            ) {
                ForEach(vm.projects) { p in
                    projectCard(p)
                }
            }
            .padding(Theme.Spacing.l)
        }
    }

    // Card uses .onTapGesture (not a Button) so the in-card Menu can claim
    // its own clicks without parent-button gesture conflicts.
    private func projectCard(_ p: Project) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
            HStack(alignment: .top) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.Palette.accent)
                Spacer()
                projectMenu(p)
            }
            Text(p.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Palette.primary)
                .lineLimit(1)
            Text(p.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.Palette.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m + 2)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card + 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card + 2, style: .continuous)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        // Double-click → enter the project's folder landing page.
        // Single-click is reserved for future "select to preview"
        // behaviour; for now it's a no-op so the card doesn't fire
        // navigation on a stray click.
        .onTapGesture(count: 2) {
            app.openedProject = p
        }
        .contextMenu {
            Button("Open") { app.openedProject = p }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([p.url])
            }
            Divider()
            Button("Rename folder") {
                renameTarget = p
                renameDraft = p.name
                renameError = nil
                showRenameAlert = true
            }
            Button(role: .destructive) {
                deleteTarget = p
                showDeleteAlert = true
            } label: {
                Text("Delete folder")
            }
        }
    }

    /// Upper-right corner menu on each tile. Same Rename / Delete actions
    /// as the sidebar disclosure menu.
    private func projectMenu(_ p: Project) -> some View {
        Menu {
            Button {
                renameTarget = p
                renameDraft = p.name
                renameError = nil
                showRenameAlert = true
            } label: {
                Label("Rename folder", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = p
                showDeleteAlert = true
            } label: {
                Label("Delete folder", systemImage: "trash")
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.tertiary)
                .padding(.horizontal, Theme.Spacing.xs + 2)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Mutations (VM-backed)
    //
    // All three actions delegate to `ProjectsViewModel`, which forwards
    // to the `ProjectsService` actor. The service is the single source
    // of truth — after each mutation the VM re-reads `projects()` so
    // the snapshot reflects what's on disk. Critically, rename works
    // because the service moves the folder and returns a fresh
    // `Project` carrying the same `id` + `createdAt` (the `Project`
    // struct is immutable, so rename can't mutate in place).

    private func commitRename() {
        guard let project = renameTarget else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            renameError = "Name cannot be empty."
            showRenameAlert = true
            return
        }
        let oldURL = project.url
        Task {
            if let updated = await vm.rename(project, to: trimmed),
               SafeModeConfig.normalizePath(oldURL.path)
                != SafeModeConfig.normalizePath(updated.url.path) {
                // Managed rename moves the folder — retarget bound tasks.
                await MainActor.run {
                    app.updateProjectBinding(from: oldURL, to: updated.url)
                }
            }
        }
        renameTarget = nil
        renameError = nil
    }

    private func commitDelete(_ project: Project) {
        let boundURL = project.url
        Task {
            await vm.delete(project)
            // Alert promises tasks fall back to Recents — must clear bindings
            // on the live conversation coordinator (not the unused list VM).
            await MainActor.run {
                app.clearProjectBinding(at: boundURL)
            }
        }
        deleteTarget = nil
    }
}

// MARK: - Preview

#Preview("Projects — populated") {
    ProjectsView()
        .frame(width: 920, height: 660)
}
