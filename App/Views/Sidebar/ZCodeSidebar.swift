//
//  ZCodeSidebar.swift
//
//  ZCode-parity sidebar: workspace indicator (top) + task tree (middle)
//  + stacked bottom actions. Replaces SidebarShell's engine-switcher +
//  Agents-panel + library-tabs layout.
//
//  All backend-specific controls (engine switcher, orchestrator/worker
//  model pickers) move to Settings → "Model & Backend" tab. This sidebar
//  is task-centric, matching ZCode's layout:
//
//    ┌──────────────────────┐
//    │ ◉ Workspace name      │  ← workspace indicator (top)
//    ├──────────────────────┤
//    │ TASKS                 │  ← task tree (conversations)
//    │  ▸ Task title         │
//    │  ★ Pinned task        │
//    │  (time-grouped)       │
//    ├──────────────────────┤
//    │ TASKS ▾               │
//    │ + New Task            │  ← under Tasks disclosure (with nav)
//    │  Search tasks…        │  ← title + preview filter
//    │  ▸ task rows…         │
//    ├──────────────────────┤
//    │ 🗑 Delete all         │
//    │ ⚙ Settings            │  ← footer only
//    └──────────────────────┘
//
//  Status badges per task (running ● / error ✕) come from a closure
//  the host provides — VibeCoder's ChatViewModel owns run state, not
//  the sidebar.
//

import SwiftUI
import AppKit
import AgentCore

/// ZCode-parity sidebar. Task-centric, not engine-centric.
///
/// Key difference from `SidebarShell`: NO engine switcher, NO Agents panel,
/// NO library tabs. Backend selection moves to Settings → "Model & Backend".
/// Library features (Projects/Scheduled/Cluster/Notes/Models) become
/// secondary surfaces accessed elsewhere.
///
/// What stays: the conversation list (now "Tasks"), pinning, time-grouping,
/// rename/archive/delete context menus — all the task-management UX, just
/// restyled to match ZCode's visual language: cleaner rows, status badges,
/// a workspace header.
struct ZCodeSidebar: View {
    @Binding var selectedConversationID: UUID?
    /// Destination tab for Chat / Code / Projects / … (RootView detail).
    @Binding var selectedTab: SidebarTab
    /// Conversations to render in the task tree. Injected by RootView
    /// from AppViewModel so we show real data, never mock.
    var conversations: [Conversation] = []
    /// Corrupt / unreadable conversation JSON files from `listDirectory()`.
    var unloadableConversations: [ConversationLoadFailure] = []
    /// Callbacks — same semantics as the old SidebarShell, so RootView
    /// wiring changes minimally.
    var onShowSettings: () -> Void = {}
    var onDeleteAll: () -> Void = {}
    var onNewConversation: () -> Void = {}
    var onDeleteConversation: (UUID) -> Void = { _ in }
    var onRenameConversation: (UUID, String) -> Void = { _, _ in }
    var onTogglePin: (UUID) -> Void = { _ in }
    var onArchiveConversation: (UUID) -> Void = { _ in }
    var onMoveDown: (UUID) -> Void = { _ in }
    var onMoveToProject: (UUID) -> Void = { _ in }

    /// Active workspace display. In VibeCoder, the "workspace" is the
    /// current working directory or a project root. Shown at the top so
    /// users know which context the agent operates in — matches ZCode's
    /// workspace switcher position.
    var workspaceName: String = "Default Workspace"
    var workspacePath: String? = nil

    /// Returns a lightweight status (running / error / idle) for a task.
    /// VibeCoder's ChatViewModel owns run state; the sidebar just displays
    /// it. Default is `.idle` (no badge).
    var taskStatus: (UUID) -> ZCodeTaskStatus = { _ in .idle }

    /// Optional model count badge for Models nav.
    var modelsOnDiskCount: Int = 0

    /// Presentation filter for task previews (Settings → Advanced).
    var cleanModelChrome: Bool = true
    @AppStorage("sidebarRecentsCollapsed") private var recentsCollapsed: Bool = false
    @AppStorage("sidebarPinnedCollapsed") private var pinnedCollapsed: Bool = false
    @State private var pendingRenameID: UUID? = nil
    @State private var showDeleteAllAlert = false
    @State private var taskSearchQuery: String = ""

    /// Conversations shown in the task tree after applying the search field.
    private var visibleConversations: [Conversation] {
        Self.filteredConversations(
            conversations,
            query: taskSearchQuery,
            cleanModelChrome: cleanModelChrome
        )
    }

