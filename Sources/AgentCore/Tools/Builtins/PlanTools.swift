//
//  PlanTools.swift
//
//  Structured-planning tools: create_plan, update_todo, revise_plan.
//  State lives in PlanStore keyed by conversationID.
//

import Foundation

public struct CreatePlanTool: Tool {
    public static let name = "create_plan"
    public static let category: ToolCategory = .planning
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Lay out a short plan for multi-step work: a one-line goal and the \
        ordered steps. Steps are numbered 1..N; mark each done with \
        update_todo as you finish it. Calling this again replaces the plan.
        """,
        parameters: .init(
            properties: [
                "goal": .init(type: "string", description: "One-line statement of what 'done' looks like."),
                "todos": .init(type: "array", description: "Ordered list of concrete step descriptions.",
                               items: .init(type: "string"))
            ],
            required: ["goal", "todos"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let goal = try arguments.string("goal")
        let todos = arguments.stringArray("todos")
        guard !todos.isEmpty else {
            return ToolResult(content: "Error: provide at least one step in `todos`.", isError: true)
        }
        let plan = Plan.make(goal: goal, todoTexts: todos)
        await PlanStore.shared.setPlan(
            plan, for: context.conversationID, workingDirectory: context.workingDirectory)
        return ToolResult(content: "Created plan.\n\(plan.renderedChecklist())")
    }
}

public struct UpdateTodoTool: Tool {
    public static let name = "update_todo"
    public static let category: ToolCategory = .planning
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Update one plan step's status as you work. Mark a step in_progress \
        when you start it and done when it's finished (or failed / skipped).
        """,
        parameters: .init(
            properties: [
                "id": .init(type: "string", description: "The step number from the plan (e.g. \"2\")."),
                "status": .init(type: "string",
                                description: "New status.",
                                enum: TodoStatus.allCases.map(\.rawValue)),
                "result": .init(type: "string", description: "Optional one-line note on the outcome.")
            ],
            required: ["id", "status"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let id = try arguments.string("id")
        let statusRaw = try arguments.string("status")
        guard let status = TodoStatus(lenient: statusRaw) else {
            let valid = TodoStatus.allCases.map(\.rawValue).joined(separator: ", ")
            return ToolResult(content: "Error: unknown status '\(statusRaw)'. Use one of: \(valid).", isError: true)
        }
        let convo = context.conversationID
        let cwd = context.workingDirectory
        // Wave C: rehydrate from disk/transcript before failing "no plan yet".
        guard let current = await PlanStore.shared.plan(for: convo, workingDirectory: cwd) else {
            return ToolResult(content: "Error: no plan yet — call create_plan first.", isError: true)
        }
        guard let updated = await PlanStore.shared.updateTodo(
            id: id, status: status,
            result: arguments.stringOptional("result"),
            for: convo,
            workingDirectory: cwd
        ) else {
            return ToolResult(content: "Error: no step with id '\(id)'. Current plan:\n\(current.renderedChecklist())",
                              isError: true)
        }
        return ToolResult(content: updated.renderedChecklist())
    }
}

public struct RevisePlanTool: Tool {
    public static let name = "revise_plan"
    public static let category: ToolCategory = .planning
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .deferred
    public static let schema = ToolSchema(
        name: name,
        description: """
        Amend the current plan WITHOUT resetting finished steps: append new \
        steps you discovered, remove steps by id that no longer apply, \
        and/or restate the goal. Use create_plan instead to start over.
        """,
        parameters: .init(
            properties: [
                "add": .init(type: "array", description: "New step descriptions to append.",
                             items: .init(type: "string")),
                "remove": .init(type: "array", description: "Step ids to drop.",
                                items: .init(type: "string")),
                "goal": .init(type: "string", description: "Optional new goal.")
            ],
            required: []
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let add = arguments.stringArray("add")
        let remove = arguments.stringArray("remove")
        let goal = arguments.stringOptional("goal")
        guard !add.isEmpty || !remove.isEmpty || (goal?.isEmpty == false) else {
            return ToolResult(content: "Error: nothing to revise — pass `add`, `remove`, or `goal`.", isError: true)
        }
        guard let revised = await PlanStore.shared.revise(
            for: context.conversationID,
            addingTexts: add, removingIDs: remove, goal: goal,
            workingDirectory: context.workingDirectory
        ) else {
            return ToolResult(content: "Error: no plan yet — call create_plan first.", isError: true)
        }
        return ToolResult(content: revised.renderedChecklist())
    }
}