//
//  InspectorSubagentDirectory.swift
//
//  Pure merge of transcript `task` calls + BackgroundJobSnapshot rows
//  for the inspector Subagents tab.
//

import Foundation
import AgentCore

// MARK: - Status

enum InspectorSubagentStatus: String, Equatable, CaseIterable {
    case running
    case waiting
    case blocked
    case completed
    case failed
    case cancelled
    case lost

    var title: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .blocked: return "Blocked"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .lost: return "Lost"
        }
    }

    var isActive: Bool {
        switch self {
        case .running, .waiting, .blocked: return true
        case .completed, .failed, .cancelled, .lost: return false
        }
    }
}

// MARK: - Entry

struct InspectorSubagentEntry: Identifiable, Equatable {
    var id: String
    var taskId: UUID?
    var toolCallId: String?
    var type: String
    var description: String
    var prompt: String
    var output: String
    var status: InspectorSubagentStatus
    var startedAt: Date?
    var finishedAt: Date?
    var threadItems: [SubagentThreadItem] = []

    var canKill: Bool { status == .running && taskId != nil }

    func elapsedSeconds(now: Date = Date()) -> Int {
        guard let startedAt else { return 0 }
        let end = finishedAt ?? now
        return max(0, Int(end.timeIntervalSince(startedAt)))
    }

    func elapsedLabel(now: Date = Date()) -> String {
        JobMonitor.formatElapsed(elapsedSeconds(now: now))
    }
}

// MARK: - Result / args parse

struct InspectorSubagentResultMeta: Equatable {
    var taskId: String?
    var agentId: String?
    var type: String?
    var description: String?
    var status: String?
    var cancelled: Bool?
    var stalled: Bool?
    var durationMs: Int?

    var taskUUID: UUID? {
        guard let taskId else { return nil }
        return UUID(uuidString: taskId)
    }
}

struct InspectorSubagentArguments: Equatable {
    var type: String
    var description: String
    var prompt: String

    static let empty = InspectorSubagentArguments(
        type: "general-purpose",
        description: "",
        prompt: ""
    )
}

struct InspectorSubagentOpenRequest: Equatable {
    static let taskIdKey = "taskId"
    static let toolCallIdKey = "toolCallId"
    static let typeKey = "type"
    static let descriptionKey = "description"
    static let userInfoKeys = [taskIdKey, toolCallIdKey, typeKey, descriptionKey]

    var taskId: String? = nil
    var toolCallId: String? = nil
    var type: String? = nil
    var description: String? = nil

    static func parse(_ note: Notification) -> InspectorSubagentOpenRequest {
        let info = note.userInfo ?? [:]
        return InspectorSubagentOpenRequest(
            taskId: stringValue(info[taskIdKey]),
            toolCallId: stringValue(info[toolCallIdKey]),
            type: stringValue(info[typeKey]),
            description: stringValue(info[descriptionKey])
        )
    }

    func userInfo() -> [String: String] {
        var info: [String: String] = [:]
        if let taskId, !taskId.isEmpty { info[Self.taskIdKey] = taskId }
        if let toolCallId, !toolCallId.isEmpty { info[Self.toolCallIdKey] = toolCallId }
        if let type, !type.isEmpty { info[Self.typeKey] = type }
        if let description, !description.isEmpty { info[Self.descriptionKey] = description }
        return info
    }

    func matchingID(in directory: InspectorSubagentDirectory) -> String? {
        let all = directory.running + directory.ended
        if let taskId, !taskId.isEmpty {
            let needle = taskId.lowercased()
            if let hit = all.first(where: {
                $0.taskId?.uuidString.lowercased() == needle || $0.id.lowercased() == needle
            }) {
                return hit.id
            }
        }
        if let toolCallId, !toolCallId.isEmpty {
            if let hit = all.first(where: { $0.toolCallId == toolCallId }) {
                return hit.id
            }
        }
        if let description, !description.isEmpty {
            if let hit = all.first(where: {
                $0.description == description && (type == nil || type == $0.type)
            }) {
                return hit.id
            }
        }
        return nil
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let value = raw as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let uuid = raw as? UUID { return uuid.uuidString }
        return nil
    }
}

@MainActor
enum InspectorSubagentOpenStore {
    static var pending: InspectorSubagentOpenRequest?

    static func take() -> InspectorSubagentOpenRequest? {
        defer { pending = nil }
        return pending
    }
}

// MARK: - Directory

