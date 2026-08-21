//
//  SidebarShell.swift
//
//  Ported from DEV PLAN's SidebarView (UI Iteration 2 Batch 3).
//  Single-column sidebar with: wordmark + sparkle, top nav rows,
//  Recents header with collapse, time-grouped conversation list,
//  bottom bar with delete-all + settings.
//
//  Stripped: ProjectsService, EngineStatusRow (will return when
//  backends are wired), rename/delete project alerts.
//

import SwiftUI
import AppKit
import AgentCore

enum SidebarTab: String, CaseIterable, Identifiable {
    /// `.code` retained for decode/migration only — not shown in the sidebar.
    /// Coding work lives in Chat (inline expandable diffs).
    case chat, code, projects, scheduled, cluster, notes, models
    var id: Self { self }

    /// Primary workspace modes shown first in the sidebar.
    /// Chat only — Code mode removed (inline edit cards in Chat).
    static let workspaceTabs: [SidebarTab] = [.chat]

    /// Tabs offered in the main sidebar nav (excludes legacy `.code`).
    /// Cluster is EXO-only — see `sidebarTabs(for:)`.
    static let sidebarTabs: [SidebarTab] = [
        .chat, .projects, .models, .notes, .scheduled
    ]

    /// Live sidebar destinations. Cluster mounts only when EXO is the
    /// active backend (read-only `/state` topology + pin Model ID).
    static func sidebarTabs(for backend: BackendIdentifier) -> [SidebarTab] {
        var tabs = sidebarTabs
        guard backend == .exo else { return tabs }
        if let idx = tabs.firstIndex(of: .models) {
            tabs.insert(.cluster, at: tabs.index(after: idx))
        } else {
            tabs.append(.cluster)
        }
        return tabs
    }

    var icon: String {
        switch self {
        case .chat:        return "bubble.left.and.bubble.right"
        case .code:        return "chevron.left.forwardslash.chevron.right"
        case .projects:    return "folder"
        case .scheduled:   return "calendar.badge.clock"
        case .cluster:     return "network"
        case .notes:       return "note.text"
        case .models:      return "cpu"
        }
    }

    var title: String {
        switch self {
        case .chat:        return "Chat"
        case .code:        return "Code"
        case .projects:    return "Projects"
        case .scheduled:   return "Scheduled"
        case .cluster:     return "Cluster"
        case .notes:       return "Notes"
        case .models:      return "Models"
        }
    }

    var isWorkspaceTab: Bool {
        Self.workspaceTabs.contains(self)
    }
}

/// Lightweight reachability poller for the sidebar engine switcher. Pings
/// each engine's host:port with a short timeout and publishes up/down so the
/// status dots reflect reality, not decoration. A uniform HTTP ping covers
/// all three (llama.cpp is a local HTTP server here, same as LM Studio/EXO).
@MainActor
final class EngineReachabilityProbe: ObservableObject {
    enum Reachability: Equatable { case unknown, checking, up, down }

    /// Sendable snapshot of the host/port fields, so the poll task doesn't
    /// capture the whole (non-Sendable) AppSettings.
    struct Hosts: Sendable {
        let lmsHost: String,   lmsPort: Int
        let exoHost: String,   exoPort: Int
        let omlxHost: String,  omlxPort: Int
        let ollamaHost: String, ollamaPort: Int
        let unslothHost: String, unslothPort: Int
        init(_ s: AppSettings) {
            lmsHost   = s.lmStudioHost; lmsPort   = s.lmStudioPort
            exoHost   = s.exoHost;      exoPort   = s.exoPort
            omlxHost   = s.omlxHost;    omlxPort   = s.omlxPort
            ollamaHost = s.ollamaHost;  ollamaPort = s.ollamaPort
            unslothHost = s.unslothHost; unslothPort = s.unslothPort
        }
    }

    @Published private(set) var status: [BackendIdentifier: Reachability] = [:]
    private var pollTask: Task<Void, Never>?

