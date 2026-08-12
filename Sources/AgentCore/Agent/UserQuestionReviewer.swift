//
//  UserQuestionReviewer.swift
//
//  Plumbing for the `ask_user` tool — lets the agent pause the loop,
//  surface a question to the user, and resume with their answer.
//

import Foundation

public struct AgentQuestion: Sendable, Identifiable {
    public let id: UUID
    public let question: String
    public let options: [String]

    public init(id: UUID = UUID(), question: String, options: [String] = []) {
        self.id = id
        self.question = question
        self.options = options
    }
}

public struct UserQuestionReviewer: Sendable {
    public let ask: @Sendable (AgentQuestion) async -> String

    public init(ask: @escaping @Sendable (AgentQuestion) async -> String) {
        self.ask = ask
    }
}