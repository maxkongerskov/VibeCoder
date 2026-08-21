//
//  ConversationCoordinator.swift
//
//  Conversation list, per-conversation ChatViewModels, CRUD, sidebar
//  ordering, and scheduled-task integration.
//

import Foundation
import AgentCore

/// Merge a sidebar metadata row with the live `ChatViewModel` transcript
/// before disk write. The list array is often a pre-turn snapshot; saving
/// it last-write-wins can drop an in-flight turn on relaunch.
enum ConversationSaveMerge {
    static func snapshot(listRow: Conversation, live: Conversation?) -> Conversation {
        guard var live else { return listRow }
        live.title = listRow.title
        live.pinned = listRow.pinned
        live.archived = listRow.archived
        live.projectRoot = listRow.projectRoot
        live.worktreeBranch = listRow.worktreeBranch
        live.worktreeOptOut = listRow.worktreeOptOut
        live.updatedAt = listRow.updatedAt
        return live
    }
}

@MainActor
final class ConversationCoordinator: ObservableObject {

    weak var host: AppViewModel?

    /// Test seam. Production uses `ConversationStore.shared`.
    var conversationStore: any ConversationStoring = ConversationStore.shared

    @Published var conversations: [Conversation] = []
    /// True after the first `refreshConversations()` finishes (success or fail).
    /// First-run seeding must wait so we do not create a task before disk load.
    @Published var conversationsDidLoad = false
    @Published var selectedConversationID: UUID? {
        // Session-scoped permission grants ("Allow for this session") are
        // keyed by conversation — keep the coordinator's scope in sync.
        didSet {
            host?.shellApprovalCoordinatorService.activeConversationID = selectedConversationID
            if oldValue != selectedConversationID {
                ensureWorktreeOnSelect(selectedConversationID)
            }
        }
    }
    /// JSON files `listDirectory()` could not decode. Sidebar banner + Show in Finder.
    @Published var unloadableConversations: [ConversationLoadFailure] = []

    private var chatViewModels: [UUID: ChatViewModel] = [:]
    private var scheduler: SchedulerService?
    private var isSeedingFirstConversation = false

    func startScheduler() async {
        let store = ScheduledTaskStore()
        let scheduler = SchedulerService(store: store, fireTask: { [weak self] task in
            await self?.runScheduledTask(task) ?? nil
        })
        await scheduler.start()
        self.scheduler = scheduler
    }

    @discardableResult
    func runScheduledTask(_ task: ScheduledTask) async -> UUID? {
        guard let host else { return nil }
        let selected = host.selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !selected.isEmpty else {
            Diagnostics.warn("Scheduler: skipping \"\(task.name)\" — no model selected")
            return nil
        }
        guard !host.availableModels.isEmpty else {
            Diagnostics.warn("Scheduler: skipping \"\(task.name)\" — no model available")
            return nil
        }
        var convo = Conversation(title: task.name.isEmpty ? "Scheduled task" : task.name)
        convo.modelID = host.selectedModelID
        if let folder = task.projectFolder, !folder.isEmpty {
            applyDefaultWorktree(
                to: &convo,
                projectRoot: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath))
        }
        conversations.insert(convo, at: 0)
        _ = await persistCreatedConversation(convo, context: "runScheduledTask")

