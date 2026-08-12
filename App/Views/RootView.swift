//
//  RootView.swift
//
//  Top-level NavigationSplitView using the new 4-tab SidebarShell.
//

import SwiftUI
import AgentCore

extension Notification.Name {
    /// Posted by the File → New (⌘N) menu command so RootView can run the
    /// same create-and-navigate path as the toolbar button.
    static let newConversationRequested = Notification.Name("agentos.newConversation")
    /// Posted (with a conversation UUID as `object`) to navigate to a
    /// specific conversation — e.g. the Scheduled pane's "View last run".
    static let openConversationRequested = Notification.Name("agentos.openConversation")
    static let showPatchReviewDebug = Notification.Name("agentos.debug.showPatchReview")
    static let showWorktreeReviewDebug = Notification.Name("agentos.debug.showWorktreeReview")
    static let showTasksListDebug = Notification.Name("agentos.debug.showTasksList")
    static let toggleGGUFBannerDebug = Notification.Name("agentos.debug.toggleGGUFBanner")
    static let commandPaletteRequested = Notification.Name("agentos.commandPalette")
    /// Settings → llama.cpp deep link: open Models pane for library/downloads.
    static let openModelsPane = Notification.Name("agentos.openModelsPane")
    /// Slash `/settings` / `/mcps` — open Settings sheet. `object` may be a
    /// String tab id (e.g. "mcp") for deep-linking.
    static let settingsRequested = Notification.Name("agentos.settings")
    /// Slash `/model` — open the model picker sheet.
    static let modelPickerRequested = Notification.Name("agentos.modelPicker")
    /// Slash `/export` — ChatView exports the active conversation.
    static let exportConversationRequested = Notification.Name("agentos.exportConversation")
    /// Slash `/loop` with no args — open Scheduled tasks tab.
    static let scheduledTasksRequested = Notification.Name("agentos.scheduledTasks")
}

