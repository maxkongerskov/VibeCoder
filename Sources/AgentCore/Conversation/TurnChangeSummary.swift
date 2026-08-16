//
//  TurnChangeSummary.swift
//
//  Aggregates mutating file-tool calls in one assistant turn into
//  ZCode-style "N file(s) changed +a −d" rows. Pure: no disk I/O.
//

import Foundation

/// Per-turn file-change rollup for the chat turn-end card.
public struct TurnChangeSummary: Sendable, Equatable {
    public struct FileChange: Sendable, Equatable, Identifiable {
        public enum Status: String, Sendable, Equatable {
            case created
            case modified
            case deleted
        }

        public var path: String
        public var added: Int
        public var removed: Int
        public var status: Status

        public var id: String { TurnChangeSummary.pathKey(path) }

        public init(path: String, added: Int, removed: Int, status: Status) {
            self.path = path
            self.added = added
            self.removed = removed
            self.status = status
        }
    }

    public var files: [FileChange]
    /// User prompt that opened this turn, when known.
    public var userMessageID: UUID?

    public var totalAdded: Int { files.reduce(0) { $0 + $1.added } }
    public var totalRemoved: Int { files.reduce(0) { $0 + $1.removed } }
    public var fileCount: Int { files.count }
    public var isEmpty: Bool { files.isEmpty }

    public static let empty = TurnChangeSummary(files: [], userMessageID: nil)

    public init(files: [FileChange], userMessageID: UUID? = nil) {
        self.files = files
        self.userMessageID = userMessageID
    }

    /// Dedupe / lookup key (standardized path).
    public static func pathKey(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("file://") {
            p = String(p.dropFirst("file://".count))
        }
        if p.hasPrefix("./") {
            p = String(p.dropFirst(2))
        }
        return (p as NSString).standardizingPath
    }

    /// Treat `messages` as a single turn (user + assistant + tool rows).
    public static func summarize(turnMessages: [ChatMessage]) -> TurnChangeSummary {
        var engine = Engine()
        for msg in turnMessages {
            engine.consume(msg)
        }
        return engine.flushTurn()
    }

    /// One summary per visible user turn. Changes stay on the turn that made them.
    public static func summarizeEachTurn(in messages: [ChatMessage]) -> [TurnChangeSummary] {
        var engine = Engine()
        var out: [TurnChangeSummary] = []
        for msg in messages {
            if msg.role == .user && !msg.isWireOnlySystemReminder {
                if engine.hasOpenedTurn {
                    out.append(engine.flushTurn())
                }
                engine.beginTurn(userID: msg.id)
                continue
            }
            engine.consume(msg)
        }
        if engine.hasOpenedTurn || engine.hasPendingFiles {
            out.append(engine.flushTurn())
        }
        return out
    }
}

// MARK: - Walk

private struct Engine {
    struct Accum {
        var displayPath: String
        var added: Int
        var removed: Int
        var lastOp: TurnChangeSummary.FileChange.Status
        var existedAtTurnStart: Bool
        var createdThisTurn: Bool
    }

    var contents: [String: String] = [:]
    var pendingInvocations: [String: ToolCallInvocation] = [:]
    var currentUserID: UUID?
    var knownAtTurnStart: Set<String> = []
    var files: [String: Accum] = [:]
    var fileOrder: [String] = []
    var hasOpenedTurn = false

    var hasPendingFiles: Bool { !files.isEmpty || !pendingInvocations.isEmpty }

    mutating func beginTurn(userID: UUID) {
        currentUserID = userID
        knownAtTurnStart = Set(contents.keys)
        files = [:]
        fileOrder = []
        pendingInvocations = [:]
        hasOpenedTurn = true
    }

    mutating func flushTurn() -> TurnChangeSummary {
        applyUnpairedInvocations()
        let summary = TurnChangeSummary(
            files: fileOrder.compactMap { key in
                guard let acc = files[key] else { return nil }
                let status: TurnChangeSummary.FileChange.Status
                if acc.lastOp == .deleted {
                    status = .deleted
                } else if acc.existedAtTurnStart {
                    status = .modified
                } else if acc.createdThisTurn {
                    status = .created
                } else {
                    status = acc.lastOp
                }
                return TurnChangeSummary.FileChange(
                    path: acc.displayPath,
                    added: acc.added,
                    removed: acc.removed,
                    status: status
                )
            },
            userMessageID: currentUserID
        )
        files = [:]
        fileOrder = []
        pendingInvocations = [:]
        currentUserID = nil
        return summary
    }