    func start(settings: AppSettings) {
        stop()
        let hosts = Hosts(settings)
        Task { await probe(hosts) }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)   // 15 s
                if Task.isCancelled { break }
                await self?.probe(hosts)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func probe(_ h: Hosts) async {
        async let lms    = Self.reachable(host: h.lmsHost,    port: h.lmsPort,    path: "/v1/models")
        async let exo    = Self.reachable(host: h.exoHost,    port: h.exoPort,    path: "/node_id")
        async let omlx   = Self.reachable(host: h.omlxHost,   port: h.omlxPort,   path: "/v1/models")
        async let ollama = Self.reachable(host: h.ollamaHost, port: h.ollamaPort, path: "/v1/models")
        async let unsloth = Self.reachable(host: h.unslothHost, port: h.unslothPort, path: "/v1/models")
        let (m, e, o, a, u) = await (lms, exo, omlx, ollama, unsloth)
        status[.lmStudio] = m ? .up : .down
        status[.exo]      = e ? .up : .down
        status[.omlx]     = o ? .up : .down
        status[.ollama]   = a ? .up : .down
        status[.unslothStudio] = u ? .up : .down
    }

    private nonisolated static func reachable(host: String, port: Int, path: String) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do { _ = try await URLSession.shared.data(for: req); return true }  // any response = up
        catch { return false }
    }
}

struct SidebarShell: View {
    @Binding var selectedTab: SidebarTab
    @Binding var selectedConversationID: UUID?
    /// Tabs to show in the nav menu. RootView passes a filtered list so
    /// the Cluster tab only appears when EXO is the active backend.
    var visibleTabs: [SidebarTab] = SidebarTab.sidebarTabs
    var onShowSettings: () -> Void = {}
    /// Conversations to render in the Recents list. Injected by RootView so
    /// the sidebar shows real (AppViewModel) data. Defaults to empty — never
    /// mock data — so a forgotten injection ships an empty list, not four
    /// fabricated conversations.
    var conversations: [Conversation] = []
    /// Fired by the "Delete all" bottom-bar button after confirmation.
    var onDeleteAll: () -> Void = {}
    /// Fired by the "New Task" top-nav row to create a new conversation.
    var onNewConversation: () -> Void = {}
    /// Fired by the right-click → Delete context menu on a Recents row.
    var onDeleteConversation: (UUID) -> Void = { _ in }
    /// Fired when the user confirms a rename from the per-row alert.
    /// Receives the conversation id and the new title (already
    /// trimmed; empty submissions are filtered upstream).
    var onRenameConversation: (UUID, String) -> Void = { _, _ in }
    /// Fired by the right-click → Pin / Unpin menu item.
    var onTogglePin: (UUID) -> Void = { _ in }
    /// Fired by the right-click → Archive menu item.
    var onArchiveConversation: (UUID) -> Void = { _ in }
    /// Fired by the right-click → ↓ Move down menu item.
    var onMoveDown: (UUID) -> Void = { _ in }
    /// Fired by the right-click → Move to project menu item. The
    /// parent presents the MoveToProjectSheet for the given id.
    var onMoveToProject: (UUID) -> Void = { _ in }

    /// Active engine + each engine's host/port, read by the top switcher
    /// strip. Defaults keep previews and other callers safe.
    var settings: AppSettings = AppSettings()
    /// Fired when the user taps an engine cell in the top switcher.
    var onActivateBackend: (BackendIdentifier) -> Void = { _ in }

    // ── Two-model (Agents panel) ────────────────────────────────────
    /// Every (backend, model) pair the role dropdowns can offer.
    var roleModelOptions: [RoleModelOption] = []
    /// True while the model list is being (re)queried across backends.
    var isRefreshingRoleModels: Bool = false
    /// Toggle two-model mode on/off.
    var onToggleTwoModel: (Bool) -> Void = { _ in }
    /// Assign the orchestrator role to a specific (backend, model).
    var onSetOrchestratorModel: (BackendIdentifier, String) -> Void = { _, _ in }
    /// Assign the worker role to a specific (backend, model).
    var onSetWorkerModel: (BackendIdentifier, String) -> Void = { _, _ in }
    /// Clear the orchestrator role (dropdown "None").
    var onClearOrchestratorModel: () -> Void = {}
    /// Clear the worker role (dropdown "None").
    var onClearWorkerModel: () -> Void = {}
    /// Re-query the available models across backends.
    var onRefreshRoleModels: () -> Void = {}
    /// True when a genuine two-model handoff will run (toggle on + two
    /// DIFFERENT models). Drives the honest "1 model / 2 models" status.
    var handoffActive: Bool = false

    @AppStorage("sidebarRecentsCollapsed") private var recentsCollapsed: Bool = false
    @AppStorage("sidebarPinnedCollapsed") private var pinnedCollapsed: Bool = false
    @State private var showDeleteAllAlert = false
    // When non-nil, the chat row with this ID renders an inline
    // TextField in place of its title — Finder/Mail-style rename.
    // Set by the per-row context menu's "Rename task" button.
    // Cleared on commit, cancel, or focus loss.
    @State private var pendingRenameID: UUID? = nil
    @StateObject private var engineProbe = EngineReachabilityProbe()