struct RootView: View {
    @EnvironmentObject var app: AppViewModel
    @State private var selectedTab: SidebarTab = .chat
    /// Single source of truth: coordinator selection (C2: closed dual-@State residual).
    private var selectedConversationID: Binding<UUID?> {
        Binding(
            get: { app.selectedConversationID },
            set: { app.selectedConversationID = $0 }
        )
    }
    @State private var showingSettings = false
    /// Deep-link into a Settings tab (`SettingsTab.rawValue`), e.g. "mcp".
    @State private var settingsInitialTab: String? = nil
    @State private var showingPatchReview = false
    @State private var showingWorktreeReview = false
    @State private var showingTasksList = false
    /// When non-nil, the MoveToProjectSheet presents bound to this
    /// conversation. Set by the sidebar's "Move to project" context
    /// menu item; cleared on dismiss.
    @State private var moveToProjectConversationID: UUID? = nil
    @State private var showingCommandPalette = false
    @State private var showingModelPicker = false
    /// Drives sidebar show/hide so we can apply a smooth slide animation
    /// (system default feels abrupt). Only used for motion — not layout.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Extracted so the type-checker solves this (large, many-closure)
    /// initializer in isolation rather than inside `body` alongside the
    /// NavigationSplitView + every sheet/onChange/onReceive modifier.
    ///
    /// ZCode parity: the sidebar is task-centric (workspace + task tree).
    /// Backend controls (engine switcher, agents panel) moved to Settings
    /// → "Model & Backend" tab. The old SidebarShell's engine/agents wiring
    /// is gone from here — all of it still works, just relocated.
    @ViewBuilder
    private var sidebarColumn: some View {
        ZCodeSidebar(
            selectedConversationID: selectedConversationID,
            selectedTab: $selectedTab,
            conversations: app.sidebarOrderedConversations(),
            onShowSettings: { showingSettings = true },
            onDeleteAll: { app.deleteAllConversations() },
            onNewConversation: {
                app.newConversation()
                selectedTab = .chat
            },
            onDeleteConversation: { id in
                app.deleteConversation(id)
            },
            onRenameConversation: { id, newTitle in
                app.renameConversation(id: id, to: newTitle)
            },
            onTogglePin: { app.togglePin($0) },
            onArchiveConversation: { app.archiveConversation($0) },
            onMoveDown: { app.moveConversationDown($0) },
            onMoveToProject: { id in
                moveToProjectConversationID = id
            },
            workspaceName: app.openedProject?.name
                ?? (activeWorkspacePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Default Workspace"),
            workspacePath: activeWorkspacePath,
            taskStatus: { id in
                let vm = app.chatViewModel(for: id)
                if vm.isRunning { return .running }
                if vm.statusLine.lowercased().contains("error") { return .error }
                return .idle
            },
            modelsOnDiskCount: app.availableModels.count,
            cleanModelChrome: app.settings.cleanModelChrome
        )
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        .background(Theme.Palette.subtle) // same plane as input card
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.newConversation()
                    selectedTab = .chat
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                // ⌘N is owned by the File → New menu command (which posts
                // .newConversationRequested); no shortcut here to avoid a
                // duplicate-binding conflict. The button still works on click.
                .help("New conversation (⌘N)")
            }
        }
        // BuildCode parity: do NOT set navigationTitle to the app name —
        // that pins "VibeCoder" in the title bar and fights sidebar collapse.
        .navigationTitle("")
    }

    /// The active workspace path for the sidebar header. Prefers the
    /// selected conversation's `projectRoot`; falls back to the opened
    /// project's URL; then nil if neither is available.
    private var activeWorkspacePath: String? {
        if let id = app.selectedConversationID,
           let conv = app.conversations.first(where: { $0.id == id }),
           let root = conv.projectRoot {
            return root.path
        }
        if let project = app.openedProject {
            return project.url.path
        }
        return nil
    }

    var body: some View {
        ZStack {
            navigationRoot
            if showingCommandPalette {
                CommandPaletteView(
                    isPresented: $showingCommandPalette,
                    items: commandPaletteItems(),
                    onRun: runCommandPaletteItem
                )
            }
        }
    }

    /// Split from sheets/notifications so the type-checker can finish.
    private var navigationSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } detail: {
            DetailPane(
                tab: selectedTab,
                selectedConversationID: selectedConversationID
            )
            // BuildCode: strip the automatic window title from the detail column
            // so hide-sidebar doesn't leave a centered app name in the title bar.
            .toolbarBackground(.hidden, for: .windowToolbar)
            .modifier(RemoveWindowTitleModifier())
        }
        // Smooth slide when the system "Hide Sidebar" control toggles visibility.
        .animation(
            .spring(response: 0.38, dampingFraction: 0.88),
            value: columnVisibility
        )
        .toolbarBackground(.hidden, for: .windowToolbar)
        .modifier(RemoveWindowTitleModifier())
    }

    private var navigationWithSheets: some View {
        navigationSplit
            .sheet(isPresented: $showingSettings, onDismiss: {
                settingsInitialTab = nil
            }) {
                SettingsViewV2(
                    settings: $app.settings,
                    onDismiss: { showingSettings = false },
                    initialTabRaw: settingsInitialTab
                )
                .environmentObject(app)
                // Must match SettingsViewV2 ideal size (980×700). The old
                // 920×660 frame clipped the sidebar labels and Close button.
            }
            .sheet(isPresented: $showingModelPicker) {
                ModelPickerSheet(selectedModelID: activeModelIDBinding)
                    .environmentObject(app)
            }
            .sheet(isPresented: $showingPatchReview) {
                PatchReviewSheetV2(onApply: { _ in showingPatchReview = false })
                    .frame(minWidth: 760, minHeight: 540)
            }
            .sheet(isPresented: $showingWorktreeReview) {
                WorktreeReviewSheet(
                    branchName: "agentos/a4f2c3",
                    files: WorktreeReviewSheet.sampleFiles,
                    onDismiss: { showingWorktreeReview = false },
                    onMerge: { _ in showingWorktreeReview = false },
                    onDiscard: { showingWorktreeReview = false }
                )
            }
            .sheet(isPresented: $showingTasksList) {
                TasksListView()
                    .frame(minWidth: 760, minHeight: 540)
            }
            .sheet(item: Binding(
                get: {
                    moveToProjectConversationID.flatMap { id in
                        app.conversations.first(where: { $0.id == id })
                    }
                },
                set: { newValue in
                    moveToProjectConversationID = newValue?.id
                }
            )) { conv in
                MoveToProjectSheet(conversation: conv)
                    .environmentObject(app)
            }
    }

    private var navigationWithAppNotifications: some View {
        navigationWithSheets
            // Settings persistence is owned by AppViewModel.settings.didSet —
            // do not double-write on every keystroke (was racing SettingsStore).
            .onChange(of: app.settings.backend) { _, backend in
                if selectedTab == .cluster && backend != .exo {
                    selectedTab = .chat
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportConversationRequested)) { note in
                // Route export to the currently active conversation's view model.
                let targetID = note.object as? UUID ?? app.selectedConversationID
                guard let id = targetID else { return }
                if selectedTab == .chat || selectedTab == .code {
                    // Delegate to ChatView's export logic by posting on the
                    // view model's notification center — but since ChatView owns
                    // exportMarkdownToFile(), we simply activate that conversation
                    // and let the user's "/export" slash-command re-fire on the right view.
                    app.selectedConversationID = id
                    // Post to the ChatView-specific handler path: it will match
                    // because note.object (the UUID) equals viewModel.conversation.id.
                    NotificationCenter.default.post(name: .exportConversationRequested, object: id)
                } else {
                    // ChatView not visible (Projects/Scheduled/cluster tab): activate
                    // the conversation so the user can navigate to it and export.
                    app.selectedConversationID = id
                    if !selectedTab.isWorkspaceTab {
                        selectedTab = .chat
                    }
                }
            }
            .onAppear {
                // Seed selection to first non-archived task if none yet.
                if app.selectedConversationID == nil {
                    app.selectedConversationID = app.conversations
                        .first(where: { !$0.archived })?.id
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newConversationRequested)) { _ in
                handleNewConversationRequested()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRequested)) { _ in
                showingCommandPalette = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsRequested)) { note in
                settingsInitialTab = note.object as? String
                showingSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .modelPickerRequested)) { _ in
                selectedTab = .chat
                showingModelPicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .scheduledTasksRequested)) { _ in
                selectedTab = .scheduled
            }
            .onReceive(NotificationCenter.default.publisher(for: .openModelsPane)) { _ in
                showingSettings = false
                selectedTab = .models
            }
    }

    private var navigationWithDebugNotifications: some View {
        navigationWithAppNotifications
            .onReceive(NotificationCenter.default.publisher(for: .openConversationRequested)) { note in
                guard let id = note.object as? UUID else { return }
                app.selectedConversationID = id
                selectedTab = .chat
            }
            .onReceive(NotificationCenter.default.publisher(for: .showPatchReviewDebug)) { _ in
                showingPatchReview = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showWorktreeReviewDebug)) { _ in
                showingWorktreeReview = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showTasksListDebug)) { _ in
                showingTasksList = true
            }
    }

    private var navigationRoot: some View {
        navigationWithDebugNotifications
            .background(WindowChromeAdjuster())
            .preferredColorScheme(resolvedColorScheme(app.settings.colorScheme))
            .onChange(of: app.selectedConversationID) { _, newID in
                // openedProject is a temporary project-folder overlay; clear it
                // when the user switches tasks so Chat is not stuck under a
                // project landing that no longer matches selection.
                if app.openedProject != nil {
                    app.openedProject = nil
                    if newID != nil, !selectedTab.isWorkspaceTab {
                        selectedTab = .chat
                    }
                }
            }
            .onChange(of: selectedTab) { _, _ in
                if app.openedProject != nil { app.openedProject = nil }
            }
    }

    private func handleNewConversationRequested() {
        app.newConversation()
        selectedTab = .chat
    }

    /// Map persisted `colorScheme` string → SwiftUI's optional ColorScheme.
    /// `nil` means "follow System" (the OS appearance).
    private func resolvedColorScheme(_ raw: String) -> ColorScheme? {
        switch raw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil  // "system"
        }
    }

    private var activeChatViewModel: ChatViewModel? {
        guard let id = app.selectedConversationID
                ?? app.conversations.first(where: { !$0.archived })?.id else { return nil }
        return app.chatViewModel(for: id)
    }

    private func commandPaletteItems() -> [CommandPaletteItem] {
        let safeOn = app.safeModeOn
        return [
            CommandPaletteItem(
                id: "new-chat", title: "New Conversation", subtitle: "Start a fresh chat",
                category: "Chat", keywords: ["new", "chat", "conversation"]),
            CommandPaletteItem(
                id: "clear-chat", title: "Clear Conversation",
                subtitle: "Remove all messages (/clear)",
                category: "Chat", keywords: ["clear", "delete", "reset"]),

            CommandPaletteItem(
                id: "toggle-safe-mode", title: safeOn ? "Disable Safe Mode" : "Enable Safe Mode",
                subtitle: "Gate mutating tools behind review (Ask ↔ Auto)",
                category: "Safety", keywords: ["safe", "mode", "patch", "review"]),
            CommandPaletteItem(
                id: "cycle-mode", title: "Cycle Permission Mode",
                subtitle: "Plan → Ask → Auto → Full (⇧Tab)",
                category: "Safety", keywords: ["plan", "ask", "auto", "full", "permission", "mode"]),
            CommandPaletteItem(
                id: "mode-plan", title: "Plan Mode",
                subtitle: "Read-only inspection before edits",
                category: "Safety", keywords: ["plan", "readonly"]),
            CommandPaletteItem(
                id: "open-settings", title: "Open Settings", subtitle: "Connection, tools, appearance",
                category: "App", keywords: ["settings", "preferences", "config"]),
            CommandPaletteItem(
                id: "open-projects", title: "Projects",
                subtitle: "Open projects tab",
                category: "App", keywords: ["project", "folder", "workspace"]),
            CommandPaletteItem(
                id: "open-scheduled", title: "Scheduled Tasks",
                subtitle: "Recurring prompts",
                category: "App", keywords: ["schedule", "loop", "cron"]),
            CommandPaletteItem(
                id: "choose-model", title: "Choose Model", subtitle: "Switch the active model",
                category: "Model", keywords: ["model", "switch", "llm", "provider"]),
            CommandPaletteItem(
                id: "compact", title: "Compact Conversation",
                subtitle: "Compress history to free context (/compact)",
                category: "Chat", keywords: ["compact", "history", "context"]),
            CommandPaletteItem(
                id: "session-info", title: "Session Info",
                subtitle: "Model, turns, context (/session-info)",
                category: "Chat", keywords: ["session", "info", "context"]),
            CommandPaletteItem(
                id: "fork-chat", title: "Fork Conversation",
                subtitle: "Branch with history preserved (/fork)",
                category: "Chat", keywords: ["fork", "branch", "duplicate"]),
        ]
    }

    private func runCommandPaletteItem(_ item: CommandPaletteItem) {
        switch item.id {
        case "new-chat":
            app.newConversation()
            selectedTab = .chat
        case "clear-chat":
            _ = activeChatViewModel?.handleSlashCommand("/clear")
        case "compact":
            _ = activeChatViewModel?.handleSlashCommand("/compact")
        case "session-info":
            if case .handled(let msg) = activeChatViewModel?.handleSlashCommand("/session-info"),
               let msg {
                activeChatViewModel?.statusLine = msg
            }
        case "fork-chat":
            _ = activeChatViewModel?.handleSlashCommand("/fork")
        case "toggle-safe-mode":
            // Avoid Plan↔toggle conflict: if Plan, leave plan; else flip allow-list.
            if app.executionMode == .plan {
                app.executionMode = .build
            } else {
                app.safeModeOn.toggle()
            }
        case "cycle-mode":
            app.cycleExecutionMode()
        case "mode-plan":
            app.executionMode = .plan
        case "open-settings":
            showingSettings = true
        case "open-projects":
            selectedTab = .projects
        case "open-scheduled":
            selectedTab = .scheduled
        case "choose-model":
            selectedTab = .chat
            showingModelPicker = true
        default:
            break
        }
    }

    private var activeModelIDBinding: Binding<String> {
        Binding(
            get: {
                if let vm = activeChatViewModel,
                   let id = vm.conversation.modelID, !id.isEmpty {
                    return id
                }
                return app.selectedModelID ?? ""
            },
            set: { newID in
                app.selectedModelID = newID
                if let vm = activeChatViewModel {
                    vm.conversation.modelID = newID
                    Task { try? await ConversationStore.shared.save(vm.conversation) }
                }
                // Load the engine in oMLX (or warm the active backend) as soon
                // as the user picks a model — don't wait until the first send.
                if !newID.isEmpty {
                    Task { await app.activateModel(id: newID) }
                }
            }
        )
    }
}

