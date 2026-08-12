//
//  WorktreeCoordinator.swift
//
//  Worktree enable / merge / discard lifecycle and error surfacing.
//

import Foundation
import AgentCore

@MainActor
final class WorktreeCoordinator: ObservableObject {

    weak var conversations: ConversationCoordinator?

    @Published var worktreeError: String?

    func enableWorktree(for conversationID: UUID) {
        guard let conversations,
              let idx = conversations.conversationIndex(for: conversationID) else { return }
        let convo = conversations.conversation(at: idx)
        guard let projectRoot = convo.projectRoot else {
            worktreeError = "This conversation has no project folder. Bind a folder before enabling worktree mode."
            return
        }
        let shortID = String(convo.id.uuidString.prefix(8)).lowercased()
        do {
            let created = try WorktreeService.createOrReuseWorktree(
                projectFolder: projectRoot.path,
                conversationShortId: shortID
            )
            conversations.updateConversation(at: idx) { $0.worktreeBranch = created.branch }
            conversations.syncChatViewModel(conversationID) { $0.conversation.worktreeBranch = created.branch }
            conversations.saveConversationSnapshot(at: idx)
        } catch let err as WorktreeError {
            worktreeError = err.errorDescription
        } catch {
            worktreeError = "Worktree create failed: \(error.localizedDescription)"
        }
    }

    func mergeWorktree(for conversationID: UUID, commitMessage: String = WorktreeService.defaultMergeCommitMessage) {
        guard let conversations,
              let idx = conversations.conversationIndex(for: conversationID) else { return }
        let convo = conversations.conversation(at: idx)
        guard let projectRoot = convo.projectRoot,
              let branch = convo.worktreeBranch,
              let worktreeURL = convo.worktreeRootURL else { return }
        do {
            try WorktreeService.mergeAndRemove(
                worktreePath: worktreeURL.path,
                branch: branch,
                projectFolder: projectRoot.path,
                commitMessage: commitMessage
            )
            conversations.updateConversation(at: idx) { $0.worktreeBranch = nil }
            conversations.syncChatViewModel(conversationID) { $0.conversation.worktreeBranch = nil }
            conversations.saveConversationSnapshot(at: idx)
        } catch let err as WorktreeError {
            worktreeError = err.errorDescription
        } catch {
            worktreeError = "Merge failed: \(error.localizedDescription)"
        }
    }

    func discardWorktree(for conversationID: UUID) {
        guard let conversations,
              let idx = conversations.conversationIndex(for: conversationID) else { return }
        let convo = conversations.conversation(at: idx)
        if let projectRoot = convo.projectRoot,
           let branch = convo.worktreeBranch,
           let worktreeURL = convo.worktreeRootURL {
            do {
                try WorktreeService.discard(
                    worktreePath: worktreeURL.path,
                    branch: branch,
                    projectFolder: projectRoot.path
                )
            } catch let err as WorktreeError {
                worktreeError = err.errorDescription
            } catch {
                worktreeError = "Discard failed: \(error.localizedDescription)"
            }
        }
        conversations.updateConversation(at: idx) { $0.worktreeBranch = nil }
        conversations.syncChatViewModel(conversationID) { $0.conversation.worktreeBranch = nil }
        conversations.saveConversationSnapshot(at: idx)
    }
}