    var body: some View {
        VStack(spacing: 0) {

            // Wordmark row removed — sparkle + "AgentOS" header was
            // visual noise above the nav menu. The window title bar
            // already identifies the app.

            // ── Engine switcher ─────────────────────────────────────
            engineStrip

            // ── Agents (two-model orchestrator + worker) ────────────
            agentsPanel

            Divider()
                .opacity(0.4)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            // ── Workspace (Chat / Code) ─────────────────────────────
            VStack(spacing: 2) {
                ForEach(visibleTabs.filter(\.isWorkspaceTab)) { tab in
                    SidebarShellRow(
                        style: .navMenu,
                        icon: tab.icon,
                        title: tab.title,
                        isActive: tab == selectedTab,
                        onTap: { selectedTab = tab }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)

            // ── Library nav ─────────────────────────────────────────
            VStack(spacing: 2) {
                ForEach(visibleTabs.filter { !$0.isWorkspaceTab }) { tab in
                    SidebarShellRow(
                        style: .navMenu,
                        icon: tab.icon,
                        title: tab.title,
                        isActive: tab == selectedTab,
                        onTap: { selectedTab = tab }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 8)

            // ── Conversation lists (Pinned + Recents) ─────────────────
            //
            // Two collapsible sections share a single scroll surface so
            // a long pinned list and a long recents list scroll
            // together naturally. The Pinned section only appears
            // when there's at least one pinned conversation.
            if conversations.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 32))                     // was 22
                        .foregroundColor(Theme.Palette.tertiary)
                    Text("No tasks yet")
                        .font(.system(size: 18))                     // was 12
                        .foregroundColor(Theme.Palette.tertiary)
                }
                Spacer()
            } else {
                let pinned = conversations.filter { $0.pinned }
                let unpinned = conversations.filter { !$0.pinned }
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        // Pinned section — only render when there's at
                        // least one pinned chat. Header gets its own
                        // collapse chevron persisted under
                        // `sidebarPinnedCollapsed`.
                        if !pinned.isEmpty {
                            sectionDisclosureHeader(
                                "Pinned",
                                collapsed: pinnedCollapsed,
                                toggle: { pinnedCollapsed.toggle() }
                            )
                            if !pinnedCollapsed {
                                ForEach(pinned) { conv in
                                    sidebarChatRow(conv)
                                }
                            }
                        }

                        // Recents section — only render the header if
                        // there's at least one unpinned chat. When all
                        // chats are pinned, the Pinned section is the
                        // whole list and Recents would be an empty
                        // header.
                        if !unpinned.isEmpty {
                            sectionDisclosureHeader(
                                "Recents",
                                collapsed: recentsCollapsed,
                                toggle: { recentsCollapsed.toggle() }
                            )
                            if !recentsCollapsed {
                                ForEach(grouped(unpinned)) { group in
                                    sectionHeader(group.label)
                                    ForEach(group.conversations) { conv in
                                        sidebarChatRow(conv)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }
            }

            // ── Serving indicator (Local API Server) ────────────────
            servingLine

            // ── Bottom bar ──────────────────────────────────────────
            HStack(spacing: 0) {
                Button {
                    showDeleteAllAlert = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("Delete all")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(Theme.Palette.tertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(conversations.isEmpty)
                .alert("Delete all tasks?", isPresented: $showDeleteAllAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete All", role: .destructive) { onDeleteAll() }
                } message: {
                    Text("This will permanently remove all \(conversations.count) tasks.")
                }

                Spacer()

                Button { onShowSettings() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.Palette.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(Theme.Palette.subtle)  // match composer input card
        .onAppear { engineProbe.start(settings: settings) }
        .onChange(of: settings) { _, s in engineProbe.start(settings: s) }
        .onDisappear { engineProbe.stop() }
    }

    // MARK: - Engine switcher

    private var engineStrip: some View {
        HStack(spacing: 0) {
            engineCell(.lmStudio, "LMS")
            engineCell(.exo, "EXO")
            engineCell(.omlx, "OMLX")
            engineCell(.ollama, "OLLAMA")
            engineCell(.unslothStudio, "UNSLOTH")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.Palette.subtle)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.divider, lineWidth: 0.5))
        )
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    // MARK: - Agents panel (two-model)

    /// The two-model control: a toggle plus an Orchestrator and a Worker
    /// model picker. Roles attach to an explicit (backend + model) pair, so
    /// the orchestrator and worker can be two DIFFERENT models — including
    /// two models on the same backend (e.g. LM Studio's multi-load).
    @ViewBuilder
    private var agentsPanel: some View {
        let twoModel = settings.orchestratorEnabled
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("AGENTS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.Palette.tertiary)
                Spacer()
                if twoModel {
                    Button { onRefreshRoleModels() } label: {
                        Image(systemName: isRefreshingRoleModels
                              ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Theme.Palette.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh the model list from all backends")
                    .disabled(isRefreshingRoleModels)
                }
                Toggle("", isOn: Binding(
                    get: { twoModel },
                    set: { onToggleTwoModel($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Two-model mode: an orchestrator plans, a worker executes")
            }

            if twoModel {
                rolePicker(title: "Orchestrator",
                           tint: Theme.Palette.accent,
                           selectedBackend: settings.orchestratorBackend,
                           selectedModelID: settings.orchestratorModelID,
                           isSet: settings.orchestratorBackendSet,
                           onClear: { onClearOrchestratorModel() }) { backend, modelID in
                    onSetOrchestratorModel(backend, modelID)
                }
                rolePicker(title: "Worker",
                           tint: Theme.Palette.violet,
                           selectedBackend: settings.workerBackend,
                           selectedModelID: settings.workerModelID,
                           isSet: settings.workerBackendSet,
                           onClear: { onClearWorkerModel() }) { backend, modelID in
                    onSetWorkerModel(backend, modelID)
                }
                agentsStatusLine
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .padding(.top, 6)
        .onAppear { if twoModel { onRefreshRoleModels() } }
    }

    /// Honest "how many models will actually run" line. Two distinct models
    /// → a real handoff; same model or only one role set → single-model
    /// (clearly labelled so the user is never misled into thinking two
    /// models run when only one does).
    @ViewBuilder
    private var agentsStatusLine: some View {
        let orchSet = settings.orchestratorBackendSet && !settings.orchestratorModelID.isEmpty
        let workerSet = settings.workerBackendSet && !settings.workerModelID.isEmpty
        let soloID = workerSet ? settings.workerModelID
                   : (orchSet ? settings.orchestratorModelID : "")
        Group {
            if handoffActive {
                Label("Running 2 models — orchestrator → worker",
                      systemImage: "person.2.fill")
                    .foregroundColor(Theme.Palette.success)
            } else if !soloID.isEmpty {
                Label(orchSet && workerSet
                      ? "Running 1 model — both roles are the same model"
                      : "Running 1 model — \(ModelPickerButton.prettyModelName(soloID))",
                      systemImage: "person.fill")
                    .foregroundColor(Theme.Palette.warning)
            } else {
                Label("Pick a model for each role to enable the handoff",
                      systemImage: "exclamationmark.circle")
                    .foregroundColor(Theme.Palette.tertiary)
            }
        }
        .font(.system(size: 9, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One role row: a label and a Menu listing every available
    /// (backend, model) option grouped by backend.
    private func rolePicker(title: String,
                            tint: Color,
                            selectedBackend: BackendIdentifier,
                            selectedModelID: String,
                            isSet: Bool,
                            onClear: @escaping () -> Void,
                            onPick: @escaping (BackendIdentifier, String) -> Void) -> some View {
        // Group options by backend for a tidy menu.
        let grouped = Dictionary(grouping: roleModelOptions, by: \.backend)
        let currentLabel: String = {
            guard isSet, !selectedModelID.isEmpty else { return "Choose model…" }
            if let opt = roleModelOptions.first(where: {
                $0.backend == selectedBackend && $0.modelID == selectedModelID
            }) {
                return opt.label
            }
            // Selected model isn't currently loaded — still show what was picked.
            return "\(selectedBackend.shortLabel) · \(selectedModelID)"
        }()
        let hasSelection = isSet && !selectedModelID.isEmpty

        return HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.Palette.tertiary)
                Menu {
                    // "None" clears the role — lets the user drop back to a
                    // single model (e.g. orchestrator = None → just the worker).
                    Button {
                        onClear()
                    } label: {
                        if !hasSelection {
                            Label("None", systemImage: "checkmark")
                        } else {
                            Text("None")
                        }
                    }
                    Divider()
                    if roleModelOptions.isEmpty {
                        Text(isRefreshingRoleModels ? "Loading…" : "No models found — start a backend")
                    }
                    ForEach([BackendIdentifier.lmStudio, .exo, .omlx, .ollama, .unslothStudio, .custom], id: \.self) { backend in
                        if let opts = grouped[backend], !opts.isEmpty {
                            Section(backend.shortLabel) {
                                ForEach(opts) { opt in
                                    Button {
                                        onPick(opt.backend, opt.modelID)
                                    } label: {
                                        if opt.backend == selectedBackend && opt.modelID == selectedModelID {
                                            Label(opt.displayName, systemImage: "checkmark")
                                        } else {
                                            Text(opt.displayName)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(hasSelection ? Theme.Palette.primary : Theme.Palette.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(Theme.Palette.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.Palette.subtle)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.Palette.divider, lineWidth: 0.5))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func engineCell(_ id: BackendIdentifier, _ label: String) -> some View {
        let active = settings.backend == id
        let reach = engineProbe.status[id] ?? .unknown
        // Single-backend select (one-model mode). Two-model role assignment
        // moved to the dedicated Agents panel below, where roles attach to an
        // explicit (backend + model) pair instead of just a backend.
        return Button { onActivateBackend(id) } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor(reach, active: active))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(active ? .white : Theme.Palette.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(active ? Theme.Palette.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(engineHelp(label, reach))
    }

    private func dotColor(_ r: EngineReachabilityProbe.Reachability, active: Bool) -> Color {
        switch r {
        // Green is reserved for the one ACTIVE engine when it's live, so
        // exactly one light is "on" at a time. A down engine shows red (a
        // warning, active or not); a reachable-but-inactive engine is a
        // neutral grey "available" dot — never green.
        case .up:                 return active ? Theme.Palette.success : Theme.Palette.tertiary
        case .down:               return Theme.Palette.error
        case .checking, .unknown: return Theme.Palette.tertiary
        }
    }

    private func engineHelp(_ label: String, _ r: EngineReachabilityProbe.Reachability) -> String {
        switch r {
        case .up:       return "\(label) — reachable. Click to make it the active engine."
        case .down:     return "\(label) — not reachable. Click to switch anyway."
        case .checking: return "\(label) — checking…"
        case .unknown:  return "\(label) — click to make it the active engine."
        }
    }

    /// "Serving on :11435" — only when the Local API Server is on. It's the
    /// outbound server (other tools call AgentOS), kept distinct from the
    /// engine group above on purpose.
    @ViewBuilder
    private var servingLine: some View {
        if settings.localAPIEnabled {
            HStack(spacing: 5) {
                Circle().fill(Theme.Palette.success).frame(width: 6, height: 6)
                Text("Serving on :\(settings.localAPIPort)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.Palette.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Section header

    /// Section header with its own collapse chevron — used for the
    /// top-level "Pinned" and "Recents" groups. Reuses the same 18pt
    /// semibold typography the old standalone Recents header had so
    /// the visual rhythm doesn't shift after the refactor.
    @ViewBuilder
    private func sectionDisclosureHeader(_ label: String,
                                         collapsed: Bool,
                                         toggle: @escaping () -> Void)
    -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Theme.Palette.tertiary)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Palette.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 16, weight: .semibold))              // was 11 (Today / Yesterday / etc.)
            .foregroundColor(Theme.Palette.tertiary)
            // textCase(.uppercase) removed — group labels are already
            // title-cased ("Today", "Yesterday", "Past 7 days").
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    // MARK: - Chat row

    @ViewBuilder
    private func sidebarChatRow(_ conv: Conversation) -> some View {
        // Only highlight when this row is the selected conversation AND
        // the user is currently on the conversations tab. Without the
        // tab guard, navigating to Projects/Models leaves the
        // Recents row visibly highlighted — producing the multi-
        // highlight regression the user reported. The selection state
        // itself stays in place so the row will re-highlight when the
        // user returns to the conversations tab.
        let isSelected = (selectedConversationID == conv.id)
            && (selectedTab == .chat || selectedTab == .code)
        let isEditing = (pendingRenameID == conv.id)
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
                SidebarShellRow(
                    style: .chat,
                    icon: nil,
                    title: conv.title.isEmpty ? "Untitled" : conv.title,
                    isActive: isSelected,
                    onTap: {
                        selectedConversationID = conv.id
                        if !selectedTab.isWorkspaceTab {
                            selectedTab = .chat
                        }
                    }
                )
            }
        }
        // 6-item context menu in this order:
        //   1. Move to project (opens MoveToProjectSheet)
        //   2. Pin / Unpin (flips conv.pinned)
        //   3. Rename (inline TextField via pendingRenameID)
        //   4. Archive (hides from Recents)
        //   5. Delete (destructive — red)
        //   6. ↓ Move down (swaps updatedAt with the next row)
        .contextMenu {
            Button {
                onMoveToProject(conv.id)
            } label: {
                Label("Move to project", systemImage: "folder")
            }

            Button {
                onTogglePin(conv.id)
            } label: {
                Label(conv.pinned ? "Unpin" : "Pin",
                      systemImage: conv.pinned ? "pin.slash" : "pin")
            }

            Button {
                pendingRenameID = conv.id
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                onArchiveConversation(conv.id)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }

            Button(role: .destructive) {
                onDeleteConversation(conv.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Divider()

            Button {
                onMoveDown(conv.id)
            } label: {
                Label("Move down", systemImage: "arrow.down")
            }
        }
    }
}

// MARK: - Time grouping

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

// MARK: - SidebarShellRow
//
// One component, two styles. The visual contract — accent.opacity(0.18)
// active background, hover background, optimistic highlight on click —
// is byte-for-byte ported from DEV PLAN's SidebarShellRow.

private struct SidebarShellRow: View {
    enum Style { case navMenu, chat }

    let style: Style
    let icon: String?
    let title: String
    let isActive: Bool
    let onTap: () -> Void

    @State private var hovering = false
    @State private var optimisticActive = false

    private var showActive: Bool { isActive || optimisticActive }
    private var fontSize: CGFloat   { 20 }   // sidebar rows (was 27, then 15 / 13)
    private var verticalPad: CGFloat { 6 }

    var body: some View {
        Button {
            optimisticActive = true
            DispatchQueue.main.async { onTap() }
            // Always clear the optimistic flag after a brief window. The
            // `.onChange(of: isActive)` below covers the case where the
            // tap actually transitions the row's active state — but for
            // rows like "New task" whose isActive STAYS false even after
            // a successful tap (because the guard suppresses it once a
            // conversation is selected), the onChange never fires and
            // optimisticActive gets stuck true. A 200 ms reset is long
            // enough for the click flash, short enough to feel snappy.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                optimisticActive = false
            }
        } label: {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .frame(width: 20, alignment: .center)
                }
                Text(title)
                    .font(.system(size: fontSize,
                                  weight: (showActive && style == .navMenu) ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Soft trailing fade so truncation reads as a gentle
                    // blur rather than a hard cut.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.0),
                                .init(color: .black, location: 0.92),
                                .init(color: .black.opacity(0.45), location: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .foregroundColor(showActive ? Theme.Palette.primary : Theme.Palette.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, verticalPad)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(showActive
                          ? Theme.Palette.accent.opacity(0.18)
                          : (hovering ? Theme.Palette.hover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onChange(of: isActive) { _, _ in optimisticActive = false }
    }
}

// MARK: - Inline rename row
//
// Finder-style inline rename. Renders a TextField sized to match
// SidebarShellRow's chat style. On appear it focuses the field and
// selects every character so the user can just start typing to
// replace the title. Return commits, Escape cancels, focus loss
// commits (same convention as Finder / Mail).
//
// The select-all-on-focus uses an AppKit reach-through because
// SwiftUI's TextField has no native "select all" API on macOS.

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
        HStack(spacing: 0) {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 20))                     // matches SidebarShellRow.fontSize
                .foregroundColor(Theme.Palette.primary)
                .focused($focused)
                .onSubmit { onCommit(draft) }
                .onExitCommand { onCancel() }                // Escape
                .onChange(of: focused) { _, isFocused in
                    // Focus loss commits (Finder convention). The
                    // Submit-then-blur path also fires onChange; the
                    // onSubmit above already committed, so the second
                    // commit here is a benign no-op (parent clears
                    // pendingRenameID and reverts to the static row).
                    if !isFocused { onCommit(draft) }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? Theme.Palette.accent.opacity(0.18)
                      : Theme.Palette.subtle)
        )
        .task {
            focused = true
            // Tiny delay so the AppKit field editor is realized and
            // can receive the selectAll command. Without this, the
            // selectAll fires before the field has a backing text
            // view and silently does nothing.
            try? await Task.sleep(nanoseconds: 60_000_000)
            if let editor = NSApp.keyWindow?.firstResponder as? NSText {
                editor.selectAll(nil)
            }
        }
    }
}