// MARK: - Detail pane

private struct DetailPane: View {
    @EnvironmentObject var app: AppViewModel
    let tab: SidebarTab
    @Binding var selectedConversationID: UUID?

    var body: some View {
        // A non-nil `openedProject` always wins over the tab's normal
        // detail content — double-clicking a project on the Projects
        // grid puts us into the project's folder landing page even
        // while the sidebar still highlights Projects. The back arrow
        // in the project view clears `openedProject`, which returns
        // us here and falls through to the tab's normal pane.
        if let project = app.openedProject {
            ProjectFolderLandingView(project: project)
        } else {
            switch tab {
            case .chat, .code:
                // PA10: Code workspace UI is retired (CodeWorkspaceView has no
                // call sites). Legacy `.code` tab enum values still open Chat only.
                workspaceDetail(mode: .chat)
            case .projects:
                // TODO(autopilot): Was DetailPlaceholder stub. Swapped in
                // the ported ProjectsView so the Projects tab renders the
                // full landing grid + its own NewProjectSheet wiring.
                ProjectsView()
            case .scheduled:
                ScheduledLandingView()
            case .cluster:
                ClusterView(host: app.settings.exoHost, port: app.settings.exoPort)
            case .notes:
                NotesDetailEmpty()
            case .models:
                ModelsDetailEmpty()
            }
        }
    }

