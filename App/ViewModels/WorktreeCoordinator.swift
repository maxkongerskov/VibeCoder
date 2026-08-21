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
        let shortID = WorktreeService.conversationShortId(from: convo.id)
        do {
            let created = try WorktreeService.createOrReuseWorktree(
                projectFolder: projectRoot.path,
                conversationShortId: shortID
            )
            conversations.updateConversation(at: idx) {
                $0.worktreeBranch = created.branch
                $0.worktreeOptOut = false
            }
            conversations.syncChatViewModel(conversationID) {
                $0.conversation.worktreeBranch = created.branch
                $0.conversation.worktreeOptOut = false
            }
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
            // Stay isolated: do not leave the same chat on main until next select.
            var afterMerge = conversations.conversation(at: idx)
            do {
                _ = try WorktreeService.ensureDefaultWorktreeIfNeeded(&afterMerge)
                conversations.updateConversation(at: idx) {
                    $0.worktreeBranch = afterMerge.worktreeBranch
                    $0.worktreeOptOut = afterMerge.worktreeOptOut
                }
            } catch let err as WorktreeError {
                worktreeError = err.errorDescription
            } catch {
                worktreeError = "Worktree create failed: \(error.localizedDescription)"
            }
            let latest = conversations.conversation(at: idx)
            conversations.syncChatViewModel(conversationID) {
                $0.conversation.worktreeBranch = latest.worktreeBranch
                $0.conversation.worktreeOptOut = latest.worktreeOptOut
            }
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
        guard let projectRoot = convo.projectRoot,
              let branch = convo.worktreeBranch,
              let worktreeURL = convo.worktreeRootURL else { return }
        do {
            try WorktreeService.discard(
                worktreePath: worktreeURL.path,
                branch: branch,
                projectFolder: projectRoot.path
            )
            conversations.updateConversation(at: idx) { $0.worktreeBranch = nil }
            conversations.syncChatViewModel(conversationID) { $0.conversation.worktreeBranch = nil }
            conversations.saveConversationSnapshot(at: idx)
        } catch let err as WorktreeError {
            worktreeError = err.errorDescription
        } catch {
            worktreeError = "Discard failed: \(error.localizedDescription)"
        }
    }

    /// Escape hatch: edit the main checkout without deleting the worktree.
    func disableWorktree(for conversationID: UUID) {
        guard let conversations,
              let idx = conversations.conversationIndex(for: conversationID) else { return }
        conversations.updateConversation(at: idx) { WorktreeService.disableWorktreeMode(&$0) }
        conversations.syncChatViewModel(conversationID) {
            WorktreeService.disableWorktreeMode(&$0.conversation)
        }
        conversations.saveConversationSnapshot(at: idx)
    }
}
