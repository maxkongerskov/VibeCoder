//
//  CodeSessionBuilder.swift
//
//  Derives a coding-focused timeline from a conversation transcript +
//  live tool-call UI state. Powers the Code sidebar pane (plans, todos,
//  file edits with +/- diff lines — OpenCode-style).
//

import Foundation
import AgentCore

enum CodeDiffLine: Equatable {
    case added(String)
    case removed(String)
    case context(String)

    var text: String {
        switch self {
        case .added(let s), .removed(let s), .context(let s): return s
        }
    }

    var kindPrefix: String {
        switch self {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }
}

struct FileCodeEdit: Identifiable {
    let id: String
    let path: String
    let toolName: String
    let status: ToolCallStatus
    let lines: [CodeDiffLine]

    var addedCount: Int {
        lines.reduce(0) { partial, line in
            if case .added = line { return partial + 1 }
            return partial
        }
    }

    var removedCount: Int {
        lines.reduce(0) { partial, line in
            if case .removed = line { return partial + 1 }
            return partial
        }
    }

    var shortPath: String {
        // Prefer last 2–3 path components for the card header.
        let parts = path.split(separator: "/").map(String.init)
        if parts.count <= 2 { return path }
        return parts.suffix(3).joined(separator: "/")
    }

    /// True when we reconstructed a rewrite against prior content (shows red − lines).
    var isRewrite: Bool = false

    /// HunkTracker ids from tool result (`hunk_id=…`). Empty when untracked.
    var hunkIDs: [UUID] = []

    /// Successful edit with at least one trackable hunk for post-apply Undo.
    var canUndo: Bool {
        status == .success && !hunkIDs.isEmpty
    }

    var statusLabel: String {
        switch status {
        case .pending: return "Queued"
        case .running: return "Editing…"
        case .success:
            if removedCount > 0 { return "Edited" }
            if isRewrite { return "Rewrote" }
            if toolName == "write_file" || toolName == "XcodeWrite" { return "Created" }
            return "Edited"
        case .failure: return "Failed"
        }
    }
}

enum CodeTimelineEntry: Identifiable {
    case userPrompt(String, messageId: UUID)
    case orchestratorPlan(String)
    case plan(Plan)
    case fileEdit(FileCodeEdit)
    case activity(ToolCallUIState)
    case assistantProse(String, messageId: UUID, isStreaming: Bool = false)

    var id: String {
        switch self {
        case .userPrompt(_, let messageId):
            return "user-\(messageId.uuidString)"
        case .orchestratorPlan:
            // Stable across brief edits so the card doesn't destroy/recreate (flicker).
            return "orch-plan"
        case .plan:
            // One live plan card identity — content updates in place.
            return "plan-live"
        case .fileEdit(let edit):
            return "edit-\(edit.id)"
        case .activity(let state):
            return "act-\(state.id)"
        case .assistantProse(_, let messageId, let isStreaming):
            // Streaming and committed prose for the same message share one id so
            // SwiftUI updates text in place instead of flashing a new row.
            // Live pre-persist stream uses a fixed sentinel messageId.
            if isStreaming {
                return "prose-live"
            }
            return "prose-\(messageId.uuidString)"
        }
    }
}

extension CodeTimelineEntry {
    /// Stable UUID for the in-flight streaming prose row (before the
    /// assistant message is persisted). Must never be `UUID()` per render.
    static let liveStreamingMessageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
}

enum CodeSessionBuilder {

    /// Mutating file tools that get inline expandable diff cards in Chat
    /// (and file-edit rows in Code). Shared so both surfaces stay in sync.
    static let editTools: Set<String> = [
        "apply_patch", "edit_file", "write_file", "search_replace",
        "XcodeWrite", "XcodeUpdate",
    ]

    /// Parse a tool UI state into a file edit (path + green/red lines).
    /// Pass `previousContent` when known (earlier write/edit of the same path)
    /// so full-file rewrites show red removals, not only green adds.
    static func fileEdit(from state: ToolCallUIState,
                         previousContent: String? = nil) -> FileCodeEdit? {
        parseFileEdit(from: state, previousContent: previousContent)
    }

    static func isEditTool(_ name: String) -> Bool {
        editTools.contains(name)
    }

    /// Path targeted by an edit tool, if any.
    static func path(from state: ToolCallUIState) -> String? {
        let payload = argumentJSON(input: state.input, output: state.output)
        return string(payload, keys: ["path", "file_path", "filePath", "absolutePath", "file"])
            ?? pathFromPatch(payload)
    }

