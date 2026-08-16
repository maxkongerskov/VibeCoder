//
//  ConversationListViewModel.swift
//  AgentOS — Claude Edition
//
//  Ported from DEV PLAN's ViewModels/ConversationListViewModel.swift.
//
//  Bridges the AgentCore `ConversationStore` actor to a `@Published`
//  array the sidebar can render. The DEV PLAN version called a
//  synchronous `ConversationStore.shared.loadAll()` on a non-actor
//  singleton; here the store is an `actor` so the call must be `async`.
//  We refresh from disk on init (off the main hop) and after every
//  mutation, keeping the @Published array as the snapshot the UI reads.
//
//  Differences vs DEV PLAN:
//    • `Conversation.modelId` → `Conversation.modelID` (AgentCore casing).
//    • `Conversation.projectFolder` → `Conversation.projectRoot` (URL).
//    • Headless/archived/worktree-binding flags don't exist on the
//      ported `Conversation` shape; the helpers that touched them are
//      omitted with a `// MARK: skipped — field not on AgentCore.Conversation`
//      breadcrumb so a later pass can re-add them without re-deriving
//      where they belong.
//    • `chatViewModel(for:)` cache delegates to the App's `AppViewModel`
//      which already owns a `[UUID: ChatViewModel]` map — we forward
//      there instead of re-implementing the cache, so a chat survives
//      navigation away from its pane (the original cache's purpose).
//    • Deletion still cascades into the cache via `AppViewModel`.
//

import Foundation
import Combine
import AgentCore

@MainActor
final class ConversationListViewModel: ObservableObject {

    // MARK: - Published state

    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID?
    @Published var unloadableConversations: [ConversationLoadFailure] = []

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    // MARK: - Dependencies

    /// AgentCore store, injected so tests can substitute a directory-
    /// scoped instance. Defaults to the shared on-disk store.
    private let store: ConversationStore

    /// Optional handle on the App's top-level view model — used to
    /// forward ChatViewModel creation and eviction to its existing
    /// cache. Kept weak so a long-lived list VM doesn't pin the app VM.
    private weak var app: AppViewModel?

    // MARK: - Init

    init(store: ConversationStore = .shared, app: AppViewModel? = nil) {
        self.store = store
        self.app = app
        Task { [weak self] in
            await self?.load()
        }
    }

    // MARK: - Loading

    /// Pulls the conversation list from disk and replaces the in-memory
    /// snapshot. The DEV PLAN call was synchronous; here it's async
    /// because `ConversationStore` is an actor.
    func load() async {
        do {
            let listing = try await store.listDirectory()
            self.conversations = listing.conversations
            self.unloadableConversations = listing.unloadable
            if selectedConversationID == nil {
                selectedConversationID = listing.conversations.first?.id
            }
        } catch {
            Diagnostics.error("ConversationListViewModel.load: \(error.localizedDescription)")
        }
    }

    // MARK: - ChatViewModel cache (delegated to AppViewModel)

    /// In DEV PLAN this VM owned the `[UUID: ChatViewModel]` cache. In
    /// Claude Edition that cache already lives on `AppViewModel` (see
    /// `AppViewModel.chatViewModel(for:)`), so we forward there to keep
    /// a single source of truth.
    func chatViewModel(for conversation: Conversation) -> ChatViewModel? {
        guard let app else { return nil }
        return app.chatViewModel(for: conversation.id)
    }

    // MARK: - Mutations

    /// Create a fresh conversation pinned to a model id. Mirrors the
    /// DEV PLAN signature. `projectFolder`/`title` are optional and the
    /// resulting conversation is persisted and selected.
    @discardableResult
    func newConversation(modelID: String,
                         projectRoot: URL? = nil,
                         title: String? = nil) -> Conversation {
        var conv = Conversation()
        conv.modelID = modelID
        if let r = projectRoot { conv.projectRoot = r }
        if let t = title, !t.isEmpty { conv.title = t }
        conversations.insert(conv, at: 0)
        selectedConversationID = conv.id
        let snapshot = conv
        Task { [store] in
            try? await store.save(snapshot)
        }
        return conv
    }

