//
//  AppViewModel.swift
//
//  Top-level app state. Owns domain coordinators and delegates to them
//  while preserving the public API surface SwiftUI call sites expect.
//

import Foundation
import SwiftUI
import AppKit
import Combine
import AgentCore

/// One assignable (backend, model) pair for the orchestrator/worker
/// dropdowns in the sidebar Agents panel. `id` is stable across refreshes
/// so SwiftUI keeps menu selection consistent.
struct RoleModelOption: Identifiable, Hashable {
    let backend: BackendIdentifier
    let modelID: String
    let displayName: String
    var id: String { "\(backend.rawValue)::\(modelID)" }
    var label: String { "\(backend.shortLabel) · \(displayName)" }
}

extension BackendIdentifier {
    var shortLabel: String {
        switch self {
        case .lmStudio: return "LM Studio"
        case .exo:      return "EXO"
        case .mlx:      return "MLX"
        case .omlx:     return "oMLX"
        case .ollama:   return "Ollama"
        case .unslothStudio: return "Unsloth"
        case .xai:      return "xAI"   // retired product surface; kept for settings decode
        case .custom:   return "Custom"
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {

    // MARK: - Coordinators

    let backendConnection = BackendConnectionCoordinator()
    let conversationsCoordinator = ConversationCoordinator()
    let worktreeCoordinator = WorktreeCoordinator()
    let xcodeMCP = XcodeMCPCoordinator()

    private var cancellables = Set<AnyCancellable>()

    init() {
        wireCoordinators()
        bridgeCoordinatorChanges()
    }

    private func wireCoordinators() {
        backendConnection.host = self
        conversationsCoordinator.host = self
        worktreeCoordinator.conversations = conversationsCoordinator
    }

    private func bridgeCoordinatorChanges() {
        backendConnection.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        conversationsCoordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        worktreeCoordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        xcodeMCP.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - App-owned state

    @Published var openedProject: Project?

    @Published var settings: AppSettings = AppSettings() {
        didSet {
            guard settings != oldValue else { return }
            let snap = settings
            Task { await SettingsStore.shared.replace(snap) }
        }
    }

    // z.code-style 4-mode permission system. `executionMode` is the
    // user-facing source of truth (the chip in the input card). It
    // drives `safeModeOn` so the permissions sheet / fingerprint glow
    // stay consistent. `headlessModeOn` is orthogonal.
    @Published var executionMode: ExecutionMode = .build {
        didSet {
            let want = executionMode.enablesSafeMode
            if safeModeOn != want { safeModeOn = want }
        }
    }

    /// Legacy binary Safe Mode flag — kept for the permissions sheet.
    /// Prefer `executionMode` as the source of truth. Writing this from
    /// the sheet syncs back to a matching mode when not in Plan.
    /// Default matches `.build` (Ask) — first-run is not Full/YOLO.
    @Published var safeModeOn: Bool = true {
        didSet {
            // Plan is first-class read-only: never eject Plan → YOLO when
            // the user toggles the legacy Safe Mode switch (Wave C fix).
            if executionMode == .plan {
                if !safeModeOn {
                    // Snap back — Plan always implies restricted mode.
                    safeModeOn = true
                }
                return
            }
            if safeModeOn && !executionMode.enablesSafeMode {
                executionMode = .build   // Ask before changes
            } else if !safeModeOn && executionMode.enablesSafeMode {
                // Leaving Ask Safe Mode → Auto (edit), not Full — less
                // surprising than jumping to YOLO from a single toggle.
                executionMode = .edit
            }
        }
    }
    @Published var headlessModeOn: Bool = false

    @Published var roleModelOptions: [RoleModelOption] = []
    @Published var isRefreshingRoleModels: Bool = false

    let sleepAssertion = SleepAssertionService()
    let patchReviewCoordinator = PatchReviewCoordinator()
    let userQuestionCoordinator = UserQuestionCoordinator()
    let planApprovalCoordinator = PlanApprovalCoordinator()
    let shellApprovalCoordinatorService = ShellApprovalCoordinatorService()
    private var headlessRunCount = 0

    // MARK: - Forwarded: conversations

    var conversations: [Conversation] {
        get { conversationsCoordinator.conversations }
        set { conversationsCoordinator.conversations = newValue }
    }

    var selectedConversationID: UUID? {
        get { conversationsCoordinator.selectedConversationID }
        set { conversationsCoordinator.selectedConversationID = newValue }
    }

    // MARK: - Forwarded: backend connection

    var availableModels: [ModelDescriptor] {
        get { backendConnection.availableModels }
        set { backendConnection.availableModels = newValue }
    }

    var selectedModelID: String? {
        get { backendConnection.selectedModelID }
        set { backendConnection.selectedModelID = newValue }
    }

    var activeModelSettings: ModelSettings? {
        get { backendConnection.activeModelSettings }
        set { backendConnection.activeModelSettings = newValue }
    }

    var modelListError: String? {
        get { backendConnection.modelListError }
        set { backendConnection.modelListError = newValue }
    }

    var modelLoadError: String? {
        get { backendConnection.modelLoadError }
        set { backendConnection.modelLoadError = newValue }
    }

    var isLoadingModel: Bool {
        backendConnection.isLoadingModel
    }

    var localServerRunning: Bool {
        get { backendConnection.localServerRunning }
        set { backendConnection.localServerRunning = newValue }
    }

    internal var testingBackend: (any InferenceBackend)? {
        get { backendConnection.testingBackend }
        set { backendConnection.testingBackend = newValue }
    }

    // MARK: - Forwarded: worktree

    var worktreeError: String? {
        get { worktreeCoordinator.worktreeError }
        set { worktreeCoordinator.worktreeError = newValue }
    }

    // MARK: - Forwarded: Xcode MCP

    var xcodeMCPStatus: XcodeMCPConnectionStatus {
        get { xcodeMCP.status }
        set { xcodeMCP.status = newValue }
    }

    var xcodeMCPLive: Bool { xcodeMCP.isLive }

    // MARK: - Safe Mode

    var safeModeAllowedPaths: [String] {
        get { settings.safeModeAllowedPaths }
        set { persistSettings { $0.safeModeAllowedPaths = newValue } }
    }

    var safeModeAllowedShellPrefixes: [String] {
        get { settings.safeModeAllowedShellPrefixes }
        set { persistSettings { $0.safeModeAllowedShellPrefixes = newValue } }
    }

    var effectiveSafeModeConfig: SafeModeConfig? {
        guard safeModeOn || executionMode.enablesSafeMode else { return nil }
        let roots = [openedProject?.url].compactMap { $0 }
        return settings.safeModeConfig(projectRoots: roots)
    }

    /// Cycle Plan → Ask → Auto → Full (⇧Tab in chat).
    func cycleExecutionMode() {
        executionMode = executionMode.next()
    }

    // MARK: - Headless mode

    func beginHeadlessRun() {
        headlessRunCount += 1
        if headlessRunCount == 1 { sleepAssertion.acquire() }
    }

    func endHeadlessRun() {
        headlessRunCount = max(0, headlessRunCount - 1)
        if headlessRunCount == 0 { sleepAssertion.release() }
    }

    // MARK: - Boot

    func boot() async {
        await AgentCore.bootstrap()
        // Offline PDF tools (PDFKit / Vision / local MD→PDF) live in the App
        // target; register after builtins so the agent can call them.
        await PDFToolRegistration.register()
        BrowserUseRegistration.install()
        self.settings = await SettingsStore.shared.current()
        // PC2: seatbelt env for SafeBash (auto leaves keys unset).
        settings.shellSeatbeltPreference.applyToProcessEnvironment()

        if settings.backend == .mlx {
            settings.backend = .ollama
            await SettingsStore.shared.update { $0.backend = .ollama }
            Diagnostics.info("Migrated persisted backend .mlx → .ollama (MLX paused; llama.cpp product removed)")
        }
        if settings.backend == .xai {
            settings.backend = .lmStudio
            await SettingsStore.shared.update { $0.backend = .lmStudio }
            Diagnostics.info("Migrated persisted backend .xai → .lmStudio (Grok / xAI removed from product)")
        }
        // Orchestrator / worker roles must not stay pinned to xAI.
        if settings.orchestratorBackend == .xai || settings.workerBackend == .xai {
            await SettingsStore.shared.update {
                if $0.orchestratorBackend == .xai { $0.orchestratorBackend = .lmStudio }
                if $0.workerBackend == .xai { $0.workerBackend = .lmStudio }
            }
            settings = await SettingsStore.shared.current()
        }

        await refreshConversations()
        await refreshModels()
        if settings.localAPIEnabled {
            await startLocalServer()
        }
        if settings.xcodeMCPEnabled {
            await startXcodeMCP()
        }
        await conversationsCoordinator.startScheduler()
    }

    // MARK: - Conversations (delegated)

    func runScheduledTask(_ task: ScheduledTask) async -> UUID? {
        await conversationsCoordinator.runScheduledTask(task)
    }

    func chatViewModel(for conversationID: UUID) -> ChatViewModel {
        conversationsCoordinator.chatViewModel(for: conversationID)
    }

    var conversationsDidLoad: Bool {
        conversationsCoordinator.conversationsDidLoad
    }

    func newConversation() { conversationsCoordinator.newConversation() }

    func ensureFirstConversationIfNeeded() {
        conversationsCoordinator.ensureFirstConversationIfNeeded()
    }

    func newConversation(in project: Project) -> UUID {
        conversationsCoordinator.newConversation(in: project)
    }

    func deleteConversation(_ id: UUID) { conversationsCoordinator.deleteConversation(id) }
    func renameConversation(id: UUID, to newTitle: String) {
        conversationsCoordinator.renameConversation(id: id, to: newTitle)
    }
    func togglePin(_ id: UUID) { conversationsCoordinator.togglePin(id) }
    func archiveConversation(_ id: UUID) { conversationsCoordinator.archiveConversation(id) }
    func moveConversationDown(_ id: UUID) { conversationsCoordinator.moveConversationDown(id) }
    func moveConversationToProject(_ id: UUID, project: Project?) {
        conversationsCoordinator.moveConversationToProject(id, project: project)
    }
    func sidebarOrderedConversations() -> [Conversation] {
        conversationsCoordinator.sidebarOrderedConversations()
    }

    var unloadableConversations: [ConversationLoadFailure] {
        conversationsCoordinator.unloadableConversations
    }
    func duplicateConversation(_ id: UUID) { conversationsCoordinator.duplicateConversation(id) }
    func deleteAllConversations() { conversationsCoordinator.deleteAllConversations() }
    func refreshConversations() async { await conversationsCoordinator.refreshConversations() }

    // MARK: - Worktree (delegated)

    func enableWorktree(for conversationID: UUID) {
        worktreeCoordinator.enableWorktree(for: conversationID)
    }
    func mergeWorktree(
        for conversationID: UUID,
        commitMessage: String = WorktreeService.defaultMergeCommitMessage
    ) {
        worktreeCoordinator.mergeWorktree(for: conversationID, commitMessage: commitMessage)
    }
    func discardWorktree(for conversationID: UUID) {
        worktreeCoordinator.discardWorktree(for: conversationID)
    }
    func disableWorktree(for conversationID: UUID) {
        worktreeCoordinator.disableWorktree(for: conversationID)
    }

    // MARK: - Backend connection (delegated)

    func ingestConnectionTestModels(_ models: [ModelDescriptor]) async {
        await backendConnection.ingestConnectionTestModels(models)
    }
    func activateModel(id: String) async { await backendConnection.activateModel(id: id) }
    func applyPreparedModelSettings(_ settings: ModelSettings) {
        backendConnection.applyPreparedModelSettings(settings)
    }
    func refreshModels() async { await backendConnection.refreshModels() }
    func currentBackend() -> any InferenceBackend { backendConnection.currentBackend() }
    func makeBackend(_ id: BackendIdentifier) -> any InferenceBackend {
        backendConnection.makeBackend(id)
    }

    /// Switch provider if needed, refresh that backend's model list, then warm the model.
    func selectModel(backend: BackendIdentifier, modelID: String) async {
        if settings.backend != backend {
            // Persist backend without the full updateSettings side-effects race;
            // then explicitly refresh against the new backend.
            settings.backend = backend
            let snap = settings
            await SettingsStore.shared.replace(snap)
        }
        await refreshModels()
        await activateModel(id: modelID)
    }

    /// Load a model on its provider without necessarily switching the active backend.
    /// Used by the text-input model list Load control.
    @discardableResult
    func loadModel(backend: BackendIdentifier, modelID: String) async -> String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty model id" }
        backendConnection.modelLoadError = nil
        backendConnection.isLoadingModel = true
        defer { backendConnection.isLoadingModel = false }
        let desc = availableModels.first(where: {
            $0.id == trimmed && $0.backend == backend
        }) ?? ModelDescriptor(
            id: trimmed,
            displayName: trimmed,
            backend: backend,
            supportsTools: true)
        do {
            try await makeBackend(backend).warmUp(model: desc)
            // Refresh lists so isLoaded flags update in the picker.
            if settings.backend == backend {
                await refreshModels()
            }
            return nil
        } catch {
            let msg = error.localizedDescription
            backendConnection.modelLoadError = msg
            return msg
        }
    }

    /// Unload a model on its provider from the text-input model list.
    @discardableResult
    func unloadModel(backend: BackendIdentifier, modelID: String) async -> String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty model id" }
        let desc = availableModels.first(where: {
            $0.id == trimmed && $0.backend == backend
        }) ?? ModelDescriptor(
            id: trimmed,
            displayName: trimmed,
            backend: backend,
            supportsTools: true)
        do {
            try await makeBackend(backend).unload(model: desc)
            if settings.backend == backend {
                await refreshModels()
            }
            return nil
        } catch {
            let msg = error.localizedDescription
            backendConnection.modelLoadError = msg
            return msg
        }
    }

    func pinEXOModel(_ id: String) { backendConnection.pinEXOModel(id) }
    func activateBackend(_ id: BackendIdentifier) { backendConnection.activateBackend(id) }
    func startLocalServer() async { await backendConnection.startLocalServer() }
    func stopLocalServer() async { await backendConnection.stopLocalServer() }

    // MARK: - Xcode MCP (delegated)

    func startXcodeMCP() async { await xcodeMCP.start() }
    func stopXcodeMCP() async { await xcodeMCP.stop() }
    func reconnectXcodeMCP() async { await xcodeMCP.reconnect() }

    // MARK: - Settings

    /// Persist allow-list / connection-field edits without refreshing backends
    /// or toggling servers. Host/port/API-key typing must use this path.
    /// Writes only via `settings` didSet (single SettingsStore.replace).
    func persistSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
    }

    /// Count of `applySettingsSideEffects` calls (tests). Production unused.
    internal private(set) var settingsSideEffectCount = 0

    /// Mutate settings and run side effects (model refresh / local API / Xcode MCP).
    /// Persistence is owned solely by `settings.didSet`.
    func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        applySettingsSideEffects()
    }