    mutating func consume(_ msg: ChatMessage) {
        switch msg.role {
        case .assistant:
            for inv in msg.toolCalls {
                pendingInvocations[inv.id] = inv
            }
        case .tool:
            guard let id = msg.toolCallID, let inv = pendingInvocations.removeValue(forKey: id) else {
                return
            }
            apply(invocation: inv, result: msg.content)
        default:
            break
        }
    }

    mutating func applyUnpairedInvocations() {
        let leftover = pendingInvocations
        pendingInvocations = [:]
        for inv in leftover.values {
            apply(invocation: inv, result: nil)
        }
    }

    mutating func apply(invocation: ToolCallInvocation, result: String?) {
        if let result, Parser.looksFailed(result) { return }
        let accepted = result.flatMap(Parser.acceptedPatchPaths)
        Parser.apply(
            name: invocation.name,
            arguments: invocation.arguments,
            acceptedPaths: accepted,
            contents: &contents,
            knownAtTurnStart: knownAtTurnStart,
            files: &files,
            fileOrder: &fileOrder
        )
    }
}

// Re-implement consume without the unused lookahead.

private enum Parser {
    static let mutatingTools: Set<String> = [
        "write_file", "XcodeWrite",
        "edit_file", "search_replace", "XcodeUpdate",
        "apply_patch",
        "delete_file",
    ]

    static func looksFailed(_ content: String) -> Bool {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty { return false }
        if t.contains("no files modified") { return true }
        if t.contains("no net multi-file") { return true }
        if t.hasPrefix("error") { return true }
        if t.contains("patch rejected") { return true }
        if t.contains("patch failed") { return true }
        if t.contains("patch parsed to zero") { return true }
        if t.contains("couldn't parse") { return true }
        if t.contains("read-before-edit") { return true }
        if t.contains("strict multi-block apply") { return true }
        if t.contains("tool error:") { return true }
        return false
    }

    /// Paths listed as `Patched <path> (` in apply_patch output.
    static func acceptedPatchPaths(_ content: String) -> Set<String>? {
        var paths = Set<String>()
        for line in content.split(separator: "\n") {
            let s = String(line)
            guard s.hasPrefix("Patched ") else { continue }
            let rest = s.dropFirst("Patched ".count)
            if let paren = rest.firstIndex(of: "(") {
                let path = rest[..<paren].trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { paths.insert(path) }
            }
        }
        return paths.isEmpty ? nil : paths
    }

    static func apply(
        name: String,
        arguments: String,
        acceptedPaths: Set<String>?,
        contents: inout [String: String],
        knownAtTurnStart: Set<String>,
        files: inout [String: Engine.Accum],
        fileOrder: inout [String]
    ) {
        guard mutatingTools.contains(name) else { return }
        let payload = ChatLoop.parseToolArgs(arguments)

        switch name {
        case "apply_patch":
            let patchText = string(payload, keys: ["patch", "diff", "content"]) ?? arguments
            let patches = UnifiedDiff.parse(patchText)
            for filePatch in patches {
                if let acceptedPaths {
                    let key = TurnChangeSummary.pathKey(filePatch.path)
                    let listed = acceptedPaths.contains { TurnChangeSummary.pathKey($0) == key }
                    if !listed { continue }
                }
                applyPatchFile(
                    filePatch,
                    contents: &contents,
                    knownAtTurnStart: knownAtTurnStart,
                    files: &files,
                    fileOrder: &fileOrder
                )
            }

        case "delete_file":
            guard let path = string(payload, keys: ["path", "file_path", "filePath", "file"]) else { return }
            applyDelete(
                path: path,
                contents: &contents,
                knownAtTurnStart: knownAtTurnStart,
                files: &files,
                fileOrder: &fileOrder
            )

        case "write_file", "XcodeWrite":
            guard let path = string(payload, keys: ["path", "file_path", "filePath", "absolutePath", "file"]) else { return }
            let body = string(payload, keys: ["content", "contents", "text"]) ?? ""
            applyWrite(
                path: path,
                newBody: body,
                contents: &contents,
                knownAtTurnStart: knownAtTurnStart,
                files: &files,
                fileOrder: &fileOrder
            )

        default:
            // edit_file / search_replace / XcodeUpdate
            guard let path = string(payload, keys: ["path", "file_path", "filePath", "absolutePath", "file"]) else { return }
            applyEdit(
                path: path,
                payload: payload,
                contents: &contents,
                knownAtTurnStart: knownAtTurnStart,
                files: &files,
                fileOrder: &fileOrder
            )
        }
    }

