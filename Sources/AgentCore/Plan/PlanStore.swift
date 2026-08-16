//
//  PlanStore.swift
//
//  Per-conversation home for the assistant's structured Plan. The plan
//  tools (create_plan / update_todo / revise_plan) read and mutate it
//  here so the plan survives across tool calls within a turn without a
//  hidden field on every ChatMessage. Keyed by conversationID.
//
//  Wave C: also durable under workingDirectory/.agentos/plans/<id>/plan.json
//  and rehydratable from transcript tool_calls when memory is cold.
//

import Foundation

public actor PlanStore {
    public static let shared = PlanStore()

    private var plans: [UUID: Plan] = [:]
    /// Working directories used for durable `plan.json`, so `clear(for:)`
    /// can delete the on-disk copy without the caller re-passing cwd.
    private var durableRoots: [UUID: URL] = [:]

    public init() {}

    public func plan(for conversation: UUID) -> Plan? { plans[conversation] }

    /// In-memory plan, loading durable JSON when cold.
    public func plan(for conversation: UUID, workingDirectory: URL?) -> Plan? {
        if let existing = plans[conversation] { return existing }
        if let root = PathConfinement.usableWorkspaceRoot(workingDirectory),
           let disk = Self.loadDurable(conversation: conversation, workingDirectory: root) {
            plans[conversation] = disk
            durableRoots[conversation] = root
            return disk
        }
        return nil
    }

    public func setPlan(_ plan: Plan, for conversation: UUID) {
        plans[conversation] = plan
    }

    /// Persist plan in memory and (when cwd is a usable workspace) on disk.
    public func setPlan(_ plan: Plan, for conversation: UUID, workingDirectory: URL?) {
        plans[conversation] = plan
        if let root = PathConfinement.usableWorkspaceRoot(workingDirectory) {
            durableRoots[conversation] = root
            Self.saveDurable(plan, conversation: conversation, workingDirectory: root)
        }
    }

    @discardableResult
    public func updateTodo(id todoID: String,
                           status: TodoStatus,
                           result: String?,
                           for conversation: UUID) -> Plan? {
        guard let updated = plans[conversation]?.updatingTodo(id: todoID, status: status, result: result)
        else { return nil }
        plans[conversation] = updated
        return updated
    }

    @discardableResult
    public func updateTodo(id todoID: String,
                           status: TodoStatus,
                           result: String?,
                           for conversation: UUID,
                           workingDirectory: URL?) -> Plan? {
        // Cold rehydrate before update (process restart / store cleared).
        if plans[conversation] == nil {
            _ = plan(for: conversation, workingDirectory: workingDirectory)
        }
        guard let updated = updateTodo(id: todoID, status: status, result: result, for: conversation)
        else { return nil }
        if let root = PathConfinement.usableWorkspaceRoot(workingDirectory) {
            durableRoots[conversation] = root
            Self.saveDurable(updated, conversation: conversation, workingDirectory: root)
        }
        return updated
    }

    @discardableResult
    public func revise(for conversation: UUID,
                       addingTexts: [String],
                       removingIDs: [String],
                       goal: String?) -> Plan? {
        guard let current = plans[conversation] else { return nil }
        let revised = current.revising(addingTexts: addingTexts, removingIDs: removingIDs, goal: goal)
        plans[conversation] = revised
        return revised
    }

    @discardableResult
    public func revise(for conversation: UUID,
                       addingTexts: [String],
                       removingIDs: [String],
                       goal: String?,
                       workingDirectory: URL?) -> Plan? {
        if plans[conversation] == nil {
            _ = plan(for: conversation, workingDirectory: workingDirectory)
        }
        guard let revised = revise(for: conversation, addingTexts: addingTexts,
                                   removingIDs: removingIDs, goal: goal)
        else { return nil }
        if let root = PathConfinement.usableWorkspaceRoot(workingDirectory) {
            durableRoots[conversation] = root
            Self.saveDurable(revised, conversation: conversation, workingDirectory: root)
        }
        return revised
    }

    public func clear(for conversation: UUID, workingDirectory: URL? = nil) {
        plans[conversation] = nil
        let root = workingDirectory ?? durableRoots[conversation]
        durableRoots[conversation] = nil
        if let root {
            Self.deleteDurable(conversation: conversation, workingDirectory: root)
        }
    }

    /// If the store has no plan for this conversation, rebuild from
    /// transcript tool_calls (create_plan / update_todo / revise_plan)
    /// and optionally durable disk. Call at AgentLoop start.
    @discardableResult
    public func hydrateIfNeeded(
        for conversation: UUID,
        messages: [ChatMessage],
        workingDirectory: URL?
    ) -> Plan? {
        if let existing = plans[conversation] { return existing }
        if let root = PathConfinement.usableWorkspaceRoot(workingDirectory),
           let disk = Self.loadDurable(conversation: conversation, workingDirectory: root) {
            plans[conversation] = disk
            durableRoots[conversation] = root
            return disk
        }
        if let fromTranscript = PlanTranscript.latestPlan(in: messages) {
            plans[conversation] = fromTranscript
            if let root = PathConfinement.usableWorkspaceRoot(workingDirectory) {
                durableRoots[conversation] = root
                Self.saveDurable(fromTranscript, conversation: conversation,
                                 workingDirectory: root)
            }
            return fromTranscript
        }
        return nil
    }

    // MARK: - Durable JSON

    public static func durableDirectory(workingDirectory: URL, conversation: UUID) -> URL {
        workingDirectory
            .appendingPathComponent(".agentos", isDirectory: true)
            .appendingPathComponent("plans", isDirectory: true)
            .appendingPathComponent(conversation.uuidString, isDirectory: true)
    }

    public static func durableFileURL(workingDirectory: URL, conversation: UUID) -> URL {
        durableDirectory(workingDirectory: workingDirectory, conversation: conversation)
            .appendingPathComponent("plan.json")
    }

    private static func saveDurable(_ plan: Plan, conversation: UUID, workingDirectory: URL) {
        guard PathConfinement.usableWorkspaceRoot(workingDirectory) != nil else { return }
        let dir = durableDirectory(workingDirectory: workingDirectory, conversation: conversation)
        let file = durableFileURL(workingDirectory: workingDirectory, conversation: conversation)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            // Match NoteStore / ScheduledTaskStore / ConversationStore so rewrites are
            // byte-stable (no key-order churn on every update_todo / revise_plan).
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(plan)
            try data.write(to: file, options: .atomic)
        } catch {
            // Best-effort durability — in-memory plan remains authoritative for the turn.
            // Wave C2: do not swallow silently (E3).
            Diagnostics.warn(
                "PlanStore durable save failed",
                detail: "\(file.path): \(error.localizedDescription)")
        }
    }

    private static func loadDurable(conversation: UUID, workingDirectory: URL) -> Plan? {
        let file = durableFileURL(workingDirectory: workingDirectory, conversation: conversation)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Plan.self, from: data)
    }

    private static func deleteDurable(conversation: UUID, workingDirectory: URL) {
        let dir = durableDirectory(workingDirectory: workingDirectory, conversation: conversation)
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - Transcript reconstruction

/// Pure rebuild of the latest structured plan from assistant tool_calls
/// in conversation history (AgentCore; no App dependency).
public enum PlanTranscript: Sendable {

    public static func latestPlan(in messages: [ChatMessage]) -> Plan? {
        var plan: Plan?
        for msg in messages where msg.role == .assistant {
            for call in msg.toolCalls {
                switch call.name {
                case "create_plan":
                    if let p = parseCreate(arguments: call.arguments) {
                        plan = p
                    }
                case "revise_plan":
                    if let existing = plan {
                        plan = applyRevise(arguments: call.arguments, to: existing)
                    } else {
                        // revise without prior create_plan — build an empty stub
                        // plan from the revise args, then apply the revision.
                        if let stub = PlanTranscript.mkStubFromRevise(arguments: call.arguments) {
                            plan = applyRevise(arguments: call.arguments, to: stub)
                        }
                    }
                case "update_todo":
                    if let existing = plan {
                        plan = applyTodoUpdate(arguments: call.arguments, to: existing)
                    }
                default:
                    break
                }
            }
        }
        return plan
    }

    private static func parseJSON(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    private static func parseCreate(arguments: String) -> Plan? {
        guard let dict = parseJSON(arguments) else { return nil }
        let goal = (dict["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var texts: [String] = []
        if let arr = dict["todos"] as? [String] {
            texts = arr
        } else if let arr = dict["todos"] as? [Any] {
            texts = arr.compactMap { $0 as? String }
        }
        guard !texts.isEmpty else { return nil }
        return Plan.make(goal: goal.isEmpty ? "Task plan" : goal, todoTexts: texts)
    }

    /// Extract the goal string from revise_plan arguments to create a stub plan.
    private static func mkStubFromRevise(arguments: String) -> Plan? {
        guard let dict = parseJSON(arguments) else { return nil }
        if let goal = dict["goal"] as? String,
           !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Plan.make(goal: goal, todoTexts: [])
        }
        // Fall back to a generic goal so the plan exists for revision.
        return Plan.make(goal: "Revise plan", todoTexts: [])
    }

    private static func applyRevise(arguments: String, to existing: Plan) -> Plan {
        guard let dict = parseJSON(arguments) else { return existing }
        let add: [String]
        if let a = dict["add"] as? [String] { add = a }
        else if let a = dict["add"] as? [Any] { add = a.compactMap { $0 as? String } }
        else { add = [] }
        let remove: [String]
        if let r = dict["remove"] as? [String] { remove = r }
        else if let r = dict["remove"] as? [Any] { remove = r.compactMap { $0 as? String } }
        else { remove = [] }
        let goal = dict["goal"] as? String
        return existing.revising(addingTexts: add, removingIDs: remove, goal: goal)
    }

    private static func applyTodoUpdate(arguments: String, to existing: Plan) -> Plan {
        guard let dict = parseJSON(arguments) else { return existing }
        let id = (dict["id"] as? String)
            ?? (dict["id"] as? Int).map(String.init)
            ?? ""
        guard !id.isEmpty else { return existing }
        let statusRaw = dict["status"] as? String ?? ""
        guard let status = TodoStatus(lenient: statusRaw) else { return existing }
        let result = dict["result"] as? String
        return existing.updatingTodo(id: id, status: status, result: result) ?? existing
    }
}
