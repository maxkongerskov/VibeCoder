//
//  UserQuestionCoordinator.swift
//
//  Bridges AgentCore's `UserQuestionReviewer` to `QuestionCardView`.
//
//  Concurrent ask_user calls are FIFO-queued: only one question is shown
//  at a time (`pendingQuestion`); additional asks wait until the user
//  answers the active card. Never resumes a waiter with an empty string
//  just because another question is already open — that previously made
//  the agent treat a dropped concurrent question as a silent dismiss.
//

import Foundation
import SwiftUI
import AgentCore

@MainActor
final class UserQuestionCoordinator: ObservableObject {

    /// The question currently shown in the UI (head of the FIFO queue).
    @Published var pendingQuestion: AgentQuestion?

    /// Number of questions waiting *behind* the active one (not counting
    /// `pendingQuestion`). Exposed so the card can show "N more queued".
    @Published private(set) var queuedCount: Int = 0

    private struct Waiter {
        let question: AgentQuestion
        let continuation: CheckedContinuation<String, Never>
    }

    /// Continuation for the active (displayed) question.
    private var activeContinuation: CheckedContinuation<String, Never>?
    /// Questions waiting to be shown, in arrival order.
    private var waitQueue: [Waiter] = []

    /// Suspend until the user answers. Concurrent callers enqueue FIFO
    /// and resume with their own answer when promoted — never with `""`
    /// solely because another question was already pending.
    func ask(_ question: AgentQuestion) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            if activeContinuation == nil {
                activeContinuation = cont
                pendingQuestion = question
            } else {
                waitQueue.append(Waiter(question: question, continuation: cont))
                queuedCount = waitQueue.count
            }
        }
    }

    /// Answer the currently displayed question. Promotes the next queued
    /// question (if any) so its continuation stays suspended until the
    /// user answers it too.
    func resolve(answer: String) {
        guard let cont = activeContinuation else { return }
        activeContinuation = nil
        pendingQuestion = nil
        cont.resume(returning: answer)
        promoteNextIfNeeded()
    }

    private func promoteNextIfNeeded() {
        guard !waitQueue.isEmpty else {
            queuedCount = 0
            return
        }
        let next = waitQueue.removeFirst()
        queuedCount = waitQueue.count
        activeContinuation = next.continuation
        pendingQuestion = next.question
    }

    nonisolated func makeReviewer() -> UserQuestionReviewer {
        UserQuestionReviewer { [weak self] question in
            // Coordinator gone (e.g. app teardown) → empty answer is treated
            // by AskUserTool as "dismissed / proceed with judgment". That is
            // not the concurrent-drop path; concurrent asks always queue.
            guard let self else { return "" }
            return await self.ask(question)
        }
    }
}