    /// Re-apply live connection side effects from the current `settings`
    /// snapshot (Test / Use this backend / commit). Does not mutate fields.
    func applySettingsSideEffects() {
        settingsSideEffectCount += 1
        let snap = settings
        // PC2: keep SafeBash seatbelt env in sync with Settings preference.
        snap.shellSeatbeltPreference.applyToProcessEnvironment()
        Task {
            // MCP config may have changed — reconnect next turn with new servers.
            await MCPSessionHolder.shared.invalidate()
            await self.refreshModels()
            if snap.localAPIEnabled {
                await self.startLocalServer()
            } else {
                await self.stopLocalServer()
            }
            // Even if server already running, re-apply agentTools flag (PB7).
            if snap.localAPIEnabled {
                await LocalAPIServer.shared.setAgentToolsEnabled(snap.localAPIAgentToolsEnabled)
            }
            if snap.xcodeMCPEnabled {
                await self.startXcodeMCP()
            } else {
                await self.stopXcodeMCP()
            }
        }
    }

    /// Untether conversations from a deleted project folder (Projects UI).
    func clearProjectBinding(at path: URL) {
        conversationsCoordinator.clearProjectBinding(at: path)
    }

    /// Retarget conversations after a project folder rename/move.
    func updateProjectBinding(from oldPath: URL, to newPath: URL) {
        conversationsCoordinator.updateProjectBinding(from: oldPath, to: newPath)
    }