    private enum WorkspaceMode { case chat }

    /// Routing logic: Chat is the only workspace surface.
    ///   1. Selected ID matches a real conversation → that conversation.
    ///   2. Otherwise → the first available conversation.
    ///   3. If none exist yet → New Task landing.
    @ViewBuilder
    private func workspaceDetail(mode: WorkspaceMode) -> some View {
        if let id = selectedConversationID,
           app.conversations.contains(where: { $0.id == id && !$0.archived }) {
            workspaceView(mode: mode, conversationID: id)
        } else if let first = app.conversations.first(where: { !$0.archived }) {
            workspaceView(mode: mode, conversationID: first.id)
                .onAppear { selectedConversationID = first.id }
        } else {
            NewTaskLandingViewV2()
                .environmentObject(app)
        }
    }

    @ViewBuilder
    private func workspaceView(mode: WorkspaceMode, conversationID: UUID) -> some View {
        let vm = app.chatViewModel(for: conversationID)
        ChatView(viewModel: vm)
            .environmentObject(app)
    }
}

private struct EmptyDetailView: View {
    // Active empty-state: real NewTaskLandingViewV2 (creates conversations).
    var body: some View {
        NewTaskLandingViewV2()
    }
}
private struct NotesDetailEmpty: View {
    // Notes pane — list + search + edit. Human scratch pad; no auto-injection.
    var body: some View { NotesLandingView() }
}
private struct ModelsDetailEmpty: View {
    var body: some View { ModelsLandingView() }
}

