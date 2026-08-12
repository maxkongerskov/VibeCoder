//
//  Plan.swift
//
//  Structured task plan emitted by the assistant for multi-step work.
//  A Plan is attached to the assistant ChatMessage that created it; the
//  agent loop mutates Todo.status as work progresses (pending → inProgress
//  → done / failed / skipped).
//
//  Ported from the original AgentOS DEV PLAN as a pure value type so the
//  App target can render it and the agent loop can mutate it without any
//  UI dependency.
//

import Foundation

public enum TodoStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case done
    case failed
    case skipped
}

public struct Todo: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var status: TodoStatus
    public var result: String?

    public init(id: String,
                text: String,
                status: TodoStatus = .pending,
                result: String? = nil) {
        self.id = id
        self.text = text
        self.status = status
        self.result = result
    }
}

public struct Plan: Codable, Equatable, Sendable {
    public var goal: String
    public var todos: [Todo]

    public init(goal: String, todos: [Todo] = []) {
        self.goal = goal
        self.todos = todos
    }

    /// Empty plans are *not* complete — that used to flash "Plan complete"
    /// the moment `create_plan` landed with zero parsed steps.
    public var isComplete: Bool {
        !todos.isEmpty && todos.allSatisfy { $0.status == .done || $0.status == .skipped }
    }

    public var hasFailures: Bool {
        todos.contains { $0.status == .failed }
    }
}

public extension TodoStatus {
    /// Parse a status from whatever the model wrote — case-insensitive,
    /// space/underscore-tolerant, with the common synonyms folded in.
    init?(lenient raw: String) {
        let s = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        switch s {
        case "pending", "todo", "not_started", "open": self = .pending
        case "in_progress", "inprogress", "doing", "started", "active", "wip": self = .inProgress
        case "done", "complete", "completed", "finished": self = .done
        case "failed", "fail", "error", "blocked": self = .failed
        case "skipped", "skip", "cancelled", "canceled": self = .skipped
        default:
            if let v = TodoStatus(rawValue: s) { self = v } else { return nil }
        }
    }
}

public extension Plan {
    static func make(goal: String, todoTexts: [String]) -> Plan {
        let todos = todoTexts.enumerated().map { index, text in
            Todo(id: String(index + 1), text: text)
        }
        return Plan(goal: goal, todos: todos)
    }

    func updatingTodo(id: String, status: TodoStatus, result: String?) -> Plan? {
        guard let idx = todos.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = self
        copy.todos[idx].status = status
        if let result, !result.isEmpty { copy.todos[idx].result = result }
        return copy
    }

    func revising(addingTexts: [String], removingIDs: [String], goal newGoal: String?) -> Plan {
        var copy = self
        if let newGoal, !newGoal.isEmpty { copy.goal = newGoal }
        if !removingIDs.isEmpty {
            let drop = Set(removingIDs)
            copy.todos.removeAll { drop.contains($0.id) }
        }
        if !addingTexts.isEmpty {
            let nextID = (copy.todos.compactMap { Int($0.id) }.max() ?? 0) + 1
            for (offset, text) in addingTexts.enumerated() {
                copy.todos.append(Todo(id: String(nextID + offset), text: text))
            }
        }
        return copy
    }

    func renderedChecklist() -> String {
        func marker(_ status: TodoStatus) -> String {
            switch status {
            case .pending: return "[ ]"
            case .inProgress: return "[~]"
            case .done: return "[x]"
            case .failed: return "[!]"
            case .skipped: return "[-]"
            }
        }
        var lines = ["Plan — \(goal)"]
        for todo in todos {
            var line = "\(todo.id). \(marker(todo.status)) \(todo.text)"
            if let result = todo.result, !result.isEmpty { line += " → \(result)" }
            lines.append(line)
        }
        let settled = todos.filter { $0.status == .done || $0.status == .skipped }.count
        lines.append("Progress: \(settled)/\(todos.count) complete")
        return lines.joined(separator: "\n")
    }
}