    /// Full file body written by this tool (for chaining rewrites).
    static func writtenContent(from state: ToolCallUIState) -> String? {
        let payload = argumentJSON(input: state.input, output: state.output)
        switch state.toolName {
        case "write_file", "XcodeWrite":
            return string(payload, keys: ["content", "contents", "text"])
        case "edit_file", "search_replace", "XcodeUpdate":
            if let full = string(payload, keys: ["content", "contents", "text"]) {
                return full
            }
            return nil
        default:
            return nil
        }
    }

    /// Apply edit_file-style replacement onto prior full content when possible.
    static func contentAfterEdit(previous: String?, state: ToolCallUIState) -> String? {
        if let written = writtenContent(from: state) { return written }
        let payload = argumentJSON(input: state.input, output: state.output)
        guard var prev = previous else { return previous }

        // SEARCH/REPLACE blocks (edit_file wire format).
        let pathHint = string(payload, keys: ["path", "file_path", "filePath"]) ?? ""
        if let editsText = string(payload, keys: ["edits", "edit", "blocks"]) {
            let normalised = ensureDefaultFilename(editsText, defaultPath: pathHint)
            if let blocks = try? EditBlockParser.findBlocks(in: normalised), !blocks.isEmpty {
                for block in blocks {
                    if block.original.isEmpty { continue }
                    if let range = prev.range(of: block.original) {
                        prev.replaceSubrange(range, with: block.updated)
                    } else {
                        prev = prev.replacingOccurrences(of: block.original, with: block.updated)
                    }
                }
                return prev
            }
        }

        // Legacy old_string / new_string.
        guard let old = string(payload, keys: ["old_string", "search", "find"]),
              let new = string(payload, keys: ["new_string", "replace", "replacement"])
        else { return previous }
        let replaceAll = (payload["replace_all"] as? Bool) ?? false
        if replaceAll {
            return prev.replacingOccurrences(of: old, with: new)
        }
        if let range = prev.range(of: old) {
            prev.replaceSubrange(range, with: new)
            return prev
        }
        return prev
    }

    static func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("file://") { p = String(p.dropFirst("file://".count)) }
        if p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        // Expand ~ and junk like $(whoami) so create/edit share one content key.
        if p.hasPrefix("~/") {
            p = NSHomeDirectory() + String(p.dropFirst())
        }
        p = p.replacingOccurrences(of: "$(whoami)", with: NSUserName())
        p = p.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
        p = (p as NSString).standardizingPath
        // Also index by last two components for fuzzy seed lookup.
        return p
    }

    /// Look up prior content by exact path or matching filename suffix.
    static func lookupContent(_ map: [String: String], path: String) -> String? {
        let key = normalizePath(path)
        if let c = map[key] { return c }
        let file = (key as NSString).lastPathComponent
        guard !file.isEmpty else { return nil }
        for (k, v) in map {
            if k == file || k.hasSuffix("/" + file) || (k as NSString).lastPathComponent == file {
                return v
            }
        }
        return nil
    }

    private static let planTools: Set<String> = [
        "create_plan", "update_todo", "revise_plan",
    ]

    /// Latest plan projected from plan-authoring tool calls in the transcript.
    static func currentPlan(
        conversation: Conversation,
        toolStates: [UUID: [ToolCallUIState]]
    ) -> Plan? {
        build(conversation: conversation, toolStates: toolStates)
            .compactMap { entry -> Plan? in
                if case .plan(let plan) = entry { return plan }
                return nil
            }
            .last
    }

