//
//  ToolCallGrouping.swift
//
//  ZCode-parity (docs/ui-parity-research/zcode-chat.md §3): classify tools
//  into renderer families and collapse consecutive read-only calls into one
//  Explore card (N searches, N lists, N files) and consecutive file
//  write/edit/delete into one file-change family (Writing/Wrote,
//  Updating/Updated). Shell cards use Running/Ran plus Failed/Denied/Stopped
//  and skip empty in-flight commands. Long-running shells carry startedAt so
//  the composer chip can show "Running for Ns" without App chrome here.
//  Skill cards use Running skill / Ran skill + Args; Agent/Task cards use
//  SubAgent + prompt (Launching/Launched). Maps VibeCoder load_skill / task
//  / get_task_output / wait_tasks / kill_task (not send_message).
//  Todo cards use Updating todo / Updated todo (`update_todo`, TodoWrite,
//  TodoRead). MCP cards (`server__tool`) expose View call details,
//  Parameters, Result, Copy result, wrap lines. Plan-guidance /
//  switch-mode / ask-user-question map enter_plan_mode, exit_plan_mode,
//  ask_user (and ZCode EnterPlanMode / ExitPlanMode / AskUserQuestion).
//  Pure functions so App/Sable can render later — this file does not
//  touch AgentLoop.swift.
//

import Foundation

/// Renderer families from ZCode `Qme` / `og`: file-read, file-write, shell,
/// search, explore, todo, skill, agent, plan-guidance, switch-mode,
/// ask-user-question, plus mcp (`server__tool`). Unknown names map to `other`.
public enum ToolFamily: String, Sendable, Equatable {
    case fileRead = "file-read"
    case fileWrite = "file-write"
    case shell
    case search
    case explore
    case todo
    case skill
    case agent
    case mcp
    case planGuidance = "plan-guidance"
    case switchMode = "switch-mode"
    case askUserQuestion = "ask-user-question"
    case other
}

/// Kind of file-write family member (create vs patch vs delete).
public enum FileWriteKind: String, Sendable, Equatable {
    case write
    case update
    case delete
}

/// One tool event as the transcript would present it (name + in-flight bits).
public struct ToolCallEvent: Sendable, Equatable {
    public var name: String
    public var isRunning: Bool
    /// Parsed shell command when family is shell. Empty + running → skip.
    public var parsedCommand: String?
    /// Terminal shell outcome when not running (success / failed / denied / stopped).
    public var shellStatus: ShellToolStatus
    /// Path when the tool mutates a file (optional; grouping still works without it).
    public var path: String?
    /// Line adds from patch/tool result when already known.
    public var added: Int
    /// Line deletes from patch/tool result when already known.
    public var deleted: Int
    /// Wall-clock start for long-running shells (composer chip "Running for Ns").
    public var startedAt: Date?
    /// Skill name for `load_skill` cards (ZCode `chat.toolCall.skill.*`).
    public var skillName: String?
    /// Skill args string shown next to Running skill / Ran skill.
    public var skillArgs: String?
    /// Subagent prompt for Agent/Task cards.
    public var agentPrompt: String?
    /// `subagent_type` / catalog id (explore, plan, general-purpose).
    public var agentType: String?
    /// Todo item / list summary for todo cards.
    public var todoSummary: String?
    /// JSON/text parameters shown on MCP "View call details".
    public var mcpParameters: String?
    /// MCP tool result body (Copy result).
    public var mcpResult: String?
    /// ZCode wrap-lines toggle for MCP result pane.
    public var wrapResultLines: Bool
    /// Plan body for switch-mode / plan-guidance cards.
    public var planText: String?
    /// Question shown on ask-user-question cards.
    public var question: String?