    // MARK: - Per-role backend resolution (orchestrator / worker)

    enum AgentRole { case orchestrator, worker }

    func backend(for role: AgentRole) -> any InferenceBackend {
        guard settings.orchestratorEnabled else { return currentBackend() }
        let id: BackendIdentifier = (role == .orchestrator)
            ? settings.orchestratorBackend
            : settings.workerBackend
        return makeBackend(id)
    }

    func resolveRoleModel(for role: AgentRole) async -> ModelDescriptor? {
        let backend = backend(for: role)
        let preferredID = (role == .orchestrator)
            ? settings.orchestratorModelID
            : settings.workerModelID
        guard !preferredID.isEmpty else { return nil }
        let models = (try? await backend.listModels()) ?? []
        // Exact user choice only — never fall back to the backend's first
        // listed model (oMLX often returns its pinned GLM as models[0]).
        return models.first(where: { $0.id == preferredID })
    }

    var twoModelEnabled: Bool { settings.orchestratorEnabled }

    func roleSelection(for role: AgentRole) -> (backend: BackendIdentifier, modelID: String)? {
        let isSet = (role == .orchestrator) ? settings.orchestratorBackendSet : settings.workerBackendSet
        let modelID = (role == .orchestrator) ? settings.orchestratorModelID : settings.workerModelID
        let backend = (role == .orchestrator) ? settings.orchestratorBackend : settings.workerBackend
        guard isSet, !modelID.isEmpty else { return nil }
        return (backend, modelID)
    }