    static func build(
        conversation: Conversation,
        toolStates: [UUID: [ToolCallUIState]]
    ) -> [CodeTimelineEntry] {
        var entries: [CodeTimelineEntry] = []
        var currentPlan: Plan?
        var assistantRun: [ChatMessage] = []
        /// Path → last known full file body (for rewrite red/− diffs).
        var knownContents: [String: String] = [:]

        func flushAssistantRun() {
            guard !assistantRun.isEmpty else { return }

            // Chronological (Cursor / Claude / ZCode): each assistant iteration
            // in order — prose for that step first ("I'll do X"), then its tools,
            // then the next iteration, then the final message last.
            //
            // Old behavior dumped every tool in the run first and a single
            // prose blob at the end, so "what I'll do" appeared under shells.
            for msg in assistantRun {
                let prose = msg.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !prose.isEmpty {
                    entries.append(.assistantProse(prose, messageId: msg.id, isStreaming: false))
                }

                let states = toolStates[msg.id] ?? toolCallsFromMessage(msg)
                for state in states {
                    // Stable timeline identity: include message id so reused
                    // model tool-call ids don't collide across user turns
                    // (SwiftUI would otherwise re-use rows and look "duplicated").
                    let scopedID = "\(msg.id.uuidString)::\(state.id)"
                    let scopedState = ToolCallUIState(
                        id: scopedID,
                        toolName: state.toolName,
                        status: state.status,
                        input: state.input,
                        output: state.output
                    )

                    if planTools.contains(state.toolName) {
                        if let plan = parsePlan(from: state, merging: currentPlan) {
                            currentPlan = plan
                            // Single stable plan card — update in place so ForEach
                            // identity (`plan-live`) doesn't thrash / duplicate.
                            if let idx = entries.lastIndex(where: {
                                if case .plan = $0 { return true }
                                return false
                            }) {
                                entries[idx] = .plan(plan)
                            } else {
                                entries.append(.plan(plan))
                            }
                        }
                        continue
                    }

                    if editTools.contains(state.toolName) {
                        let pathKey = path(from: state).map(normalizePath)
                        let previous = pathKey.flatMap { knownContents[$0] }
                        if var edit = parseFileEdit(from: state, previousContent: previous) {
                            edit = FileCodeEdit(
                                id: scopedID,
                                path: edit.path,
                                toolName: edit.toolName,
                                status: edit.status,
                                lines: edit.lines,
                                isRewrite: edit.isRewrite,
                                hunkIDs: edit.hunkIDs
                            )
                            entries.append(.fileEdit(edit))
                            if let pathKey {
                                if let after = contentAfterEdit(previous: previous, state: state) {
                                    knownContents[pathKey] = after
                                } else if let written = writtenContent(from: state) {
                                    knownContents[pathKey] = written
                                }
                            }
                        } else {
                            entries.append(.activity(scopedState))
                        }
                        continue
                    }

                    entries.append(.activity(scopedState))
                }
            }

            assistantRun.removeAll(keepingCapacity: true)
        }

        for msg in conversation.messages {
            switch msg.role {
            case .user:
                flushAssistantRun()

                let prompt = msg.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !prompt.isEmpty {
                    entries.append(.userPrompt(prompt, messageId: msg.id))
                }

                if let brief = conversation.orchestratorBriefs[msg.id.uuidString],
                   !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    entries.append(.orchestratorPlan(brief))
                }

            case .assistant:
                assistantRun.append(msg)

            default:
                break
            }
        }

