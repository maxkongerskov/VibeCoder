//
//  CheckpointStore.swift
//
//  Filesystem turn checkpoints for code-aware /rewind (Phase A PA4).
//
//  Before a mutating tool writes, we snapshot the on-disk pre-state of each
//  target path for the active conversation turn. /undo and /rewind restore
//  those files (not just chat transcript).
//
//  Persistence: ~/Library/Application Support/VibeCoder/checkpoints/
//    <conversationID>/<turnID>.json
//  Optional project-local mirror: <project>/.vibecoder/checkpoints/ when
//  `projectRoot` is provided to beginTurn (best-effort, non-fatal).
//
//  Hook: ToolRegistry.execute snapshots paths for `.mutates` tools before
//  the tool body runs. AgentLoop.beginTurn opens a turn id at run start.
//

import Foundation

// MARK: - Models

/// One file's pre-mutation state within a turn checkpoint.
public struct FileCheckpoint: Sendable, Equatable, Codable {
    /// Absolute path on disk.
    public var path: String
    /// True when the file/directory existed before the mutation.
    public var existed: Bool
    /// UTF-8 content when `existed` and readable as text; empty for create tombstone.
    public var content: String
    /// True when the path was a directory (restore deletes the tree if agent created it).
    public var isDirectory: Bool
    /// True when content was skipped (binary / unreadable) — restore will not rewrite it.
    public var skipped: Bool

    public init(
        path: String,
        existed: Bool,
        content: String = "",
        isDirectory: Bool = false,
        skipped: Bool = false
    ) {
        self.path = path
        self.existed = existed
        self.content = content
        self.isDirectory = isDirectory
        self.skipped = skipped
    }
}

/// All file snapshots for one agent turn (one user send / AgentLoop run).
public struct TurnCheckpoint: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var createdAt: Date
    public var files: [FileCheckpoint]
    /// True after restore consumed this turn (or explicit finalize).
    public var restored: Bool

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        createdAt: Date = Date(),
        files: [FileCheckpoint] = [],
        restored: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.createdAt = createdAt
        self.files = files
        self.restored = restored
    }
}

/// One path that failed during checkpoint restore.
public struct CheckpointRestoreFailure: Sendable, Equatable {
    public var path: String
    public var reason: String
    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// Result of restoring a turn checkpoint to disk.
public struct CheckpointRestoreReport: Sendable, Equatable {
    public var turnID: UUID?
    public var restoredPaths: [String]
    public var deletedPaths: [String]
    public var skippedPaths: [String]
    public var failedPaths: [CheckpointRestoreFailure]
    public var message: String

    public var restoredFileCount: Int { restoredPaths.count + deletedPaths.count }

    public init(
        turnID: UUID? = nil,
        restoredPaths: [String] = [],
        deletedPaths: [String] = [],
        skippedPaths: [String] = [],
        failedPaths: [CheckpointRestoreFailure] = [],
        message: String = ""
    ) {
        self.turnID = turnID
        self.restoredPaths = restoredPaths
        self.deletedPaths = deletedPaths
        self.skippedPaths = skippedPaths
        self.failedPaths = failedPaths
        self.message = message
    }