    var orchestrationActive: Bool {
        guard settings.orchestratorEnabled,
              let o = roleSelection(for: .orchestrator),
              let w = roleSelection(for: .worker) else { return false }
        return o.backend != w.backend || o.modelID != w.modelID
    }

    func executingRole() -> AgentRole? {
        guard settings.orchestratorEnabled else { return nil }
        if roleSelection(for: .worker) != nil { return .worker }
        if roleSelection(for: .orchestrator) != nil { return .orchestrator }
        return nil
    }

    func clearRole(_ role: AgentRole) {
        updateSettings {
            switch role {
            case .orchestrator:
                $0.orchestratorModelID = ""
                $0.orchestratorBackendSet = false
            case .worker:
                $0.workerModelID = ""
                $0.workerBackendSet = false
            }
        }
    }

    func refreshRoleModelOptions() async {
        isRefreshingRoleModels = true
        defer { isRefreshingRoleModels = false }
        let ids: [BackendIdentifier] = [.lmStudio, .exo, .omlx, .ollama, .unslothStudio, .custom]
        var collected: [RoleModelOption] = []
        await withTaskGroup(of: (BackendIdentifier, [ModelDescriptor]).self) { group in
            for id in ids {
                let backend = makeBackend(id)
                group.addTask {
                    let models = (try? await backend.listModels()) ?? []
                    return (id, models)
                }
            }
            for await (id, models) in group {
                collected.append(contentsOf: models.map {
                    RoleModelOption(backend: id, modelID: $0.id, displayName: $0.displayName)
                })
            }
        }
        collected.sort {
            $0.backend.rawValue == $1.backend.rawValue
                ? $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                : $0.backend.rawValue < $1.backend.rawValue
        }
        self.roleModelOptions = collected
    }