private struct DetailPlaceholder: View {
    let icon: String
    let title: String
    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.Palette.tertiary)
            Text(title)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xxxl)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas)
    }
}

// MARK: - Window title removal (BuildCode parity)

/// Hides the automatic NavigationSplitView / window title in the toolbar.
/// Uses `.toolbar(removing: .title)` on macOS 15+ (same API BuildCode uses);
/// older systems rely on `WindowChromeAdjuster` (`titleVisibility = .hidden`).
private struct RemoveWindowTitleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

// `ToolbarModelChip` was removed — it lived in the navigation toolbar,
// read from mock data, and showed up on every tab including ones where
// model selection doesn't apply (Skills, Projects, Models). When chat
// is wired to real models, the picker will return inside ChatHeaderView
// where it belongs.

/// Internal view used by the toolbar chip's popover. Re-uses the
/// section model from MockPickerData and renders the same row layout
/// as `ModelPickerButton`, just without the wrapping button.
private struct ModelPickerButtonPopoverContent: View {
    @Binding var selectedModelID: String
    let onSelect: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(MockPickerData.sections) { section in
                    Text(section.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.Palette.tertiary)
                        .tracking(0.5)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                    ForEach(section.models) { model in
                        Button {
                            selectedModelID = model.id
                            onSelect()
                        } label: {
                            HStack(spacing: 8) {
                                if model.id == selectedModelID {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Theme.Palette.accent)
                                        .frame(width: 14)
                                } else {
                                    Color.clear.frame(width: 14, height: 14)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.displayName)
                                        .font(.system(size: 13))
                                        .foregroundColor(Theme.Palette.primary)
                                        .lineLimit(1)
                                    if let subtitle = model.subtitle {
                                        Text(subtitle)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Theme.Palette.tertiary)
                                    }
                                }
                                Spacer()
                                if let badge = model.badge {
                                    Text(badge.label)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(badge.color)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(badge.color.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 480)
    }
}