    static func applyWrite(
        path: String,
        newBody: String,
        contents: inout [String: String],
        knownAtTurnStart: Set<String>,
        files: inout [String: Engine.Accum],
        fileOrder: inout [String]
    ) {
        let key = TurnChangeSummary.pathKey(path)
        let previous = contents[key]
        let added: Int
        let removed: Int
        if let previous, previous != newBody {
            let counts = rewriteCounts(old: previous, new: newBody)
            added = counts.added
            removed = counts.removed
        } else if previous == newBody {
            return
        } else {
            added = lineCount(newBody)
            removed = 0
        }
        let op: TurnChangeSummary.FileChange.Status =
            (previous == nil) ? .created : .modified
        record(
            path: path,
            key: key,
            added: added,
            removed: removed,
            op: op,
            knownAtTurnStart: knownAtTurnStart,
            files: &files,
            fileOrder: &fileOrder
        )
        contents[key] = newBody
    }

    static func applyEdit(
        path: String,
        payload: [String: Any],
        contents: inout [String: String],
        knownAtTurnStart: Set<String>,
        files: inout [String: Engine.Accum],
        fileOrder: inout [String]
    ) {
        let key = TurnChangeSummary.pathKey(path)
        var added = 0
        var removed = 0
        var created = false

        if let editsText = string(payload, keys: ["edits", "edit", "blocks"]) {
            let normalised = ensureDefaultFilename(editsText, defaultPath: path)
            if let blocks = try? EditBlockParser.findBlocks(in: normalised), !blocks.isEmpty {
                var allCreate = true
                for block in blocks {
                    let old = stripTrailingNewline(block.original)
                    let new = stripTrailingNewline(block.updated)
                    if old.isEmpty && !new.isEmpty {
                        added += lineCount(new)
                    } else {
                        allCreate = false
                        removed += lineCount(old)
                        added += lineCount(new)
                    }
                }
                created = allCreate
            }
        }

        if added == 0 && removed == 0 {
            if let old = string(payload, keys: ["old_string", "search", "find"]) {
                removed = lineCount(old)
            }
            if let new = string(payload, keys: ["new_string", "replace", "replacement"]) {
                added = lineCount(new)
            }
        }

        if added == 0 && removed == 0 { return }

        let op: TurnChangeSummary.FileChange.Status =
            created ? .created : .modified
        record(
            path: path,
            key: key,
            added: added,
            removed: removed,
            op: op,
            knownAtTurnStart: knownAtTurnStart,
            files: &files,
            fileOrder: &fileOrder
        )

        if let previous = contents[key] {
            if let after = applySearchReplace(payload, path: path, to: previous) {
                contents[key] = after
            }
        } else if created, let newBody = createdBody(payload, path: path) {
            contents[key] = newBody
        }
    }

    static func applyDelete(
        path: String,
        contents: inout [String: String],
        knownAtTurnStart: Set<String>,
        files: inout [String: Engine.Accum],
        fileOrder: inout [String]
    ) {
        let key = TurnChangeSummary.pathKey(path)
        let previous = contents[key]
        let removed: Int
        if let previous {
            removed = max(lineCount(previous), 1)
        } else {
            // Unknown prior body — still a removal-only row.
            removed = 1
        }
        record(
            path: path,
            key: key,
            added: 0,
            removed: removed,
            op: .deleted,
            knownAtTurnStart: knownAtTurnStart,
            files: &files,
            fileOrder: &fileOrder
        )
        contents.removeValue(forKey: key)
    }