struct InspectorSubagentDirectory: Equatable {
    var running: [InspectorSubagentEntry]
    var ended: [InspectorSubagentEntry]

    var isEmpty: Bool { running.isEmpty && ended.isEmpty }

    static let runningTitle = "Running"
    static let endedTitle = "Ended"
    static let runningEmptyMessage = "No running subagents"
    static let allEmptyMessage = "No subagents in this task"
    static let loadFailedMessage = "Unable to load subagents."
    static let showMoreTitle = "Show 20 more"
    static let promptTitle = "Prompt"
    static let outputTitle = "SubAgent output"
    static let outputEmptyMessage = "No output yet"
    static let endedPageSize = 20
    static let outputVisibleRows = 40

    static func build(
        conversation: Conversation?,
        jobs: [BackgroundJobSnapshot],
        liveTaskStates: [ToolCallUIState] = []
    ) -> InspectorSubagentDirectory {
        var order: [String] = []
        var map: [String: InspectorSubagentEntry] = [:]

        if let conversation {
            ingestTranscript(conversation.messages, order: &order, map: &map)
        }

        ingestLiveTaskStates(liveTaskStates, order: &order, map: &map)

        for job in jobs where job.kind == .subagent {
            overlay(job: job, order: &order, map: &map)
        }

        let entries = order.compactMap { map[$0] }
        return InspectorSubagentDirectory(
            running: entries.filter(\.status.isActive),
            ended: entries.filter { !$0.status.isActive }
        )
    }

    static func pagedEnded(_ ended: [InspectorSubagentEntry], limit: Int) -> [InspectorSubagentEntry] {
        Array(ended.prefix(max(0, limit)))
    }

    static func status(from job: BackgroundJobStatus) -> InspectorSubagentStatus {
        switch job {
        case .running: return .running
        case .completed: return .completed
        case .failed: return .failed
        case .killed: return .cancelled
        case .timedOut: return .lost
        }
    }