    private var primaryNav: [SidebarTab] {
        SidebarTab.sidebarTabs
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Workspace indicator (top) ───────────────────────
            workspaceHeader

            Divider()
                .opacity(0.4)
                .padding(.horizontal, 8)

            // ── Primary destinations ────────────────────────────
            VStack(spacing: 1) {
                ForEach(primaryNav) { tab in
                    navRow(tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            Divider()
                .opacity(0.4)
                .padding(.horizontal, 8)

            // ── Tasks section: header + New Task, then list ─────
            // New Task sits with the section chrome (under the disclosure),
            // not down at the footer — next to the other left-nav actions.
            VStack(spacing: 0) {
                sectionDisclosureHeader(
                    "Tasks",
                    collapsed: recentsCollapsed,
                    toggle: { recentsCollapsed.toggle() }
                )
                .padding(.horizontal, 8)
                .padding(.top, 6)

                bottomActionRow(
                    icon: "plus",
                    title: "New Task",
                    accent: true,
                    help: "Start a new task (⌘N)"
                ) {
                    onNewConversation()
                    selectedTab = .chat
                    recentsCollapsed = false
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)

                taskSearchField
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)

                if !unloadableConversations.isEmpty {
                    unloadableBanner
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }

                if !recentsCollapsed {
                    if conversations.isEmpty {
                        VStack(spacing: 8) {
                            Text("No tasks yet")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Palette.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        Spacer(minLength: 0)
                    } else if visibleConversations.isEmpty {
                        Text("No matching tasks")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .accessibilityIdentifier("sidebar-no-matching-tasks")
                        Spacer(minLength: 0)
                    } else {
                        let pinned = visibleConversations.filter { $0.pinned }
                        let unpinned = visibleConversations.filter { !$0.pinned }
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 2) {
                                if !pinned.isEmpty {
                                    sectionDisclosureHeader(
                                        "Pinned",
                                        collapsed: pinnedCollapsed,
                                        toggle: { pinnedCollapsed.toggle() }
                                    )
                                    if !pinnedCollapsed {
                                        ForEach(pinned) { conv in
                                            taskRow(conv)
                                        }
                                    }
                                }

                                if !unpinned.isEmpty {
                                    ForEach(grouped(unpinned)) { group in
                                        sectionHeader(group.label)
                                        ForEach(group.conversations) { conv in
                                            taskRow(conv)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 2)
                            .padding(.bottom, 8)
                        }
                    }
                } else {
                    Spacer(minLength: 0)
                }
            }

            // ── Footer: admin + settings only ───────────────────
            Divider().opacity(0.4)
            VStack(spacing: 0) {
                bottomActionRow(
                    icon: "trash",
                    title: "Delete all",
                    accent: false,
                    muted: true,
                    help: "Delete all tasks",
                    disabled: conversations.isEmpty
                ) {
                    showDeleteAllAlert = true
                }
                .alert("Delete all tasks?", isPresented: $showDeleteAllAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete All", role: .destructive) { onDeleteAll() }
                } message: {
                    Text("This will permanently remove all \(conversations.count) tasks.")
                }

                bottomActionRow(
                    icon: "gearshape",
                    title: "Settings",
                    accent: false,
                    help: "Settings"
                ) {
                    onShowSettings()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Theme.Palette.subtle)
        }
        .background(Theme.Palette.subtle)
        .onChange(of: taskSearchQuery) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recentsCollapsed = false
            }
        }
    }

    /// Compact in-sidebar filter. Placeholder matches ZCode `searchTasksPlaceholder`.
    private var taskSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.tertiary)
            TextField("Search tasks…", text: $taskSearchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.primary)
                .onExitCommand { taskSearchQuery = "" }
            if !taskSearchQuery.isEmpty {
                Button {
                    taskSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.Palette.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
        .accessibilityIdentifier("sidebar-search-tasks")
    }

    private var unloadableBanner: some View {
        let count = unloadableConversations.count
        let title = count == 1
            ? "1 conversation couldn't be loaded"
            : "\(count) conversations couldn't be loaded"
        return Button {
            NSWorkspace.shared.activateFileViewerSelecting(unloadableConversations.map(\.url))
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                    Text("Show in Finder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Palette.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.Palette.hover)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Reveal unreadable conversation files in Finder")
        .accessibilityLabel(title)
        .accessibilityIdentifier("unloadable-conversations-banner")
    }

    /// Full-width bottom control — same icon column + label alignment for all three.
    private func bottomActionRow(
        icon: String,
        title: String,
        accent: Bool = false,
        muted: Bool = false,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: accent ? .semibold : .regular))
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .font(.system(size: 12, weight: accent ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(
                disabled ? Theme.Palette.tertiary.opacity(0.45)
                    : accent ? Theme.Palette.accent
                    : muted ? Theme.Palette.tertiary
                    : Theme.Palette.secondary
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(title)
    }

    // MARK: - Primary nav

    @ViewBuilder
    private func navRow(_ tab: SidebarTab) -> some View {
        let on = selectedTab == tab
        Button {
            selectedTab = tab
            if tab == .chat || tab == .code {
                // Keep current conversation selection when entering workspace.
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(tab.title)
                    .font(.system(size: 12.5, weight: on ? .medium : .regular))
                Spacer(minLength: 0)
                if tab == .models, modelsOnDiskCount > 0 {
                    Text("\(modelsOnDiskCount)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.Palette.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.Palette.hover)
                        .clipShape(Capsule())
                }
            }
            .foregroundColor(on ? Theme.Palette.primary : Theme.Palette.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(on ? Theme.Palette.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Workspace header

    /// Top section showing the active workspace. ZCode shows the workspace
    /// path prominently at the top of its sidebar so users always know which
    /// directory context the agent operates in.
    @ViewBuilder
    private var workspaceHeader: some View {
        Button {
            selectedTab = .projects
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.Palette.accentSubtle)
                        .frame(width: 28, height: 28)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspaceName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Palette.primary)
                        .lineLimit(1)
                    if let path = workspacePath, !path.isEmpty {
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.Palette.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Theme.Palette.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.Palette.hover)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Task row (ZCode style)

    /// One task row. Shows title + preview + relative time + status.
    @ViewBuilder
    private func taskRow(_ conv: Conversation) -> some View {
        let isSelected = (selectedConversationID == conv.id) && selectedTab.isWorkspaceTab
        let isEditing = (pendingRenameID == conv.id)
        let status = taskStatus(conv.id)

        Group {
            if isEditing {
                InlineRenameRow(
                    initialTitle: conv.title,
                    isActive: isSelected,
                    onCommit: { newTitle in
                        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty, trimmed != conv.title {
                            onRenameConversation(conv.id, trimmed)
                        }
                        pendingRenameID = nil
                    },
                    onCancel: { pendingRenameID = nil }
                )
            } else {
                ZCodeTaskRow(
                    title: conv.title.isEmpty ? "Untitled" : conv.title,
                    preview: Self.previewLine(
                        for: conv,
                        cleanModelChrome: cleanModelChrome
                    ),
                    relativeTime: Self.relativeTime(conv.updatedAt),
                    status: status,
                    isSelected: isSelected,
                    onTap: {
                        selectedConversationID = conv.id
                        if !selectedTab.isWorkspaceTab {
                            selectedTab = .chat
                        }
                    }
                )
            }
        }
        .contextMenu {
            Button {
                onMoveToProject(conv.id)
            } label: { Label("Move to project", systemImage: "folder") }

            Button {
                onTogglePin(conv.id)
            } label: { Label(conv.pinned ? "Unpin" : "Pin",
                              systemImage: conv.pinned ? "pin.slash" : "pin") }

            Button {
                pendingRenameID = conv.id
            } label: { Label("Rename", systemImage: "pencil") }

            Button {
                onArchiveConversation(conv.id)
            } label: { Label("Archive", systemImage: "archivebox") }

            Button(role: .destructive) {
                onDeleteConversation(conv.id)
            } label: { Label("Delete", systemImage: "trash") }

            Divider()

            Button {
                onMoveDown(conv.id)
            } label: { Label("Move down", systemImage: "arrow.down") }
        }
    }

    // MARK: - Section headers

    @ViewBuilder
    private func sectionDisclosureHeader(_ label: String,
                                         collapsed: Bool,
                                         toggle: @escaping () -> Void)
    -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.Palette.tertiary)
                .tracking(0.8)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.Palette.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.Palette.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

// MARK: - Task status

/// Lightweight task status for sidebar display. ZCode shows a running
/// indicator (green dot) while the agent works, an error badge if it
/// failed, and nothing when idle. VibeCoder maps this from ChatViewModel.
public enum ZCodeTaskStatus: Equatable {
    case idle       // not running — no badge
    case running    // green dot (agent working)
    case error      // red ✕ (last run failed)

    public var dotColor: Color {
        switch self {
        case .idle:    return .clear
        case .running:  return Theme.Palette.success
        case .error:    return Theme.Palette.error
        }
    }

    public var icon: String? {
        switch self {
        case .idle:    return nil
        case .running:  return "circle.fill"          // solid green dot
        case .error:    return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - ZCode task row

/// A single task row in the sidebar. Cleaner than SidebarShellRow —
/// ZCode uses a flat, minimal style: title left, optional status badge
/// right. No icon column (the task IS the conversation).
private struct ZCodeTaskRow: View {
    let title: String
    let preview: String
    let relativeTime: String
    let status: ZCodeTaskStatus
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false
    @State private var optimisticActive = false

    private var showActive: Bool { isSelected || optimisticActive }

    var body: some View {
        Button {
            optimisticActive = true
            DispatchQueue.main.async { onTap() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                optimisticActive = false
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // Running / error indicator
                Group {
                    if status == .running {
                        Circle()
                            .fill(Theme.Palette.success)
                            .frame(width: 6, height: 6)
                            .shadow(color: Theme.Palette.success.opacity(0.45), radius: 3)
                    } else if status == .error {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(Theme.Palette.error)
                    } else {
                        Color.clear.frame(width: 6, height: 6)
                    }
                }
                .frame(width: 12, height: 14)
                .padding(.top, 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: showActive ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(showActive ? Theme.Palette.primary : Theme.Palette.secondary)
                    if !preview.isEmpty {
                        Text(preview)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundColor(Theme.Palette.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(relativeTime)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Palette.tertiary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(showActive
                          ? Theme.Palette.hover
                          : (hovering ? Theme.Palette.hover.opacity(0.6) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onChange(of: isSelected) { _, _ in optimisticActive = false }
    }
}

// MARK: - Preview / relative time helpers

extension ZCodeSidebar {
    /// Case-insensitive title + preview substring. Trimmed-empty query returns `items`.
    static func filteredConversations(
        _ items: [Conversation],
        query: String,
        cleanModelChrome: Bool
    ) -> [Conversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { conv in
            if conv.title.localizedCaseInsensitiveContains(needle) { return true }
            let preview = previewLine(for: conv, cleanModelChrome: cleanModelChrome)
            return preview.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Last assistant (or user) line for the task list preview.
    static func previewLine(for conv: Conversation, cleanModelChrome: Bool = true) -> String {
        let msg = conv.messages.last(where: { $0.role == .assistant && $0.appearsInTranscript })
            ?? conv.messages.last(where: { $0.role == .user && $0.appearsInTranscript })
        guard let content = msg?.content else { return "" }
        let display = msg?.role == .assistant
            ? ModelChrome.displayBody(content, enabled: cleanModelChrome)
            : content
        let flat = display
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return "" }
        if flat.count <= 72 { return flat }
        return String(flat.prefix(72)) + "…"
    }

    static func relativeTime(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86_400 { return "\(Int(secs / 3600))h" }
        if secs < 172_800 { return "yday" }
        if secs < 604_800 { return "\(Int(secs / 86_400))d" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

// MARK: - Inline rename row
//
// Finder-style inline rename. Same convention as the old SidebarShell's:
// return commits, Escape cancels, focus loss commits (Finder/Mail).
// Kept here so renaming works without depending on SidebarShell being
// moved elsewhere.

private struct InlineRenameRow: View {
    let initialTitle: String
    let isActive: Bool
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(initialTitle: String,
         isActive: Bool,
         onCommit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialTitle = initialTitle
        self.isActive = isActive
        self.onCommit = onCommit
        self.onCancel = onCancel
        self._draft = State(initialValue: initialTitle)
    }

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 12, height: 12)
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.primary)
                .focused($focused)
                .onSubmit { onCommit(draft) }
                .onExitCommand { onCancel() }      // Escape
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { onCommit(draft) }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? Theme.Palette.accent.opacity(0.18)
                      : Theme.Palette.hover)
        )
        .task {
            focused = true
            try? await Task.sleep(nanoseconds: 60_000_000)
            if let editor = NSApp.keyWindow?.firstResponder as? NSText {
                editor.selectAll(nil)
            }
        }
    }
}

// MARK: - Time grouping (ported from old sidebar)

private struct ConvGroup: Identifiable {
    let label: String
    let conversations: [Conversation]
    var id: String { label }
}

private func grouped(_ convs: [Conversation]) -> [ConvGroup] {
    guard !convs.isEmpty else { return [] }
    let cal = Calendar.current
    let now = Date()
    var today:     [Conversation] = []
    var yesterday: [Conversation] = []
    var week:      [Conversation] = []
    var month:     [Conversation] = []
    var older:     [Conversation] = []

    for c in convs {
        if cal.isDateInToday(c.updatedAt) {
            today.append(c)
        } else if cal.isDateInYesterday(c.updatedAt) {
            yesterday.append(c)
        } else if let d = cal.dateComponents([.day], from: c.updatedAt, to: now).day, d < 7 {
            week.append(c)
        } else if let d = cal.dateComponents([.day], from: c.updatedAt, to: now).day, d < 30 {
            month.append(c)
        } else {
            older.append(c)
        }
    }

    var result: [ConvGroup] = []
    if !today.isEmpty     { result.append(.init(label: "Today",        conversations: today)) }
    if !yesterday.isEmpty { result.append(.init(label: "Yesterday",    conversations: yesterday)) }
    if !week.isEmpty      { result.append(.init(label: "Past 7 days",  conversations: week)) }
    if !month.isEmpty     { result.append(.init(label: "Past 30 days", conversations: month)) }
    if !older.isEmpty     { result.append(.init(label: "Older",        conversations: older)) }
    return result
}