    /// Called by ChatViewModel callbacks — keeps the list in sync with
    /// updates persisted from the chat. Re-sorts so the most-recently
    /// updated conversation floats to the top.
    func update(_ conversation: Conversation) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[idx] = conversation
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Duplicate a conversation. The copy starts fresh (new id, "(copy)"
    /// suffix on the title, current timestamps). Keeps pin / deferred tools
    /// (C2 parity with ConversationCoordinator.duplicateConversation).
    @discardableResult
    func duplicate(_ conversation: Conversation) -> Conversation {
        // `Conversation.id` is `let`, so we have to build a new
        // value-init'd copy rather than mutate in place.
        let copy = Conversation(
            id: UUID(),
            title: conversation.title + " (copy)",
            createdAt: Date(),
            updatedAt: Date(),
            messages: conversation.messages,
            modelID: conversation.modelID,
            projectRoot: conversation.projectRoot,
            worktreeBranch: nil,                         // copy starts off any worktree
            systemPromptOverride: conversation.systemPromptOverride,
            samplingOverride: conversation.samplingOverride,
            unlockedDeferredTools: conversation.unlockedDeferredTools,
            pinned: conversation.pinned,
            archived: false,
            railUserPreference: conversation.railUserPreference
        )
        conversations.insert(copy, at: 0)
        selectedConversationID = copy.id
        let snapshot = copy
        Task { [store] in
            try? await store.save(snapshot)
        }
        return copy
    }

    /// Rename a conversation. Persists the new title and re-sorts.
    func rename(_ conversation: Conversation, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[idx].title = trimmed
        conversations[idx].updatedAt = Date()
        conversations.sort { $0.updatedAt > $1.updatedAt }
        let snapshot = conversations[idx]
        Task { [store] in
            try? await store.save(snapshot)
        }
    }

    /// Delete one conversation. If it was the selected one we re-select
    /// the new top — otherwise the selection is left untouched (right-
    /// clicking some OTHER chat → Delete shouldn't jump the main pane).
    func delete(_ conversation: Conversation) {
        let wasSelected = (selectedConversationID == conversation.id)
        conversations.removeAll { $0.id == conversation.id }
        app?.deleteConversation(conversation.id)         // also evicts cached VM + persists delete
        if wasSelected {
            selectedConversationID = conversations.first?.id
        }
    }

    /// Wipe every conversation. Uses the shared store's delete API one-
    /// by-one so the on-disk JSON files are removed too.
    func deleteAll() {
        let ids = conversations.map(\.id)
        conversations = []
        selectedConversationID = nil
        Task { [store] in
            for id in ids {
                try? await store.delete(id: id)
            }
        }
        // Evict any cached VMs.
        if let app {
            for id in ids { app.deleteConversation(id) }
        }
    }

    // MARK: - Project binding

    /// Clear `projectRoot` on every conversation pointing at `path` —
    /// used after a project folder is deleted so chats fall back to
    /// "Recents" rather than referencing a stale URL.
    /// Compares via normalized paths (trailing slash / symlink-safe-ish).
    func clearProjectBinding(at path: URL) {
        let target = SafeModeConfig.normalizePath(path.path)
        guard !target.isEmpty else { return }
        for i in conversations.indices {
            guard let root = conversations[i].projectRoot else { continue }
            guard SafeModeConfig.normalizePath(root.path) == target else { continue }
            conversations[i].projectRoot = nil
            let snapshot = conversations[i]
            Task { [store] in
                try? await store.save(snapshot)
            }
        }
    }

    /// Re-point every conversation bound to `oldPath` to `newPath` —
    /// used after a project folder is renamed/moved.
    func updateProjectBinding(from oldPath: URL, to newPath: URL) {
        let old = SafeModeConfig.normalizePath(oldPath.path)
        let neu = SafeModeConfig.normalizePath(newPath.path)
        guard !old.isEmpty, old != neu else { return }
        for i in conversations.indices {
            guard let root = conversations[i].projectRoot else { continue }
            guard SafeModeConfig.normalizePath(root.path) == old else { continue }
            conversations[i].projectRoot = newPath
            let snapshot = conversations[i]
            Task { [store] in
                try? await store.save(snapshot)
            }
        }
    }

    // MARK: - Filtering helpers (used by sidebar sections)

    /// Conversations bound to a specific project folder, most-recent
    /// first.
    func conversations(in projectRoot: URL) -> [Conversation] {
        conversations.filter { $0.projectRoot == projectRoot }
    }

    /// Conversations with no `projectRoot` — the sidebar's "Recents"
    /// list.
    var untetheredConversations: [Conversation] {
        conversations.filter { $0.projectRoot == nil }
    }

    // MARK: - Skipped (not on AgentCore.Conversation yet)
    //
    //   • setArchived(_:_:)        — no `archived` flag on Conversation
    //   • newHeadlessConversation  — no `headlessMode` / scheduler service
    //   • updateProjectBinding via String path — DEV PLAN used `String`
    //     for `projectFolder`; AgentCore uses `URL`. The URL overload
    //     above is the equivalent.
    //
    // These return without a stub so callers will get a clean compile
    // error pointing at the missing API rather than a silent no-op.
}
