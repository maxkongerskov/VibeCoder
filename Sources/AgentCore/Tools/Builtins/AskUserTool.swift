//
//  AskUserTool.swift
//
//  Lets the agent pause the loop and ask the user a clarifying question.
//

import Foundation

public struct AskUserTool: Tool {
    public static let name = "ask_user"
    public static let category: ToolCategory = .agent
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core

    public static let schema = ToolSchema(
        name: name,
        description: """
        Pause and ask the user a clarifying question before proceeding. \
        Use this when you are genuinely uncertain about intent and the wrong \
        assumption would waste significant work. Do NOT use it to ask for \
        information you could reasonably infer, or for confirmation of small \
        decisions. When you call this tool the UI shows a question card — \
        the user can pick one of your suggested options or type a custom \
        answer. Their response is returned as the tool result.
        """,
        parameters: ToolSchema.Parameters(
            properties: [
                "question": .init(
                    type: "string",
                    description: "The question to show the user. Be specific and concise."
                ),
                "options": .init(
                    type: "array",
                    description: "Optional 2–4 pre-set answer chips. Omit for open-ended questions.",
                    items: .init(type: "string")
                )
            ],
            required: ["question"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let question = arguments.stringOptional("question") ?? ""
        guard !question.isEmpty else {
            throw ToolError.invalidArguments("ask_user requires a non-empty 'question' field")
        }

        let options: [String] = arguments.stringArray("options")

        guard let reviewer = context.userQuestionReviewer else {
            return ToolResult(
                content: "[ask_user] No interactive reviewer available. Proceeding with best judgment.",
                isError: false
            )
        }

        let agentQuestion = AgentQuestion(question: question, options: options)
        let answer = await reviewer.ask(agentQuestion)

        return ToolResult(
            content: answer.isEmpty
                ? "[ask_user] User dismissed the question without answering. Proceed with best judgment."
                : answer,
            isError: false
        )
    }
}