    public init(
        name: String,
        isRunning: Bool = false,
        parsedCommand: String? = nil,
        shellStatus: ShellToolStatus = .success,
        path: String? = nil,
        added: Int = 0,
        deleted: Int = 0,
        startedAt: Date? = nil,
        skillName: String? = nil,
        skillArgs: String? = nil,
        agentPrompt: String? = nil,
        agentType: String? = nil,
        todoSummary: String? = nil,
        mcpParameters: String? = nil,
        mcpResult: String? = nil,
        wrapResultLines: Bool = true,
        planText: String? = nil,
        question: String? = nil
    ) {
        self.name = name
        self.isRunning = isRunning
        self.parsedCommand = parsedCommand
        self.shellStatus = shellStatus
        self.path = path
        self.added = added
        self.deleted = deleted
        self.startedAt = startedAt
        self.skillName = skillName
        self.skillArgs = skillArgs
        self.agentPrompt = agentPrompt
        self.agentType = agentType
        self.todoSummary = todoSummary
        self.mcpParameters = mcpParameters
        self.mcpResult = mcpResult
        self.wrapResultLines = wrapResultLines
        self.planText = planText
        self.question = question
    }
}

/// Explore card buckets (ZCode `chat.toolCall.explore.*`).
public struct ExploreBucketCounts: Sendable, Equatable {
    public var searches: Int
    public var lists: Int
    public var files: Int

    public init(searches: Int = 0, lists: Int = 0, files: Int = 0) {
        self.searches = searches
        self.lists = lists
        self.files = files
    }

    public var total: Int { searches + lists + files }
}

/// Consecutive write/edit/delete card. `fileCount` / `added` / `deleted`
/// are for Sable to bind a ZCode-style "N files changed +a −d" row.
public struct FileChangeGroupCounts: Sendable, Equatable {
    public var writes: Int
    public var updates: Int
    public var deletes: Int
    public var fileCount: Int
    public var added: Int
    public var deleted: Int

    public init(
        writes: Int = 0,
        updates: Int = 0,
        deletes: Int = 0,
        fileCount: Int = 0,
        added: Int = 0,
        deleted: Int = 0
    ) {
        self.writes = writes
        self.updates = updates
        self.deletes = deletes
        self.fileCount = fileCount
        self.added = added
        self.deleted = deleted
    }

    public var total: Int { writes + updates + deletes }
}

/// Turn-end rollup Sable can bind without parsing AgentLoop.
public struct FileChangeTurnTotals: Sendable, Equatable {
    public var fileCount: Int
    public var added: Int
    public var deleted: Int

    public init(fileCount: Int, added: Int, deleted: Int) {
        self.fileCount = fileCount
        self.added = added
        self.deleted = deleted
    }

    public static func from(_ summary: TurnChangeSummary) -> FileChangeTurnTotals {
        FileChangeTurnTotals(
            fileCount: summary.fileCount,
            added: summary.totalAdded,
            deleted: summary.totalRemoved
        )
    }
}

/// Shell card outcome (ZCode `chat.toolCall.execute.*` / status pills).
/// Kind is Running vs Ran; Failed/Denied/Stopped are status overlays.
public enum ShellToolStatus: String, Sendable, Equatable {
    case running
    case success
    case failed
    case denied
    case stopped
}

/// One shell tool as a chat card (title = command).
public struct ShellCard: Sendable, Equatable {
    public var index: Int
    public var status: ShellToolStatus
    public var command: String
    /// When the shell started; UI computes elapsed vs now.
    public var startedAt: Date?

    public init(
        index: Int,
        status: ShellToolStatus,
        command: String,
        startedAt: Date? = nil
    ) {
        self.index = index
        self.status = status
        self.command = command
        self.startedAt = startedAt
    }

    public var kindLabel: String { ToolCallGrouping.shellKindLabel(status) }
    public var statusLabel: String? { ToolCallGrouping.shellStatusLabel(status) }

    /// Whole seconds since start (0 if start is missing or in the future).
    public func elapsedSeconds(now: Date = Date()) -> Int {
        guard let startedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(startedAt)))
    }

    /// Composer chip copy when this shell is still running.
    public func longRunningChipLabel(now: Date = Date()) -> String? {
        guard status == .running else { return nil }
        return ToolCallGrouping.longRunningChipLabel(elapsedSeconds: elapsedSeconds(now: now))
    }
}