    static func applyPatchFile(
        _ filePatch: UnifiedDiff.FilePatch,
        contents: inout [String: String],
        knownAtTurnStart: Set<String>,
        files: inout [String: Engine.Accum],
        fileOrder: inout [String]
    ) {
        var added = 0
        var removed = 0
        var oldLen = 0
        var newLen = 0
        for hunk in filePatch.hunks {
            oldLen += hunk.oldLen
            newLen += hunk.newLen
            for line in hunk.lines {
                switch line {
                case .added: added += 1
                case .removed: removed += 1
                case .context: break
                }
            }
        }
        if added == 0 && removed == 0 { return }

        let key = TurnChangeSummary.pathKey(filePatch.path)
        let op: TurnChangeSummary.FileChange.Status
        if newLen == 0 && removed > 0 && added == 0 {
            op = .deleted
        } else if oldLen == 0 && added > 0 {
            op = .created
        } else {
            op = .modified
        }
        record(
            path: filePatch.path,
            key: key,
            added: added,
            removed: removed,
            op: op,
            knownAtTurnStart: knownAtTurnStart,
            files: &files,
            fileOrder: &fileOrder
        )

        if op == .deleted {
            contents.removeValue(forKey: key)
        } else if let previous = contents[key],
                  case .success(let next) = UnifiedDiff.apply(filePatch: filePatch, to: previous) {
            contents[key] = next
        } else if op == .created {
            var body = ""
            for hunk in filePatch.hunks {
                for line in hunk.lines {
                    if case .added(let s) = line {
                        if !body.isEmpty { body += "\n" }
                        body += s
                    }
                }
            }
            if !body.isEmpty { contents[key] = body }
        }
    }

    static func record(
        path: String,
        key: String,
        added: Int,
        removed: Int,
        op: TurnChangeSummary.FileChange.Status,
        knownAtTurnStart: Set<String>,
        files: inout [String: Engine.Accum],
        fileOrder: inout [String]
    ) {
        if var acc = files[key] {
            acc.added += added
            acc.removed += removed
            acc.lastOp = op
            if op == .created { acc.createdThisTurn = true }
            files[key] = acc
        } else {
            files[key] = Engine.Accum(
                displayPath: path,
                added: added,
                removed: removed,
                lastOp: op,
                existedAtTurnStart: knownAtTurnStart.contains(key),
                createdThisTurn: op == .created
            )
            fileOrder.append(key)
        }
    }

    static func string(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func lineCount(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            return max(0, lines.count - 1)
        }
        return lines.count
    }

    static func stripTrailingNewline(_ text: String) -> String {
        if text.hasSuffix("\n") { return String(text.dropLast()) }
        return text
    }

    static func rewriteCounts(old: String, new: String) -> (added: Int, removed: Int) {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var added = 0
        var removed = 0
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .insert: added += 1
            case .remove: removed += 1
            }
        }
        return (added, removed)
    }

    static func ensureDefaultFilename(_ editsText: String, defaultPath: String) -> String {
        guard !defaultPath.isEmpty else { return editsText }
        let trimmed = editsText.drop { $0.isWhitespace }
        if trimmed.hasPrefix("<<<<<<<") || trimmed.hasPrefix("<<<<<<") || trimmed.hasPrefix("<<<<<") {
            return defaultPath + "\n" + editsText
        }
        return editsText
    }

    static func createdBody(_ payload: [String: Any], path: String) -> String? {
        guard let editsText = string(payload, keys: ["edits", "edit", "blocks"]) else {
            return string(payload, keys: ["new_string", "replace", "replacement"])
        }
        let normalised = ensureDefaultFilename(editsText, defaultPath: path)
        guard let blocks = try? EditBlockParser.findBlocks(in: normalised) else { return nil }
        var body = ""
        for block in blocks where block.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body += block.updated
        }
        return body.isEmpty ? nil : body
    }

    static func applySearchReplace(_ payload: [String: Any], path: String, to previous: String) -> String? {
        if let editsText = string(payload, keys: ["edits", "edit", "blocks"]) {
            let normalised = ensureDefaultFilename(editsText, defaultPath: path)
            if let blocks = try? EditBlockParser.findBlocks(in: normalised), !blocks.isEmpty {
                var next = previous
                for block in blocks {
                    switch EditBlockApplier.apply(block, to: next) {
                    case .applied(let updated): next = updated
                    case .failed: break
                    }
                }
                return next
            }
        }
        guard let old = string(payload, keys: ["old_string", "search", "find"]),
              let new = string(payload, keys: ["new_string", "replace", "replacement"])
        else { return nil }
        if let range = previous.range(of: old) {
            var next = previous
            next.replaceSubrange(range, with: new)
            return next
        }
        return previous.replacingOccurrences(of: old, with: new)
    }
}