    static func status(named raw: String) -> InspectorSubagentStatus? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running": return .running
        case "waiting": return .waiting
        case "blocked", "stalled": return .blocked
        case "completed", "success", "done": return .completed
        case "failed", "error", "failure": return .failed
        case "cancelled", "canceled", "killed": return .cancelled
        case "lost", "timedout", "timed_out", "timeout": return .lost
        default: return nil
        }
    }

    static func parseArguments(_ json: String) -> InspectorSubagentArguments {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        let type = (obj["subagent_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = (obj["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = (obj["prompt"] as? String) ?? ""
        return InspectorSubagentArguments(
            type: (type?.isEmpty == false) ? type! : "general-purpose",
            description: desc,
            prompt: prompt
        )
    }

    static func parseResult(_ content: String) -> InspectorSubagentResultMeta {
        var meta = InspectorSubagentResultMeta()
        let block: String
        if let start = content.range(of: "<subagent_meta>"),
           let end = content.range(of: "</subagent_meta>", range: start.upperBound..<content.endIndex) {
            block = String(content[start.upperBound..<end.lowerBound])
        } else {
            block = content
        }
        for rawLine in block.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch key {
            case "task_id":
                meta.taskId = value
            case "agent_id":
                meta.agentId = value
            case "id":
                if meta.agentId == nil { meta.agentId = value }
            case "type":
                meta.type = value
            case "description":
                meta.description = value
            case "status":
                meta.status = value
            case "cancelled":
                meta.cancelled = parseBool(value)
            case "stalled":
                meta.stalled = parseBool(value)
            case "duration_ms":
                meta.durationMs = Int(value)
            default:
                break
            }
        }
        return meta
    }

    static func displayOutput(resultContent: String, jobOutput: String? = nil) -> String {
        if let jobOutput {
            let trimmed = jobOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let start = resultContent.range(of: "<subagent_meta>") {
            return String(resultContent[..<start.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return resultContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func outputLines(_ output: String, maxVisible: Int = outputVisibleRows) -> (visible: [String], total: Int) {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let total = lines.count
        if output.isEmpty { return ([], 0) }
        if total <= maxVisible { return (lines, total) }
        return (Array(lines.suffix(maxVisible)), total)
    }

    static func outputFooter(visible: Int, total: Int) -> String? {
        guard total > visible, visible > 0 else { return nil }
        return "Latest \(visible) rows / \(total) total"
    }

    static func splitJobCommand(_ command: String) -> (type: String, description: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = trimmed.firstIndex(of: ":") {
            let type = String(trimmed[..<idx]).trimmingCharacters(in: .whitespaces)
            let desc = String(trimmed[trimmed.index(after: idx)...])
                .trimmingCharacters(in: .whitespaces)
            if !type.isEmpty {
                return (type, desc)
            }
        }
        return ("general-purpose", trimmed)
    }

    private static func ingestLiveTaskStates(
        _ states: [ToolCallUIState],
        order: inout [String],
        map: inout [String: InspectorSubagentEntry]
    ) {
        for state in states where state.toolName == "task" {
            let args = parseArguments(state.input)
            let meta = parseResult(state.output)
            let taskUUID = meta.taskUUID ?? UUID(uuidString: state.id)
            let key = taskUUID.map { uuidKey($0) } ?? callKey(state.id)
            let status: InspectorSubagentStatus
            switch state.status {
            case .pending: status = .waiting
            case .running: status = .running
            case .success: status = .completed
            case .failure: status = .failed
            }
            if let existing = map[key], !existing.status.isActive, status.isActive == false {
                continue
            }
            upsert(
                key: key,
                order: &order,
                map: &map,
                InspectorSubagentEntry(
                    id: key,
                    taskId: taskUUID ?? existingTaskId(map[key]),
                    toolCallId: state.id,
                    type: nonempty(meta.type) ?? args.type,
                    description: nonempty(meta.description) ?? args.description,
                    prompt: args.prompt,
                    output: displayOutput(resultContent: state.output),
                    status: status,
                    startedAt: map[key]?.startedAt,
                    finishedAt: status.isActive ? nil : Date()
                )
            )
        }
    }

    private static func existingTaskId(_ entry: InspectorSubagentEntry?) -> UUID? {
        entry?.taskId
    }

    // MARK: Transcript walk

    private static func ingestTranscript(
        _ messages: [ChatMessage],
        order: inout [String],
        map: inout [String: InspectorSubagentEntry]
    ) {
        var pending: [String: ToolCallInvocation] = [:]
        var pendingStarted: [String: Date] = [:]

        for msg in messages {
            if msg.role == .assistant {
                for inv in msg.toolCalls where inv.name == "task" {
                    pending[inv.id] = inv
                    pendingStarted[inv.id] = msg.timestamp
                    let args = parseArguments(inv.arguments)
                    let key = callKey(inv.id)
                    upsert(
                        key: key,
                        order: &order,
                        map: &map,
                        InspectorSubagentEntry(
                            id: key,
                            taskId: nil,
                            toolCallId: inv.id,
                            type: args.type,
                            description: args.description,
                            prompt: args.prompt,
                            output: "",
                            status: .running,
                            startedAt: msg.timestamp,
                            finishedAt: nil
                        )
                    )
                }
            } else if msg.role == .tool, let callID = msg.toolCallID {
                let known = pending.removeValue(forKey: callID) != nil
                    || map.values.contains { $0.toolCallId == callID }
                guard known else { continue }
                applyResult(
                    toolCallId: callID,
                    content: msg.content,
                    timestamp: msg.timestamp,
                    startedAt: pendingStarted[callID],
                    order: &order,
                    map: &map
                )
            }
        }
    }

    private static func applyResult(
        toolCallId: String,
        content: String,
        timestamp: Date,
        startedAt: Date?,
        order: inout [String],
        map: inout [String: InspectorSubagentEntry]
    ) {
        let oldKey = callKey(toolCallId)
        let existing = map[oldKey] ?? map.values.first { $0.toolCallId == toolCallId }
        let args = existing.map {
            InspectorSubagentArguments(type: $0.type, description: $0.description, prompt: $0.prompt)
        } ?? .empty
        let meta = parseResult(content)
        let taskUUID = meta.taskUUID
        let newKey = taskUUID.map { uuidKey($0) } ?? oldKey
        let status = statusFromResult(meta: meta, content: content)
        var finished: Date? = status.isActive ? nil : timestamp
        if !status.isActive, let duration = meta.durationMs,
           let start = startedAt ?? existing?.startedAt {
            finished = start.addingTimeInterval(Double(duration) / 1000.0)
        }

        let entry = InspectorSubagentEntry(
            id: newKey,
            taskId: taskUUID ?? existing?.taskId,
            toolCallId: toolCallId,
            type: nonempty(meta.type) ?? existing?.type ?? args.type,
            description: nonempty(meta.description) ?? existing?.description ?? args.description,
            prompt: existing?.prompt ?? args.prompt,
            output: displayOutput(resultContent: content),
            status: status,
            startedAt: startedAt ?? existing?.startedAt ?? timestamp,
            finishedAt: finished
        )

        if oldKey != newKey {
            map.removeValue(forKey: oldKey)
            if let idx = order.firstIndex(of: oldKey) {
                order[idx] = newKey
            } else if !order.contains(newKey) {
                order.append(newKey)
            }
        }
        upsert(key: newKey, order: &order, map: &map, entry)
    }

    private static func overlay(
        job: BackgroundJobSnapshot,
        order: inout [String],
        map: inout [String: InspectorSubagentEntry]
    ) {
        let jobKey = uuidKey(job.id)
        if var existing = map[jobKey] {
            existing = merge(entry: existing, job: job)
            map[jobKey] = existing
            return
        }
        if let found = map.first(where: { $0.value.taskId == job.id }) {
            rekey(from: found.key, to: jobKey, order: &order, map: &map)
            if var existing = map[jobKey] {
                existing = merge(entry: existing, job: job)
                map[jobKey] = existing
            }
            return
        }

        let parsed = splitJobCommand(job.command)
        if let found = map.first(where: { _, entry in
            entry.taskId == nil && commandMatches(job.command, entry: entry, parsed: parsed)
        }) {
            rekey(from: found.key, to: jobKey, order: &order, map: &map)
            if var existing = map[jobKey] {
                existing = merge(entry: existing, job: job)
                map[jobKey] = existing
            }
            return
        }

        upsert(
            key: jobKey,
            order: &order,
            map: &map,
            InspectorSubagentEntry(
                id: jobKey,
                taskId: job.id,
                toolCallId: nil,
                type: parsed.type,
                description: parsed.description,
                prompt: "",
                output: job.output.trimmingCharacters(in: .whitespacesAndNewlines),
                status: status(from: job.status),
                startedAt: job.startedAt,
                finishedAt: job.finishedAt,
                threadItems: SubagentThreadBuilder.items(from: job.transcript)
            )
        )
    }

    private static func merge(entry: InspectorSubagentEntry, job: BackgroundJobSnapshot) -> InspectorSubagentEntry {
        var next = entry
        next.id = uuidKey(job.id)
        next.taskId = job.id
        next.status = status(from: job.status)
        let liveOut = job.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !liveOut.isEmpty { next.output = liveOut }
        next.startedAt = job.startedAt
        next.finishedAt = job.finishedAt
        let fromJob = SubagentThreadBuilder.items(from: job.transcript)
        if !fromJob.isEmpty { next.threadItems = fromJob }
        let parsed = splitJobCommand(job.command)
        if next.description.isEmpty { next.description = parsed.description }
        if next.type.isEmpty { next.type = parsed.type }
        return next
    }

    private static func statusFromResult(
        meta: InspectorSubagentResultMeta,
        content: String
    ) -> InspectorSubagentStatus {
        if meta.cancelled == true { return .cancelled }
        if meta.stalled == true { return .blocked }
        if let named = meta.status.flatMap(status(named:)) { return named }
        let lower = content.lowercased()
        if lower.contains("status: failed") || lower.contains("status: error") {
            return .failed
        }
        return .completed
    }

    private static func commandMatches(
        _ command: String,
        entry: InspectorSubagentEntry,
        parsed: (type: String, description: String)
    ) -> Bool {
        if !entry.description.isEmpty,
           command == "\(entry.type): \(entry.description)" || command == entry.description {
            return true
        }
        if !parsed.description.isEmpty, parsed.description == entry.description,
           parsed.type == entry.type || command.contains(entry.type) {
            return true
        }
        return false
    }

    private static func upsert(
        key: String,
        order: inout [String],
        map: inout [String: InspectorSubagentEntry],
        _ entry: InspectorSubagentEntry
    ) {
        if map[key] == nil, !order.contains(key) {
            order.append(key)
        }
        map[key] = entry
    }

    private static func rekey(
        from oldKey: String,
        to newKey: String,
        order: inout [String],
        map: inout [String: InspectorSubagentEntry]
    ) {
        guard oldKey != newKey, let existing = map.removeValue(forKey: oldKey) else { return }
        if let idx = order.firstIndex(of: oldKey) {
            order[idx] = newKey
        } else if !order.contains(newKey) {
            order.append(newKey)
        }
        var moved = existing
        moved.id = newKey
        map[newKey] = moved
    }

    private static func callKey(_ toolCallId: String) -> String { "call:\(toolCallId)" }
    private static func uuidKey(_ id: UUID) -> String { id.uuidString.lowercased() }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
}