        let prompt = [task.shortPrompt, task.longPrompt]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let vm = chatViewModel(for: convo.id)
        vm.send(prompt.isEmpty ? task.name : prompt, forceHeadless: true)
        return convo.id
    }

    func chatViewModel(for conversationID: UUID) -> ChatViewModel {
        if let existing = chatViewModels[conversationID] { return existing }
        let convo = conversations.first(where: { $0.id == conversationID }) ?? Conversation(id: conversationID)
        guard let host else {
            preconditionFailure("ConversationCoordinator.host must be wired before chatViewModel(for:)")
        }
        let vm = ChatViewModel(conversation: convo, app: host)
        chatViewModels[conversationID] = vm
        return vm
    }

    func newConversation() {
        guard let host else { return }
        var convo = Conversation()
        convo.modelID = host.selectedModelID
        conversations.insert(convo, at: 0)
        selectedConversationID = convo.id
        persistCreatedConversationInBackground(convo, context: "newConversation")
    }

    /// First-run: one visible task so ChatView's connect-hero is the first screen.
    /// No-ops before the store loads, when a task already exists, or if a seed is in flight.
    func ensureFirstConversationIfNeeded() {
        guard conversationsDidLoad else { return }
        guard !conversations.contains(where: { !$0.archived }) else { return }
        guard !isSeedingFirstConversation else { return }
        isSeedingFirstConversation = true
        newConversation()
        isSeedingFirstConversation = false
    }

    @discardableResult
    func newConversation(in project: Project) -> UUID {
        guard let host else { return UUID() }
        var convo = Conversation()
        convo.modelID = host.selectedModelID
        applyDefaultWorktree(to: &convo, projectRoot: project.url)
        conversations.insert(convo, at: 0)
        selectedConversationID = convo.id
        persistCreatedConversationInBackground(convo, context: "newConversation(in:)")
        return convo.id
    }

    func deleteConversation(_ id: UUID) {
        if let vm = chatViewModels[id] {
            vm.cancelForDeletion()
        }
        conversations.removeAll { $0.id == id }
        chatViewModels.removeValue(forKey: id)
        host?.shellApprovalCoordinatorService.sessionGrants.clearConversation(id)
        // Prefer next visible (non-archived) task — never land on an archived row
        // that is hidden from the sidebar (C2).
        if selectedConversationID == id {
            selectedConversationID = conversations.first(where: { !$0.archived })?.id
        }
        Task {
            // Only jobs owned by this conversation — never kill other chats' work.
            await BackgroundJobManager.shared.cleanup(conversationID: id)
            do {
                try await conversationStore.delete(id: id)
            } catch {
                Diagnostics.error("deleteConversation(\(id)): \(error.localizedDescription)")
            }
        }
    }

    func renameConversation(id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = trimmed
        if let vm = chatViewModels[id] {
            vm.conversation.title = trimmed
        }
        persistMergedConversation(id: id)
    }

    func togglePin(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].pinned.toggle()
        if let vm = chatViewModels[id] {
            vm.conversation.pinned = conversations[idx].pinned
        }
        persistMergedConversation(id: id)
    }

    func archiveConversation(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].archived = true
        if let vm = chatViewModels[id] {
            vm.conversation.archived = true
        }
        if selectedConversationID == id {
            selectedConversationID = conversations.first(where: { !$0.archived })?.id
        }
        persistMergedConversation(id: id)
    }

    func moveConversationDown(_ id: UUID) {
        let visible = sidebarOrderedConversations()
        guard let here = visible.firstIndex(where: { $0.id == id }),
              here + 1 < visible.count else { return }
        // Pin group is a hard partition. Last pinned sitting above the first
        // unpinned cannot move down — rewriting dates would be a no-op on
        // order but would still dirty `updatedAt`.
        guard visible[here + 1].pinned == visible[here].pinned else { return }
        let belowID = visible[here + 1].id

        guard let aIdx = conversations.firstIndex(where: { $0.id == id }),
              let bIdx = conversations.firstIndex(where: { $0.id == belowID }) else { return }
        let aDate = conversations[aIdx].updatedAt
        let bDate = conversations[bIdx].updatedAt
        let newAdate = min(aDate, bDate).addingTimeInterval(-1)
        conversations[aIdx].updatedAt = newAdate
        if conversations[bIdx].updatedAt <= newAdate {
            conversations[bIdx].updatedAt = newAdate.addingTimeInterval(1)
        }
        persistMergedConversation(id: id)
        persistMergedConversation(id: belowID)
    }

    func moveConversationToProject(_ id: UUID, project: Project?) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        applyDefaultWorktree(to: &conversations[idx], projectRoot: project?.url)
        if let vm = chatViewModels[id] {
            vm.conversation.projectRoot = conversations[idx].projectRoot
            vm.conversation.worktreeBranch = conversations[idx].worktreeBranch
            vm.conversation.worktreeOptOut = conversations[idx].worktreeOptOut
        }
        persistMergedConversation(id: id)
    }

    func sidebarOrderedConversations() -> [Conversation] {
        let visible = conversations.filter { !$0.archived }
        return visible.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updatedAt > b.updatedAt
        }
    }

    func duplicateConversation(_ id: UUID) {
        guard let source = conversations.first(where: { $0.id == id }) else { return }
        // Copy session metadata users expect to keep: pin, deferred tools,
        // sampling, rail pref. Do NOT copy archived (a duplicate should appear
        // in the sidebar). Do not share the source worktree branch or opt-out:
        // RELEASE_BAR contract 4 — git `projectRoot` gets the default isolation
        // rule via `applyDefaultWorktree` (fresh `agentcore/<copyId>`).
        var copy = Conversation(
            id: UUID(),
            title: source.title.isEmpty ? "Untitled (copy)" : "\(source.title) (copy)",
            createdAt: Date(),
            updatedAt: Date(),
            messages: source.messages,
            modelID: source.modelID,
            projectRoot: nil,
            worktreeBranch: nil,
            systemPromptOverride: source.systemPromptOverride,
            samplingOverride: source.samplingOverride,
            unlockedDeferredTools: source.unlockedDeferredTools,
            pinned: source.pinned,
            archived: false,
            orchestratorBriefs: source.orchestratorBriefs,
            railUserPreference: source.railUserPreference,
            stickyContextPins: source.stickyContextPins
        )
        if let root = source.projectRoot {
            applyDefaultWorktree(to: &copy, projectRoot: root)
        }
        conversations.insert(copy, at: 0)
        selectedConversationID = copy.id
        Task {
            do {
                try await conversationStore.save(copy)
            } catch {
                Diagnostics.error("duplicateConversation save: \(error.localizedDescription)")
            }
        }
    }

    func deleteAllConversations() {
        let ids = conversations.map(\.id)
        for vm in chatViewModels.values {
            vm.cancelForDeletion()
        }
        conversations.removeAll()
        chatViewModels.removeAll()
        selectedConversationID = nil
        Task {
            // Match single-delete: tear down bg jobs/subagents owned by each
            // conversation so Delete All cannot leave orphan workers running.
            for id in ids {
                await BackgroundJobManager.shared.cleanup(conversationID: id)
                try? await conversationStore.delete(id: id)
            }
        }
    }

    func refreshConversations() async {
        do {
            let listing = try await conversationStore.listDirectory()
            self.conversations = listing.conversations
            self.unloadableConversations = listing.unloadable
            let list = listing.conversations
            let visible = list.filter { !$0.archived }
            // Auto-select first *visible* task only. Selecting an archived
            // conversation left the detail pane on a chat missing from the
            // sidebar (C2 residual from C1 dual-selection work).
            if let sel = selectedConversationID,
               list.contains(where: { $0.id == sel && $0.archived }) {
                selectedConversationID = visible.first?.id
            } else if selectedConversationID == nil
                        || !list.contains(where: { $0.id == selectedConversationID }) {
                selectedConversationID = visible.first?.id
            }
            // Load path: isolate the visible selection even when the id
            // did not change (didSet would not re-run).
            ensureWorktreeOnSelect(selectedConversationID)
        } catch {
            Diagnostics.error("refreshConversations: \(error.localizedDescription)")
        }
        conversationsDidLoad = true
    }

    // MARK: - Project binding (Projects pane delete/rename)

    /// Clear `projectRoot` on every conversation pointing at `path` so deleted
    /// projects do not leave sidebar tasks tethered to a trash path.
    /// Paths are compared via `SafeModeConfig.normalizePath` (trailing slash safe).
    func clearProjectBinding(at path: URL) {
        let target = SafeModeConfig.normalizePath(path.path)
        guard !target.isEmpty else { return }
        for i in conversations.indices {
            guard let root = conversations[i].projectRoot else { continue }
            guard SafeModeConfig.normalizePath(root.path) == target else { continue }
            conversations[i].projectRoot = nil
            conversations[i].worktreeBranch = nil
            conversations[i].worktreeOptOut = false
            if let vm = chatViewModels[conversations[i].id] {
                vm.conversation.projectRoot = nil
                vm.conversation.worktreeBranch = nil
                vm.conversation.worktreeOptOut = false
            }
            persistMergedConversation(id: conversations[i].id)
        }
    }

    /// Re-point conversations bound to `oldPath` → `newPath` after project rename/move.
    func updateProjectBinding(from oldPath: URL, to newPath: URL) {
        let old = SafeModeConfig.normalizePath(oldPath.path)
        let neu = SafeModeConfig.normalizePath(newPath.path)
        guard !old.isEmpty, old != neu else { return }
        for i in conversations.indices {
            guard let root = conversations[i].projectRoot else { continue }
            guard SafeModeConfig.normalizePath(root.path) == old else { continue }
            if conversations[i].worktreeBranch != nil {
                applyDefaultWorktree(to: &conversations[i], projectRoot: newPath)
            } else {
                conversations[i].projectRoot = newPath
            }
            if let vm = chatViewModels[conversations[i].id] {
                vm.conversation.projectRoot = conversations[i].projectRoot
                vm.conversation.worktreeBranch = conversations[i].worktreeBranch
                vm.conversation.worktreeOptOut = conversations[i].worktreeOptOut
            }
            persistMergedConversation(id: conversations[i].id)
        }
    }

    /// Load/select: isolate saved git chats that never got a worktree.
    /// Opt-out stays on main. Not called from send.
    private func ensureWorktreeOnSelect(_ id: UUID?) {
        guard let id, let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        let beforeBranch = conversations[idx].worktreeBranch
        let beforeOptOut = conversations[idx].worktreeOptOut
        do {
            _ = try WorktreeService.ensureDefaultWorktreeIfNeeded(&conversations[idx])
        } catch let err as WorktreeError {
            host?.worktreeError = err.errorDescription
            return
        } catch {
            host?.worktreeError = "Worktree create failed: \(error.localizedDescription)"
            return
        }
        let after = conversations[idx]
        guard after.worktreeBranch != beforeBranch || after.worktreeOptOut != beforeOptOut else {
            return
        }
        if let vm = chatViewModels[id] {
            vm.conversation.projectRoot = after.projectRoot
            vm.conversation.worktreeBranch = after.worktreeBranch
            vm.conversation.worktreeOptOut = after.worktreeOptOut
        }
        persistMergedConversation(id: id)
    }

    /// Git folders get an `agentcore/<shortId>` worktree by default.
    /// Create failure is surfaced on `host.worktreeError` and does not leave
    /// the conversation bound to the git main tree. Non-git bind succeeds and
    /// surfaces `notAGitRepo` (ARCHITECTURE §11.2) — it does not throw.
    @discardableResult
    private func applyDefaultWorktree(to convo: inout Conversation, projectRoot: URL?) -> WorktreeBindResult {
        do {
            let result = try WorktreeService.bindProjectEnablingWorktree(&convo, projectRoot: projectRoot)
            if let reason = result.userVisibleReason {
                host?.worktreeError = reason
                if let vm = chatViewModels[convo.id] {
                    vm.statusLine = reason
                }
            }
            return result
        } catch let err as WorktreeError {
            host?.worktreeError = err.errorDescription
            if let path = convo.projectRoot?.path {
                return .skippedNotGit(path: path)
            }
            return .unbound
        } catch {
            host?.worktreeError = "Worktree create failed: \(error.localizedDescription)"
            if let path = convo.projectRoot?.path {
                return .skippedNotGit(path: path)
            }
            return .unbound
        }
    }

    func conversationIndex(for id: UUID) -> Int? {
        conversations.firstIndex(where: { $0.id == id })
    }

    func conversation(at index: Int) -> Conversation {
        conversations[index]
    }

    func updateConversation(at index: Int, _ update: (inout Conversation) -> Void) {
        update(&conversations[index])
    }

    func syncChatViewModel(_ conversationID: UUID, update: (ChatViewModel) -> Void) {
        if let vm = chatViewModels[conversationID] {
            update(vm)
        }
    }

    func saveConversationSnapshot(at index: Int) {
        persistMergedConversation(id: conversations[index].id)
    }

    /// Persist a newly created conversation. Logs on disk failure (Ada P2).
    @discardableResult
    func persistCreatedConversation(_ snapshot: Conversation, context: String) async -> Bool {
        do {
            try await conversationStore.save(snapshot)
            return true
        } catch {
            Diagnostics.error("\(context)(\(snapshot.id)): \(error.localizedDescription)")
            return false
        }
    }

    private func persistCreatedConversationInBackground(_ snapshot: Conversation, context: String) {
        Task { _ = await persistCreatedConversation(snapshot, context: context) }
    }

    /// Persist list-row metadata + the live VM transcript (if one exists).
    private func persistMergedConversation(id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        let merged = ConversationSaveMerge.snapshot(
            listRow: conversations[idx],
            live: chatViewModels[id]?.conversation
        )
        conversations[idx] = merged
        if let vm = chatViewModels[id] {
            vm.conversation = merged
        }
        let snapshot = merged
        Task {
            do {
                try await conversationStore.save(snapshot)
            } catch {
                Diagnostics.error("persistMergedConversation(\(id)): \(error.localizedDescription)")
            }
        }
    }
}