/// Skill card (ZCode `chat.toolCall.skill.*`): Running skill / Ran skill + Args.
public struct SkillCard: Sendable, Equatable {
    public var index: Int
    public var isRunning: Bool
    public var skillName: String
    public var args: String

    public init(index: Int, isRunning: Bool, skillName: String, args: String = "") {
        self.index = index
        self.isRunning = isRunning
        self.skillName = skillName
        self.args = args
    }

    public var kindLabel: String { ToolCallGrouping.skillKindLabel(isRunning: isRunning) }
}

/// Agent/Task card (ZCode `chat.toolCall.agent.*`): title SubAgent + prompt.
public struct AgentCard: Sendable, Equatable {
    public var index: Int
    public var isRunning: Bool
    public var prompt: String
    public var agentType: String
    /// Tool name that produced the card (`task`, `get_task_output`, …).
    public var toolName: String

    public init(
        index: Int,
        isRunning: Bool,
        prompt: String = "",
        agentType: String = "",
        toolName: String = "task"
    ) {
        self.index = index
        self.isRunning = isRunning
        self.prompt = prompt
        self.agentType = agentType
        self.toolName = toolName
    }

    public var title: String { "SubAgent" }
    public var kindLabel: String { ToolCallGrouping.agentKindLabel(isRunning: isRunning) }
}

/// Todo card (ZCode `chat.toolCall.todo.*`): Updating todo / Updated todo.
public struct TodoCard: Sendable, Equatable {
    public var index: Int
    public var isRunning: Bool
    public var summary: String
    /// Tool name (`update_todo`, `TodoWrite`, `TodoRead`).
    public var toolName: String

    public init(
        index: Int,
        isRunning: Bool,
        summary: String = "",
        toolName: String = "update_todo"
    ) {
        self.index = index
        self.isRunning = isRunning
        self.summary = summary
        self.toolName = toolName
    }

    public var kindLabel: String { ToolCallGrouping.todoKindLabel(isRunning: isRunning) }
}

/// MCP card (ZCode `chat.toolCall.mcp.*`): View call details, Parameters,
/// Result, Copy result, wrap lines. Title is the namespaced `server__tool`.
public struct MCPCard: Sendable, Equatable {
    public var index: Int
    public var isRunning: Bool
    public var toolName: String
    public var serverName: String
    public var parameters: String
    public var result: String
    public var wrapLines: Bool

    public init(
        index: Int,
        isRunning: Bool,
        toolName: String,
        serverName: String = "",
        parameters: String = "",
        result: String = "",
        wrapLines: Bool = true
    ) {
        self.index = index
        self.isRunning = isRunning
        self.toolName = toolName
        self.serverName = serverName
        self.parameters = parameters
        self.result = result
        self.wrapLines = wrapLines
    }

    public var viewCallDetailsLabel: String { ToolCallGrouping.mcpViewCallDetailsLabel }
    public var parametersLabel: String { ToolCallGrouping.mcpParametersLabel }
    public var resultLabel: String { ToolCallGrouping.mcpResultLabel }
    public var copyResultLabel: String { ToolCallGrouping.mcpCopyResultLabel }
}

/// Plan-guidance card (ZCode EnterPlanMode / `plan-guidance`).
public struct PlanGuidanceCard: Sendable, Equatable {
    public var index: Int
    public var isRunning: Bool
    public var toolName: String
    public var planText: String

    public init(
        index: Int,
        isRunning: Bool,
        toolName: String = "enter_plan_mode",
        planText: String = ""
    ) {
        self.index = index
        self.isRunning = isRunning
        self.toolName = toolName
        self.planText = planText
    }

    public var kindLabel: String { ToolCallGrouping.planGuidanceKindLabel(isRunning: isRunning) }
}