    func setTwoModelEnabled(_ on: Bool) {
        updateSettings { $0.orchestratorEnabled = on }
        if on { Task { await refreshRoleModelOptions() } }
    }

    func setOrchestratorModel(backend: BackendIdentifier, modelID: String) {
        updateSettings {
            $0.orchestratorEnabled = true
            $0.orchestratorBackend = backend
            $0.orchestratorModelID = modelID
            $0.orchestratorBackendSet = true
        }
    }

    func setWorkerModel(backend: BackendIdentifier, modelID: String) {
        updateSettings {
            $0.orchestratorEnabled = true
            $0.workerBackend = backend
            $0.workerModelID = modelID
            $0.workerBackendSet = true
        }
    }
}

// MARK: - Remote control host

extension AppViewModel: RemoteControlHost {
    func remoteControlSnapshot() -> RemoteSnapshotDTO? {
        guard let id = selectedConversationID else { return nil }
        let vm = chatViewModel(for: id)
        let msgs: [RemoteMessageDTO] = vm.conversation.messages.compactMap { m in
            switch m.role {
            case .user:
                return RemoteMessageDTO(id: m.id.uuidString, role: "user", content: m.content)
            case .assistant:
                return RemoteMessageDTO(
                    id: m.id.uuidString,
                    role: "assistant",
                    content: m.content,
                    reasoning: m.reasoningContent
                )
            default:
                return nil
            }
        }
        let modelName: String? = {
            let mid = vm.conversation.modelID ?? selectedModelID
            guard let mid else { return nil }
            return availableModels.first(where: { $0.id == mid })?.displayName ?? mid
        }()
        return RemoteSnapshotDTO(
            conversationId: id.uuidString,
            title: vm.conversation.title.isEmpty ? "AgentOS" : vm.conversation.title,
            isRunning: vm.isRunning,
            status: vm.statusLine,
            streaming: vm.streamingContent,
            reasoning: vm.streamingReasoning,
            activity: vm.currentActivityLine.map { "\($0.verb) · \($0.status)" } ?? vm.currentActivityLabel,
            model: modelName,
            messages: msgs
        )
    }

    func remoteControlSend(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if selectedConversationID == nil {
            newConversation()
        }
        guard let id = selectedConversationID else { return }
        chatViewModel(for: id).send(trimmed)
    }

    func remoteControlStop() {
        guard let id = selectedConversationID else { return }
        chatViewModel(for: id).cancel()
    }
}