        flushAssistantRun()
        return entries
    }

    private static func toolCallsFromMessage(_ msg: ChatMessage) -> [ToolCallUIState] {
        msg.toolCalls.map {
            ToolCallUIState(id: $0.id, toolName: $0.name, status: .success,
                            input: $0.arguments, output: "")
        }
    }

    // MARK: - Plan parsing

    private static func parsePlan(from state: ToolCallUIState, merging existing: Plan?) -> Plan? {
        // create_plan / revise_plan put the structured payload in *arguments*.
        // Tool *output* is a human checklist ("Created plan.\n1. [ ] …") —
        // prefer input so we don't lose the step list.
        let payload: [String: Any]
        switch state.toolName {
        case "create_plan", "revise_plan":
            payload = parseJSON(state.input) ?? parseJSON(state.output) ?? [:]
        default:
            payload = mergedJSON(input: state.input, output: state.output)
        }

        if state.toolName == "update_todo" {
            let updatePayload = parseJSON(state.input)
                ?? parseJSON(state.output)
                ?? payload
            guard !updatePayload.isEmpty else { return existing }
            return applyTodoUpdate(updatePayload, to: existing)
        }

        if payload.isEmpty {
            // Fallback: reconstruct from checklist-style tool output.
            if state.toolName == "create_plan" || state.toolName == "revise_plan",
               let fromChecklist = parseChecklistPlan(state.output) {
                return fromChecklist
            }
            return existing
        }

        let goal = string(payload, keys: ["goal", "title", "summary", "name"])
            ?? existing?.goal
            ?? "Task plan"

        var todos = parseTodos(payload["todos"] ?? payload["items"] ?? payload["steps"])
        if todos.isEmpty, let existing { todos = existing.todos }
        // Last resort: pull steps from the rendered checklist in tool output.
        if todos.isEmpty,
           let fromChecklist = parseChecklistPlan(state.output) {
            todos = fromChecklist.todos
        }

        guard !todos.isEmpty || (goal != "Task plan" && existing == nil) else {
            return existing
        }
        // Never surface a "complete" empty shell — keep prior steps if any.
        if todos.isEmpty, let existing, !existing.todos.isEmpty {
            return Plan(goal: goal, todos: existing.todos)
        }
        return Plan(goal: goal, todos: todos)
    }

    private static func applyTodoUpdate(_ payload: [String: Any], to existing: Plan?) -> Plan? {
        guard var plan = existing else {
            let text = string(payload, keys: ["text", "todo", "description"]) ?? "Update"
            return Plan(goal: "Task plan", todos: [
                Todo(id: string(payload, keys: ["id"]) ?? UUID().uuidString,
                     text: text,
                     status: parseTodoStatus(payload["status"]) ?? .pending,
                     result: string(payload, keys: ["result", "note"]))
            ])
        }

        let todoID = string(payload, keys: ["id", "todo_id", "todoId"])
        let text = string(payload, keys: ["text", "todo", "description"])
        let status = parseTodoStatus(payload["status"])
        let result = string(payload, keys: ["result", "note"])

        if let todoID,
           let idx = plan.todos.firstIndex(where: {
               $0.id == todoID || $0.id == todoID.trimmingCharacters(in: .whitespaces)
           }) {
            if let text { plan.todos[idx].text = text }
            if let status {
                plan.todos[idx].status = status
            }
            if let result { plan.todos[idx].result = result }
        } else if let text {
            plan.todos.append(Todo(
                id: todoID ?? String(plan.todos.count + 1),
                text: text,
                status: status ?? .pending,
                result: result
            ))
        }

        return plan
    }

    /// Accepts the wire shapes models actually emit:
    ///   • `["Do A", "Do B"]`          ← CreatePlanTool schema (primary)
    ///   • `[{ "text": "Do A" }, …]`  ← object form
    ///   • mixed `[Any]` from JSONSerialization
    private static func parseTodos(_ raw: Any?) -> [Todo] {
        guard let raw else { return [] }

        if let strings = raw as? [String] {
            return strings.enumerated().compactMap { index, text in
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return nil }
                return Todo(id: String(index + 1), text: t)
            }
        }

        if let anyArray = raw as? [Any] {
            return anyArray.enumerated().compactMap { index, item -> Todo? in
                if let s = item as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return nil }
                    return Todo(id: String(index + 1), text: t)
                }
                if let dict = item as? [String: Any] {
                    let text = string(dict, keys: ["text", "description", "title", "content", "step"])
                        ?? "Step \(index + 1)"
                    return Todo(
                        id: string(dict, keys: ["id"]) ?? String(index + 1),
                        text: text,
                        status: parseTodoStatus(dict["status"]) ?? .pending,
                        result: string(dict, keys: ["result", "note"])
                    )
                }
                return nil
            }
        }

        return []
    }

    /// Reconstruct a plan from `CreatePlanTool` / `UpdateTodoTool` checklist output:
    /// ```
    /// Plan — Ship login
    /// 1. [ ] Add model
    /// 2. [x] Wire UI
    /// ```
    private static func parseChecklistPlan(_ output: String) -> Plan? {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var goal = "Task plan"
        var todos: [Todo] = []
        for line in lines {
            if line.lowercased().hasPrefix("plan —") || line.lowercased().hasPrefix("plan -") {
                let rest = line.drop(while: { $0 != "—" && $0 != "-" }).dropFirst().trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { goal = rest }
                continue
            }
            if line.lowercased().hasPrefix("created plan") { continue }
            if line.lowercased().hasPrefix("progress:") { continue }

            // "1. [x] text" / "2. [~] text → note"
            guard let dot = line.firstIndex(of: ".") else { continue }
            let idPart = String(line[..<dot]).trimmingCharacters(in: .whitespaces)
            guard Int(idPart) != nil || !idPart.isEmpty else { continue }
            var rest = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)

            var status: TodoStatus = .pending
            if rest.hasPrefix("[") {
                if let close = rest.firstIndex(of: "]") {
                    let mark = String(rest[rest.index(after: rest.startIndex)..<close]).lowercased()
                    switch mark {
                    case "x", "✓", "✔": status = .done
                    case "~", ">": status = .inProgress
                    case "!", "f": status = .failed
                    case "-", "s": status = .skipped
                    default: status = .pending
                    }
                    rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                }
            }

            var result: String?
            if let arrow = rest.range(of: " → ") ?? rest.range(of: " -> ") {
                result = String(rest[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
                rest = String(rest[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            guard !rest.isEmpty else { continue }
            todos.append(Todo(id: idPart, text: rest, status: status, result: result))
        }
        guard !todos.isEmpty else { return nil }
        return Plan(goal: goal, todos: todos)
    }

    private static func parseTodoStatus(_ raw: Any?) -> TodoStatus? {
        if let s = raw as? String {
            return TodoStatus(lenient: s)
        }
        return nil
    }

    // MARK: - File edit parsing

    private static func parseFileEdit(from state: ToolCallUIState,
                                      previousContent: String? = nil) -> FileCodeEdit? {
        // Prefer tool *arguments* (input). Output is usually a status string
        // ("Edited … 1/1 block applied") and must not replace path/edits.
        let payload = argumentJSON(input: state.input, output: state.output)
        let path = string(payload, keys: ["path", "file_path", "filePath", "absolutePath", "file"])
            ?? pathFromPatch(payload)
            ?? state.toolName

        var isRewrite = false
        var lines: [CodeDiffLine] = []
        switch state.toolName {
        case "apply_patch":
            lines = linesFromPatch(string(payload, keys: ["patch", "diff", "content"]) ?? "")
        case "edit_file", "search_replace", "XcodeUpdate":
            // Primary wire format: plain-text SEARCH/REPLACE in `edits`
            // (same as EditFileTool — may omit filename when `path` is set).
            lines = linesFromEditFile(payload, defaultPath: path)
            // If blocks didn't parse but we know prior + can apply, fall back to rewrite.
            if lines.isEmpty, let prev = previousContent,
               let after = contentAfterEdit(previous: prev, state: state),
               after != prev {
                lines = linesFromRewrite(old: prev, new: after)
                isRewrite = true
            }
        case "write_file", "XcodeWrite":
            let newBody = string(payload, keys: ["content", "contents", "text"]) ?? ""
            if let prev = previousContent, !prev.isEmpty, prev != newBody {
                // Overwrite of a known prior version → real red/green rewrite diff.
                lines = linesFromRewrite(old: prev, new: newBody)
                isRewrite = true
            } else {
                lines = linesFromWrite(newBody)
            }
        default:
            let raw = state.output.isEmpty ? state.input : state.output
            if let prev = previousContent, !prev.isEmpty,
               let newBody = string(payload, keys: ["content", "contents", "text"]),
               prev != newBody {
                lines = linesFromRewrite(old: prev, new: newBody)
                isRewrite = true
            } else {
                lines = linesFromEditFile(payload, defaultPath: path)
                if lines.isEmpty {
                    lines = linesFromPatch(raw)
                }
            }
        }

        // Failed edits: still show a card with the tool error (collapsed noise).
        // Successful edits must not fall through to status-text-as-context only.
        if lines.isEmpty {
            if state.status == .failure, !state.output.isEmpty {
                lines = state.output
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(12)
                    .map { CodeDiffLine.context(String($0)) }
            }
        }

        guard !lines.isEmpty else { return nil }
        return FileCodeEdit(
            id: state.id,
            path: path,
            toolName: state.toolName,
            status: state.status,
            lines: Array(lines.prefix(160)),
            isRewrite: isRewrite,
            hunkIDs: parseHunkIDs(from: state.output)
        )
    }

    /// Extract `hunk_id=<uuid>` tokens from tool result text.
    static func parseHunkIDs(from output: String) -> [UUID] {
        guard !output.isEmpty else { return [] }
        let pattern = #"hunk_id=([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }
            let s = ns.substring(with: m.range(at: 1))
            guard let id = UUID(uuidString: s), seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    private static func linesFromPatch(_ patch: String) -> [CodeDiffLine] {
        patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { raw -> CodeDiffLine? in
                let line = String(raw)
                if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
                    return .context(line)
                }
                if line.hasPrefix("+") { return .added(String(line.dropFirst())) }
                if line.hasPrefix("-") { return .removed(String(line.dropFirst())) }
                if line.isEmpty { return nil }
                return .context(line)
            }
    }

    private static func linesFromEditFile(_ payload: [String: Any],
                                          defaultPath: String = "") -> [CodeDiffLine] {
        var lines: [CodeDiffLine] = []

        // 1) edit_file primary format: `edits` with <<<<<<< SEARCH / ======= / >>>>>>> REPLACE
        //    Models often omit the filename line and only pass `path` — match EditFileTool.
        if let editsText = string(payload, keys: ["edits", "edit", "blocks"]) {
            let normalised = ensureDefaultFilename(editsText, defaultPath: defaultPath)
            if let blocks = try? EditBlockParser.findBlocks(in: normalised), !blocks.isEmpty {
                for block in blocks {
                    let old = block.original
                    let new = block.updated
                    // Strip trailing single newlines that the parser keeps for apply fidelity.
                    let oldTrim = old.hasSuffix("\n") ? String(old.dropLast()) : old
                    let newTrim = new.hasSuffix("\n") ? String(new.dropLast()) : new
                    if oldTrim.isEmpty, !newTrim.isEmpty {
                        newTrim.split(separator: "\n", omittingEmptySubsequences: false)
                            .forEach { lines.append(.added(String($0))) }
                    } else {
                        if !oldTrim.isEmpty {
                            oldTrim.split(separator: "\n", omittingEmptySubsequences: false)
                                .forEach { lines.append(.removed(String($0))) }
                        }
                        if !newTrim.isEmpty {
                            newTrim.split(separator: "\n", omittingEmptySubsequences: false)
                                .forEach { lines.append(.added(String($0))) }
                        }
                    }
                }
                return lines
            }
        }

        // 2) Legacy / porting tools: old_string + new_string
        if let old = string(payload, keys: ["old_string", "search", "find"]) {
            old.split(separator: "\n", omittingEmptySubsequences: false)
                .forEach { lines.append(.removed(String($0))) }
        }
        if let new = string(payload, keys: ["new_string", "replace", "replacement"]) {
            new.split(separator: "\n", omittingEmptySubsequences: false)
                .forEach { lines.append(.added(String($0))) }
        }
        return lines
    }

    /// Mirror EditFileTool: if `edits` starts at SEARCH marker, inject `path` as filename.
    private static func ensureDefaultFilename(_ editsText: String, defaultPath: String) -> String {
        guard !defaultPath.isEmpty else { return editsText }
        let trimmed = editsText.drop { $0.isWhitespace }
        if trimmed.hasPrefix("<<<<<<<") || trimmed.hasPrefix("<<<<<<") || trimmed.hasPrefix("<<<<<") {
            return defaultPath + "\n" + editsText
        }
        return editsText
    }

    private static func linesFromWrite(_ content: String) -> [CodeDiffLine] {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(80)
            .map { .added(String($0)) }
    }

    /// Line-level rewrite diff so full-file write after a prior version shows red −.
    private static func linesFromRewrite(old: String, new: String) -> [CodeDiffLine] {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if oldLines == newLines {
            return Array(newLines.prefix(40).map { CodeDiffLine.context($0) })
        }

        // Prefer CollectionDifference when available for ordered +/−.
        let diff = newLines.difference(from: oldLines)
        var out: [CodeDiffLine] = []
        out.reserveCapacity(min(160, oldLines.count + newLines.count))
        for change in diff {
            switch change {
            case .remove(_, let element, _):
                out.append(.removed(element))
            case .insert(_, let element, _):
                out.append(.added(element))
            }
        }
        // If difference is empty but strings differ (shouldn't happen), fall back.
        if out.isEmpty {
            oldLines.forEach { out.append(.removed($0)) }
            newLines.forEach { out.append(.added($0)) }
        }
        return Array(out.prefix(160))
    }

    private static func pathFromPatch(_ payload: [String: Any]) -> String? {
        guard let patch = string(payload, keys: ["patch"]) else { return nil }
        for line in patch.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("+++ b/") { return String(s.dropFirst(6)) }
            if s.hasPrefix("+++ ") { return String(s.dropFirst(4)) }
        }
        return nil
    }

    // MARK: - JSON helpers

    /// Prefer tool arguments. Output is usually human status text, not JSON args.
    private static func argumentJSON(input: String, output: String) -> [String: Any] {
        parseJSON(input) ?? parseJSON(output) ?? [:]
    }

    private static func mergedJSON(input: String, output: String) -> [String: Any] {
        // Keep for call sites that want "latest"; argumentJSON is safer for edits.
        parseJSON(output) ?? parseJSON(input) ?? [:]
    }

    private static func parseJSON(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func string(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            // Models often emit numeric ids (`"id": 2`) for update_todo.
            if let value = dict[key] as? Int { return String(value) }
            if let value = dict[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }
}