/// Switch-mode / plan-approval card (ZCode ExitPlanMode).
public struct SwitchModeCard: Sendable, Equatable {
    public var index: Int
    public var isRunning: Bool
    public var toolName: String
    public var planText: String

    public init(
        index: Int,
        isRunning: Bool,
        toolName: String = "exit_plan_mode",
        planText: String = ""
    ) {
        self.index = index
        self.isRunning = isRunning
        self.toolName = toolName
        self.planText = planText
    }

    public var kindLabel: String { ToolCallGrouping.switchModeKindLabel(isRunning: isRunning) }
    public var approveLabel: String { ToolCallGrouping.switchModeApproveLabel }
    public var approveDescription: String { ToolCallGrouping.switchModeApproveDescription }
    public var placeholderTitle: String { ToolCallGrouping.switchModePlaceholderTitle }
}

/// Ask-user-question card (ZCode AskUserQuestion / `ask_user`).
public struct AskUserQuestionCard: Sendable, Equatable {
    public var index: Int
    public var isRunning: Bool
    public var toolName: String
    public var question: String

    public init(
        index: Int,
        isRunning: Bool,
        toolName: String = "ask_user",
        question: String = ""
    ) {
        self.index = index
        self.isRunning = isRunning
        self.toolName = toolName
        self.question = question
    }

    public var kindLabel: String { ToolCallGrouping.askUserQuestionKindLabel(isRunning: isRunning) }
    public var continueLabel: String { ToolCallGrouping.askUserContinueLabel }
    public var submitLabel: String { ToolCallGrouping.askUserSubmitLabel }
    public var customAnswerLabel: String { ToolCallGrouping.askUserCustomAnswerLabel }
}

public enum GroupedToolCalls: Sendable, Equatable {
    /// Consecutive read-only tools → one Explore card.
    case explore(counts: ExploreBucketCounts, memberIndices: [Int])
    /// Consecutive write / edit / delete → one file-change family card.
    case fileChange(counts: FileChangeGroupCounts, memberIndices: [Int])
    /// Shell with parsed command (empty in-flight shells are omitted).
    case shell(ShellCard)
    /// Skill load card.
    case skill(SkillCard)
    /// Subagent / task / task-output / task-stop card.
    case agent(AgentCard)
    /// Todo write/read card.
    case todo(TodoCard)
    /// Namespaced MCP `server__tool` card.
    case mcp(MCPCard)
    /// Enter plan mode card.
    case planGuidance(PlanGuidanceCard)
    /// Exit plan mode / plan-approval card.
    case switchMode(SwitchModeCard)
    /// Ask-user-question card.
    case askUserQuestion(AskUserQuestionCard)
    /// Unmapped tools, shown as their own card.
    case standalone(index: Int, family: ToolFamily)
}

public enum ToolCallGrouping: Sendable {

    public static func family(forToolName name: String) -> ToolFamily {
        switch name {
        case "read_file", "read_file_range":
            return .fileRead
        case "write_file", "edit_file", "apply_patch", "delete_file",
             "move_file", "create_directory", "text_edit", "xcode_project_editor",
             "XcodeWrite", "XcodeUpdate", "search_replace":
            return .fileWrite
        case "run_shell":
            return .shell
        case "grep_code", "grep", "glob_files", "glob",
             "web_search", "tool_search", "find_symbol", "memory_search", "apple_docs":
            return .search
        case "list_directory", "list_dir":
            return .explore
        case "update_todo", "TodoWrite", "TodoRead":
            return .todo
        case "load_skill", "Skill":
            return .skill
        case "task", "Agent", "Task",
             "get_task_output", "wait_tasks", "kill_task",
             "TaskOutput", "TaskStop":
            return .agent
        case "enter_plan_mode", "EnterPlanMode":
            return .planGuidance
        case "exit_plan_mode", "ExitPlanMode":
            return .switchMode
        case "ask_user", "AskUserQuestion":
            return .askUserQuestion
        default:
            if ToolAuthorization.isMCPToolName(name) {
                return .mcp
            }
            return .other
        }
    }

