//
//  InspectorPanelModel.swift
//
//  Pure workspace / Files / Changes / tab helpers for the right inspector.
//

import Foundation
import AgentCore

enum InspectorPanelTab: String, CaseIterable, Identifiable {
    case files
    case changes
    case subagents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .changes: return "Changes"
        case .subagents: return "Subagents"
        }
    }
}

enum InspectorVisibilityStore {
    static let key = "vc.inspectorVisible"
    static let defaultVisible = false

    /// `userInfo["visible"]` (Bool / NSNumber) or a Bool `object`.
    static func visible(from note: Notification) -> Bool? {
        if let value = note.userInfo?["visible"] as? Bool { return value }
        if let number = note.userInfo?["visible"] as? NSNumber { return number.boolValue }
        if let value = note.object as? Bool { return value }
        return nil
    }
}

enum InspectorWorkspace {
    /// Selected conversation `worktreeRootURL ?? projectRoot`, else opened project.
    static func projectRoot(conversation: Conversation?, openedProjectURL: URL?) -> URL? {
        if let conversation {
            if let worktree = conversation.worktreeRootURL { return worktree }
            if let project = conversation.projectRoot { return project }
        }
        return openedProjectURL
    }
}

enum InspectorFilesModel {
    static let emptyRootMessage = "No project folder — bind a project to see files."

    static func tree(from candidates: [ProjectFileCandidate]) -> [FileTreeNode] {
        FileTreeNode.build(from: candidates)
    }

    static func emptyMessage(projectRoot: URL?) -> String? {
        projectRoot == nil ? emptyRootMessage : nil
    }

    static func relativePath(for node: FileTreeNode) -> String {
        node.relativePath ?? node.id
    }

    static func fileURL(for node: FileTreeNode, root: URL) -> URL {
        root.appendingPathComponent(relativePath(for: node))
    }
}

struct InspectorFileChange: Identifiable, Equatable {
    let path: String
    let added: Int
    let removed: Int
    let status: TurnChangeSummary.FileChange.Status

    var id: String { TurnChangeSummary.pathKey(path) }

    var shortPath: String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count <= 2 { return path }
        return parts.suffix(3).joined(separator: "/")
    }
}

enum InspectorChangeAggregator {
    static let emptyMessage = "No file changes in this task yet."

    /// Same walk as ChatView (`TurnChangeSummary.summarizeEachTurn`).
    static func collect(from conversation: Conversation?) -> [TurnChangeSummary] {
        guard let conversation else { return [] }
        return TurnChangeSummary.summarizeEachTurn(in: conversation.messages)
    }

    /// Task-level rollup: first-seen path order, summed +/−, last status wins.
    static func files(in conversation: Conversation?) -> [InspectorFileChange] {
        var order: [String] = []
        var map: [String: InspectorFileChange] = [:]
        for summary in collect(from: conversation) {
            for file in summary.files {
                let key = TurnChangeSummary.pathKey(file.path)
                if let existing = map[key] {
                    map[key] = InspectorFileChange(
                        path: file.path,
                        added: existing.added + file.added,
                        removed: existing.removed + file.removed,
                        status: file.status
                    )
                } else {
                    order.append(key)
                    map[key] = InspectorFileChange(
                        path: file.path,
                        added: file.added,
                        removed: file.removed,
                        status: file.status
                    )
                }
            }
        }
        return order.compactMap { map[$0] }
    }

    /// Hunks from transcript tool arguments (no ChatView ownership).
    static func diffLines(in conversation: Conversation?) -> [String: [CodeDiffLine]] {
        guard let conversation else { return [:] }
        var map: [String: [CodeDiffLine]] = [:]
        let entries = CodeSessionBuilder.build(conversation: conversation, toolStates: [:])
        for entry in entries {
            guard case .fileEdit(let edit) = entry else { continue }
            let key = TurnChangeSummary.pathKey(edit.path)
            map[key, default: []].append(contentsOf: edit.lines)
        }
        return map
    }

    static func lines(for change: InspectorFileChange, in map: [String: [CodeDiffLine]]) -> [CodeDiffLine] {
        let key = TurnChangeSummary.pathKey(change.path)
        if let exact = map[key] { return exact }
        if let exact = map[change.path] { return exact }
        for (candidate, lines) in map {
            if TurnChangeSummary.pathKey(candidate) == key { return lines }
            if candidate.hasSuffix("/" + change.path) || change.path.hasSuffix("/" + candidate) {
                return lines
            }
        }
        return []
    }

    static func fileURL(for path: String, projectRoot: URL?) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        if path.hasPrefix("file://"), let url = URL(string: path) {
            return url
        }
        if let projectRoot {
            return projectRoot.appendingPathComponent(path)
        }
        return URL(fileURLWithPath: path)
    }
}