    /// Short status-line summary for slash handlers.
    public var statusSummary: String {
        if turnID == nil && restoredFileCount == 0 && failedPaths.isEmpty {
            return message.isEmpty ? "No file checkpoint for this turn" : message
        }
        var parts: [String] = []
        if restoredPaths.count > 0 {
            parts.append("restored \(restoredPaths.count) file(s)")
        }
        if deletedPaths.count > 0 {
            parts.append("removed \(deletedPaths.count) created path(s)")
        }
        if skippedPaths.count > 0 {
            parts.append("skipped \(skippedPaths.count)")
        }
        if failedPaths.count > 0 {
            parts.append("failed \(failedPaths.count)")
        }
        if parts.isEmpty {
            return message.isEmpty ? "No files to restore" : message
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Store

/// Durable per-turn filesystem checkpoints (code-aware undo/rewind).
public actor CheckpointStore {
    public static let shared = CheckpointStore()

    /// Tools whose arguments we snapshot before execution (path-bearing mutators).
    public static let snapshotToolNames: Set<String> = [
        "write_file", "edit_file", "apply_patch",
        "delete_file", "move_file", "create_directory",
        "memory", "xcode_project_editor",
        // App-hosted offline PDF mutators (also covered by .mutates permission).
        "create_pdf", "manipulate_pdf", "fill_pdf_form", "sign_pdf",
    ]

    private let rootDirectory: URL
    /// conversationID → active turn id
    private var activeTurnByConversation: [UUID: UUID] = [:]
    /// turnID → in-memory checkpoint (also flushed to disk)
    private var turns: [UUID: TurnCheckpoint] = [:]
    /// turnID → absolute paths already snapshotted this turn
    private var snapshotted: [UUID: Set<String>] = [:]
    /// conversationID → ordered turn ids (latest last)
    private var turnOrder: [UUID: [UUID]] = [:]
    /// Optional project mirror roots per conversation
    private var projectMirrorRoot: [UUID: URL] = [:]

    public init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            self.rootDirectory = AppSupport.directory("checkpoints")
        }
        try? FileManager.default.createDirectory(
            at: self.rootDirectory, withIntermediateDirectories: true)
    }

    // MARK: Turn lifecycle

    /// Open a new turn checkpoint for `conversationID`. Returns the turn id.
    /// Call once at the start of each user agent run (AgentLoop).
    @discardableResult
    public func beginTurn(
        conversationID: UUID,
        projectRoot: URL? = nil
    ) -> UUID {
        let turnID = UUID()
        let turn = TurnCheckpoint(id: turnID, conversationID: conversationID)
        turns[turnID] = turn
        snapshotted[turnID] = []
        activeTurnByConversation[conversationID] = turnID
        var order = turnOrder[conversationID] ?? []
        order.append(turnID)
        // Cap history per conversation to avoid unbounded growth.
        if order.count > 40 {
            let drop = order.prefix(order.count - 40)
            for old in drop {
                turns.removeValue(forKey: old)
                snapshotted.removeValue(forKey: old)
                try? FileManager.default.removeItem(at: turnFileURL(conversationID: conversationID, turnID: old))
            }
            order = Array(order.suffix(40))
        }
        turnOrder[conversationID] = order
        if let projectRoot {
            let mirror = projectRoot
                .appendingPathComponent(".vibecoder", isDirectory: true)
                .appendingPathComponent("checkpoints", isDirectory: true)
            try? FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
            projectMirrorRoot[conversationID] = mirror
        }
        persist(turn)
        return turnID
    }

    public func activeTurnID(for conversationID: UUID) -> UUID? {
        activeTurnByConversation[conversationID]
    }

    public func latestTurn(for conversationID: UUID) -> TurnCheckpoint? {
        guard let id = turnOrder[conversationID]?.last else {
            return loadLatestFromDisk(conversationID: conversationID)
        }
        return turns[id] ?? loadTurnFromDisk(conversationID: conversationID, turnID: id)
    }

    public func turn(id: UUID, conversationID: UUID) -> TurnCheckpoint? {
        if let t = turns[id] { return t }
        return loadTurnFromDisk(conversationID: conversationID, turnID: id)
    }

    // MARK: Snapshot

    /// Snapshot paths targeted by a mutating tool **before** it writes.
    /// Idempotent per path within a turn (first pre-state wins).
    public func snapshotBeforeMutation(
        toolName: String,
        arguments: ToolArguments,
        context: ToolContext
    ) {
        guard Self.snapshotToolNames.contains(toolName) else { return }
        let convoID = context.conversationID
        // Auto-open a turn if AgentLoop forgot (tests / headless).
        let turnID = activeTurnByConversation[convoID]
            ?? beginTurn(conversationID: convoID, projectRoot: context.projectRoot)
        let paths = Self.resolveTargetPaths(
            toolName: toolName,
            arguments: arguments,
            workingDirectory: context.workingDirectory
        )
        for url in paths {
            snapshotPath(url, turnID: turnID, conversationID: convoID)
        }
    }

    /// Snapshot a single absolute path into the active turn (first write wins).
    public func snapshotPath(
        _ url: URL,
        conversationID: UUID
    ) {
        let turnID = activeTurnByConversation[conversationID]
            ?? beginTurn(conversationID: conversationID)
        snapshotPath(url, turnID: turnID, conversationID: conversationID)
    }

    private func snapshotPath(
        _ url: URL,
        turnID: UUID,
        conversationID: UUID
    ) {
        let abs = url.resolvingSymlinksInPath().path
        var seen = snapshotted[turnID] ?? []
        guard seen.insert(abs).inserted else { return }
        snapshotted[turnID] = seen

        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: abs, isDirectory: &isDir)

        var entry = FileCheckpoint(
            path: abs,
            existed: exists,
            content: "",
            isDirectory: isDir.boolValue,
            skipped: false
        )

        if exists && !isDir.boolValue {
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                entry.content = text
            } else {
                // Binary or unreadable — do not invent content; skip on restore.
                entry.skipped = true
            }
        }