    /// Create vs patch vs delete inside the file-write family.
    public static func fileWriteKind(forToolName name: String) -> FileWriteKind {
        switch name {
        case "write_file", "create_directory", "XcodeWrite":
            return .write
        case "delete_file":
            return .delete
        default:
            return .update
        }
    }

    /// Read-only families that collapse into Explore (search / list / file).
    public static func isExploreMember(_ family: ToolFamily) -> Bool {
        switch family {
        case .fileRead, .search, .explore:
            return true
        default:
            return false
        }
    }

    public static func isFileWriteMember(_ family: ToolFamily) -> Bool {
        family == .fileWrite
    }

    /// ZCode: skip shells with empty parsed command while streaming/running.
    public static func shouldSkipInGrouping(_ event: ToolCallEvent) -> Bool {
        guard family(forToolName: event.name) == .shell else { return false }
        let running = event.isRunning || event.shellStatus == .running
        guard running else { return false }
        return parsedShellCommand(event).isEmpty
    }

    public static func parsedShellCommand(_ event: ToolCallEvent) -> String {
        (event.parsedCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func resolveShellStatus(_ event: ToolCallEvent) -> ShellToolStatus {
        if event.isRunning { return .running }
        return event.shellStatus
    }

    /// Card kind: Running while in flight, Ran once finished (incl. fail/deny/stop).
    public static func shellKindLabel(_ status: ShellToolStatus) -> String {
        status == .running ? "Running" : "Ran"
    }

    /// Overlay status. Nil for Running / Ran success.
    public static func shellStatusLabel(_ status: ShellToolStatus) -> String? {
        switch status {
        case .running, .success: return nil
        case .failed: return "Failed"
        case .denied: return "Denied"
        case .stopped: return "Stopped"
        }
    }

    /// ZCode composer chip `chat.longRunning.*`: "Running for Ns" / "Running for Nm Ns".
    public static func longRunningChipLabel(elapsedSeconds: Int) -> String {
        let total = max(0, elapsedSeconds)
        if total < 60 {
            return "Running for \(total)s"
        }
        let minutes = total / 60
        let seconds = total % 60
        return "Running for \(minutes)m \(seconds)s"
    }

    /// Running shells that already have a parsed command (hidden empty in-flight skipped).
    public static func longRunningShells(_ events: [ToolCallEvent]) -> [ShellCard] {
        group(events).compactMap { group in
            guard case .shell(let card) = group, card.status == .running else { return nil }
            return card
        }
    }

    /// Activity verb for a single file-write tool. Sable binds chrome.
    public static func fileWriteActivityLabel(name: String, isRunning: Bool) -> String {
        switch fileWriteKind(forToolName: name) {
        case .write:
            return isRunning ? "Writing" : "Wrote"
        case .update:
            return isRunning ? "Updating" : "Updated"
        case .delete:
            return isRunning ? "Deleting" : "Deleted"
        }
    }

    /// Activity verb for a consecutive file-change group.
    public static func fileChangeGroupLabel(
        events: [ToolCallEvent],
        memberIndices: [Int]
    ) -> String {
        let members = memberIndices.compactMap { events.indices.contains($0) ? events[$0] : nil }
        let running = members.contains(where: { $0.isRunning })
        let kinds = Set(members.map { fileWriteKind(forToolName: $0.name) })
        if kinds.count == 1, let only = kinds.first {
            switch only {
            case .write: return running ? "Writing" : "Wrote"
            case .update: return running ? "Updating" : "Updated"
            case .delete: return running ? "Deleting" : "Deleted"
            }
        }
        return running ? "Updating" : "Updated"
    }

    /// ZCode skill card kind: Running skill while in flight, Ran skill once done.
    public static func skillKindLabel(isRunning: Bool) -> String {
        isRunning ? "Running skill" : "Ran skill"
    }

    /// ZCode agent background kind: Launching while in flight, Launched once up.
    public static func agentKindLabel(isRunning: Bool) -> String {
        isRunning ? "Launching" : "Launched"
    }

    /// ZCode todo card kind: Updating todo while in flight, Updated todo once done.
    public static func todoKindLabel(isRunning: Bool) -> String {
        isRunning ? "Updating todo" : "Updated todo"
    }

    public static let mcpViewCallDetailsLabel = "View call details"
    public static let mcpParametersLabel = "Parameters"
    public static let mcpResultLabel = "Result"
    public static let mcpCopyResultLabel = "Copy result"

    /// ZCode plan-guidance kind.
    public static func planGuidanceKindLabel(isRunning: Bool) -> String {
        isRunning ? "Entering plan mode" : "Entered plan mode"
    }

    /// ZCode switch-mode kind while waiting for Approve.
    public static func switchModeKindLabel(isRunning: Bool) -> String {
        isRunning ? "Awaiting approval" : "Switched mode"
    }

    public static let switchModeApproveLabel = "Approve"
    public static let switchModeApproveDescription = "Exit plan mode and start implementation."
    public static let switchModePlaceholderTitle = "Implementation plan"

    /// ZCode ask-user-question kind.
    public static func askUserQuestionKindLabel(isRunning: Bool) -> String {
        isRunning ? "Asking" : "Asked"
    }

    public static let askUserContinueLabel = "Continue"
    public static let askUserSubmitLabel = "Submit"
    public static let askUserCustomAnswerLabel = "Custom answer"

    /// Server prefix of `server__tool`. Empty when the name is not MCP.
    public static func mcpServerName(forToolName name: String) -> String {
        guard ToolAuthorization.isMCPToolName(name),
              let sep = name.range(of: MCPToolNaming.delimiter) else { return "" }
        return String(name[..<sep.lowerBound])
    }

    /// Tool suffix of `server__tool` (may itself contain `__`).
    public static func mcpUnqualifiedName(forToolName name: String) -> String {
        guard ToolAuthorization.isMCPToolName(name),
              let sep = name.range(of: MCPToolNaming.delimiter) else { return name }
        return String(name[sep.upperBound...])
    }

    /// Pure grouping over a list of tool call events.
    public static func group(_ events: [ToolCallEvent]) -> [GroupedToolCalls] {
        var out: [GroupedToolCalls] = []
        var i = 0
        while i < events.count {
            if shouldSkipInGrouping(events[i]) {
                i += 1
                continue
            }
            let fam = family(forToolName: events[i].name)
            if isExploreMember(fam) {
                var indices: [Int] = []
                var searches = 0
                var lists = 0
                var files = 0
                while i < events.count {
                    if shouldSkipInGrouping(events[i]) {
                        i += 1
                        continue
                    }
                    let f = family(forToolName: events[i].name)
                    guard isExploreMember(f) else { break }
                    indices.append(i)
                    switch f {
                    case .search: searches += 1
                    case .explore: lists += 1
                    case .fileRead: files += 1
                    default: break
                    }
                    i += 1
                }
                out.append(.explore(
                    counts: ExploreBucketCounts(searches: searches, lists: lists, files: files),
                    memberIndices: indices))
            } else if isFileWriteMember(fam) {
                var indices: [Int] = []
                var writes = 0
                var updates = 0
                var deletes = 0
                var added = 0
                var deleted = 0
                var pathKeys: [String] = []
                var seen = Set<String>()
                while i < events.count {
                    if shouldSkipInGrouping(events[i]) {
                        i += 1
                        continue
                    }
                    let f = family(forToolName: events[i].name)
                    guard isFileWriteMember(f) else { break }
                    let ev = events[i]
                    indices.append(i)
                    switch fileWriteKind(forToolName: ev.name) {
                    case .write: writes += 1
                    case .update: updates += 1
                    case .delete: deletes += 1
                    }
                    added += ev.added
                    deleted += ev.deleted
                    if let path = ev.path, !path.isEmpty {
                        let key = TurnChangeSummary.pathKey(path)
                        if seen.insert(key).inserted {
                            pathKeys.append(key)
                        }
                    }
                    i += 1
                }
                let fileCount = pathKeys.isEmpty ? indices.count : pathKeys.count
                out.append(.fileChange(
                    counts: FileChangeGroupCounts(
                        writes: writes,
                        updates: updates,
                        deletes: deletes,
                        fileCount: fileCount,
                        added: added,
                        deleted: deleted),
                    memberIndices: indices))
            } else if fam == .shell {
                let ev = events[i]
                let status = resolveShellStatus(ev)
                out.append(.shell(ShellCard(
                    index: i,
                    status: status,
                    command: parsedShellCommand(ev),
                    startedAt: ev.startedAt)))
                i += 1
            } else if fam == .skill {
                let ev = events[i]
                out.append(.skill(SkillCard(
                    index: i,
                    isRunning: ev.isRunning,
                    skillName: (ev.skillName ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    args: (ev.skillArgs ?? "").trimmingCharacters(in: .whitespacesAndNewlines))))
                i += 1
            } else if fam == .agent {
                let ev = events[i]
                out.append(.agent(AgentCard(
                    index: i,
                    isRunning: ev.isRunning,
                    prompt: (ev.agentPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    agentType: (ev.agentType ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    toolName: ev.name)))
                i += 1
            } else if fam == .todo {
                let ev = events[i]
                out.append(.todo(TodoCard(
                    index: i,
                    isRunning: ev.isRunning,
                    summary: (ev.todoSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    toolName: ev.name)))
                i += 1
            } else if fam == .mcp {
                let ev = events[i]
                out.append(.mcp(MCPCard(
                    index: i,
                    isRunning: ev.isRunning,
                    toolName: ev.name,
                    serverName: mcpServerName(forToolName: ev.name),
                    parameters: (ev.mcpParameters ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    result: (ev.mcpResult ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    wrapLines: ev.wrapResultLines)))
                i += 1
            } else if fam == .planGuidance {
                let ev = events[i]
                out.append(.planGuidance(PlanGuidanceCard(
                    index: i,
                    isRunning: ev.isRunning,
                    toolName: ev.name,
                    planText: (ev.planText ?? "").trimmingCharacters(in: .whitespacesAndNewlines))))
                i += 1
            } else if fam == .switchMode {
                let ev = events[i]
                out.append(.switchMode(SwitchModeCard(
                    index: i,
                    isRunning: ev.isRunning,
                    toolName: ev.name,
                    planText: (ev.planText ?? "").trimmingCharacters(in: .whitespacesAndNewlines))))
                i += 1
            } else if fam == .askUserQuestion {
                let ev = events[i]
                out.append(.askUserQuestion(AskUserQuestionCard(
                    index: i,
                    isRunning: ev.isRunning,
                    toolName: ev.name,
                    question: (ev.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines))))
                i += 1
            } else {
                out.append(.standalone(index: i, family: fam))
                i += 1
            }
        }
        return out
    }

    /// Last group is a finished Explore burst (no in-flight members).
    public static func exploreBurstFinished(_ events: [ToolCallEvent]) -> Bool {
        let groups = group(events)
        guard let last = groups.last else { return false }
        guard case .explore(let counts, let members) = last else { return false }
        guard counts.total > 0 else { return false }
        return !members.contains(where: { events[$0].isRunning })
    }

    /// Stop-when-done: terminal PR merge banner, or explore burst ended
    /// so the model should speak instead of more identical probes.
    public static func shouldStopToolBurst(
        lastResultContent: String?,
        toolEvents: [ToolCallEvent]
    ) -> Bool {
        if GitHubPRStatusPolicy.shouldStopAfterMerged(lastResultContent) {
            return true
        }
        return exploreBurstFinished(toolEvents)
    }
}
