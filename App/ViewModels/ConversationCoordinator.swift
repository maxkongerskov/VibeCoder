//
//  ConversationCoordinator.swift
//
//  Conversation list, per-conversation ChatViewModels, CRUD, sidebar
//  ordering, and scheduled-task integration.
//

import Foundation
import AgentCore

@MainActor
final class ConversationCoordinator: ObservableObject {

    weak var host: AppViewModel?

    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID?

    private var chatViewModels: [UUID: ChatViewModel] = [:]
    private var scheduler: SchedulerService?

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
            convo.projectRoot = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        }
        conversations.insert(convo, at: 0)
        try? await ConversationStore.shared.save(convo)

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
        Task { try? await ConversationStore.shared.save(convo) }
    }

    @discardableResult
    func newConversation(in project: Project) -> UUID {
        guard let host else { return UUID() }
        var convo = Conversation()
        convo.modelID = host.selectedModelID
        convo.projectRoot = project.url
        conversations.insert(convo, at: 0)
        selectedConversationID = convo.id
        Task { try? await ConversationStore.shared.save(convo) }
        return convo.id
    }

    func deleteConversation(_ id: UUID) {
        if let vm = chatViewModels[id] {
            vm.cancelForDeletion()
        }
        conversations.removeAll { $0.id == id }
        chatViewModels.removeValue(forKey: id)
        // Prefer next visible (non-archived) task — never land on an archived row
        // that is hidden from the sidebar (C2).
        if selectedConversationID == id {
            selectedConversationID = conversations.first(where: { !$0.archived })?.id
        }
        Task {
            // Only jobs owned by this conversation — never kill other chats' work.
            await BackgroundJobManager.shared.cleanup(conversationID: id)
            do {
                try await ConversationStore.shared.delete(id: id)
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
        let snapshot = conversations[idx]
        Task { try? await ConversationStore.shared.save(snapshot) }
    }

    func togglePin(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].pinned.toggle()
        if let vm = chatViewModels[id] {
            vm.conversation.pinned = conversations[idx].pinned
        }
        let snapshot = conversations[idx]
        Task { try? await ConversationStore.shared.save(snapshot) }
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
        let snapshot = conversations[idx]
        Task { try? await ConversationStore.shared.save(snapshot) }
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
        let snapA = conversations[aIdx]
        let snapB = conversations[bIdx]
        Task {
            try? await ConversationStore.shared.save(snapA)
            try? await ConversationStore.shared.save(snapB)
        }
    }

    func moveConversationToProject(_ id: UUID, project: Project?) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].projectRoot = project?.url
        if let vm = chatViewModels[id] {
            vm.conversation.projectRoot = project?.url
        }
        let snapshot = conversations[idx]
        Task { try? await ConversationStore.shared.save(snapshot) }
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
        // in the sidebar). Worktree branch is intentionally not shared.
        let copy = Conversation(
            id: UUID(),
            title: source.title.isEmpty ? "Untitled (copy)" : "\(source.title) (copy)",
            createdAt: Date(),
            updatedAt: Date(),
            messages: source.messages,
            modelID: source.modelID,
            projectRoot: source.projectRoot,
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
        conversations.insert(copy, at: 0)
        selectedConversationID = copy.id
        Task {
            do {
                try await ConversationStore.shared.save(copy)
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
                try? await ConversationStore.shared.delete(id: id)
            }
        }
    }

    func refreshConversations() async {
        do {
            let list = try await ConversationStore.shared.list()
            self.conversations = list
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
        } catch {
            Diagnostics.error("refreshConversations: \(error.localizedDescription)")
        }
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
            if let vm = chatViewModels[conversations[i].id] {
                vm.conversation.projectRoot = nil
            }
            let snapshot = conversations[i]
            Task {
                do {
                    try await ConversationStore.shared.save(snapshot)
                } catch {
                    Diagnostics.error("clearProjectBinding save: \(error.localizedDescription)")
                }
            }
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
            conversations[i].projectRoot = newPath
            if let vm = chatViewModels[conversations[i].id] {
                vm.conversation.projectRoot = newPath
            }
            let snapshot = conversations[i]
            Task {
                do {
                    try await ConversationStore.shared.save(snapshot)
                } catch {
                    Diagnostics.error("updateProjectBinding save: \(error.localizedDescription)")
                }
            }
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
        let snapshot = conversations[index]
        Task { try? await ConversationStore.shared.save(snapshot) }
    }
}