        guard var turn = turns[turnID] else { return }
        turn.files.append(entry)
        turns[turnID] = turn
        persist(turn)
    }

    // MARK: Restore

    /// Restore the latest (most recent) turn checkpoint for the conversation.
    /// Returns a report suitable for status lines / slash handlers.
    @discardableResult
    public func restoreLatest(
        conversationID: UUID,
        markRestored: Bool = true
    ) -> CheckpointRestoreReport {
        guard let turn = latestRestorable(conversationID: conversationID) else {
            return CheckpointRestoreReport(
                message: "No file checkpoint for this turn"
            )
        }
        return restore(turn: turn, markRestored: markRestored)
    }

    /// Restore a specific turn by id.
    @discardableResult
    public func restore(
        turnID: UUID,
        conversationID: UUID,
        markRestored: Bool = true
    ) -> CheckpointRestoreReport {
        guard let turn = turn(id: turnID, conversationID: conversationID) else {
            return CheckpointRestoreReport(
                message: "Unknown checkpoint \(turnID.uuidString)"
            )
        }
        return restore(turn: turn, markRestored: markRestored)
    }

    private func latestRestorable(conversationID: UUID) -> TurnCheckpoint? {
        let order = turnOrder[conversationID] ?? []
        for id in order.reversed() {
            if let t = turns[id] ?? loadTurnFromDisk(conversationID: conversationID, turnID: id),
               !t.restored,
               !t.files.isEmpty {
                return t
            }
        }
        // Disk fallback when memory was cleared (process restart).
        return loadLatestFromDisk(conversationID: conversationID).flatMap { t in
            (!t.restored && !t.files.isEmpty) ? t : nil
        }
    }

    private func restore(
        turn: TurnCheckpoint,
        markRestored: Bool
    ) -> CheckpointRestoreReport {
        var restored: [String] = []
        var deleted: [String] = []
        var skipped: [String] = []
        var failed: [CheckpointRestoreFailure] = []
        let fm = FileManager.default

        // Restore in reverse order so move source/dest pairs behave better.
        for file in turn.files.reversed() {
            if file.skipped {
                skipped.append(file.path)
                continue
            }
            let url = URL(fileURLWithPath: file.path)
            do {
                if file.existed {
                    if file.isDirectory {
                        // We only snapshot directory existence as a tombstone for
                        // create_directory — do not try to recreate directory trees
                        // from content. If agent deleted a dir we can't fully restore.
                        if !fm.fileExists(atPath: file.path) {
                            try fm.createDirectory(at: url, withIntermediateDirectories: true)
                            restored.append(file.path)
                        } else {
                            skipped.append(file.path)
                        }
                    } else {
                        try fm.createDirectory(
                            at: url.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try file.content.write(to: url, atomically: true, encoding: .utf8)
                        restored.append(file.path)
                    }
                } else {
                    // Did not exist before mutation → remove agent-created path.
                    if fm.fileExists(atPath: file.path) {
                        try fm.removeItem(at: url)
                        deleted.append(file.path)
                    }
                }
            } catch {
                failed.append(CheckpointRestoreFailure(
                    path: file.path, reason: error.localizedDescription))
            }
        }

        var updated = turn
        if markRestored {
            updated.restored = true
            turns[turn.id] = updated
            persist(updated)
            if activeTurnByConversation[turn.conversationID] == turn.id {
                activeTurnByConversation[turn.conversationID] = nil
            }
        }

        var report = CheckpointRestoreReport(
            turnID: turn.id,
            restoredPaths: restored.reversed(),
            deletedPaths: deleted.reversed(),
            skippedPaths: skipped.reversed(),
            failedPaths: failed.reversed()
        )
        report.message = report.statusSummary
        return report
    }

    /// Drop in-memory + on-disk checkpoints for a conversation.
    public func clear(conversationID: UUID) {
        let order = turnOrder[conversationID] ?? []
        for id in order {
            turns.removeValue(forKey: id)
            snapshotted.removeValue(forKey: id)
        }
        turnOrder.removeValue(forKey: conversationID)
        activeTurnByConversation.removeValue(forKey: conversationID)
        projectMirrorRoot.removeValue(forKey: conversationID)
        let dir = conversationDirectory(conversationID)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Path resolution (shared with ToolRegistry hook)

    /// Absolute URLs targeted by a mutator tool's arguments.
    public static func resolveTargetPaths(
        toolName: String,
        arguments: ToolArguments,
        workingDirectory: URL
    ) -> [URL] {
        var out: [URL] = []
        let base = workingDirectory

        if toolName == "apply_patch", let patch = arguments.stringOptional("patch") {
            for filePatch in UnifiedDiff.parse(patch) {
                out.append(resolvePath(filePatch.path, base: base))
            }
            return uniqueAbsolute(out)
        }

        if toolName == "move_file" {
            if let s = arguments.stringOptional("source"), !s.isEmpty {
                out.append(resolvePath(s, base: base))
            }
            if let d = arguments.stringOptional("destination"), !d.isEmpty {
                out.append(resolvePath(d, base: base))
            }
            return uniqueAbsolute(out)
        }

        for key in ToolAuthorization.pathArgumentKeys {
            guard let raw = arguments.stringOptional(key), !raw.isEmpty else { continue }
            out.append(resolvePath(raw, base: base))
        }
        return uniqueAbsolute(out)
    }

    private static func uniqueAbsolute(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for u in urls {
            let p = u.resolvingSymlinksInPath().path
            if seen.insert(p).inserted {
                result.append(URL(fileURLWithPath: p))
            }
        }
        return result
    }

    // MARK: Persistence

    private func conversationDirectory(_ conversationID: UUID) -> URL {
        let dir = rootDirectory.appendingPathComponent(
            conversationID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func turnFileURL(conversationID: UUID, turnID: UUID) -> URL {
        conversationDirectory(conversationID)
            .appendingPathComponent(turnID.uuidString + ".json")
    }

    private func persist(_ turn: TurnCheckpoint) {
        guard let data = try? JSONEncoder.iso8601Pretty.encode(turn) else { return }
        let url = turnFileURL(conversationID: turn.conversationID, turnID: turn.id)
        try? data.write(to: url, options: .atomic)
        if let mirror = projectMirrorRoot[turn.conversationID] {
            let mdir = mirror.appendingPathComponent(
                turn.conversationID.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: mdir, withIntermediateDirectories: true)
            let murl = mdir.appendingPathComponent(turn.id.uuidString + ".json")
            try? data.write(to: murl, options: .atomic)
        }
    }

    private func loadTurnFromDisk(conversationID: UUID, turnID: UUID) -> TurnCheckpoint? {
        let url = turnFileURL(conversationID: conversationID, turnID: turnID)
        guard let data = try? Data(contentsOf: url),
              let turn = try? JSONDecoder.iso8601.decode(TurnCheckpoint.self, from: data)
        else { return nil }
        turns[turnID] = turn
        return turn
    }

    private func loadLatestFromDisk(conversationID: UUID) -> TurnCheckpoint? {
        let dir = conversationDirectory(conversationID)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let jsons = files.filter { $0.pathExtension == "json" }
        guard !jsons.isEmpty else { return nil }
        let sorted = jsons.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return d0 < d1
        }
        guard let last = sorted.last,
              let data = try? Data(contentsOf: last),
              let turn = try? JSONDecoder.iso8601.decode(TurnCheckpoint.self, from: data)
        else { return nil }
        turns[turn.id] = turn
        var order = turnOrder[conversationID] ?? []
        if !order.contains(turn.id) {
            order.append(turn.id)
            turnOrder[conversationID] = order
        }
        return turn
    }
}
