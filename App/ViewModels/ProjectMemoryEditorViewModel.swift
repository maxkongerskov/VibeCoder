//
//  ProjectMemoryEditorViewModel.swift
//  S4 — Load/edit/save project MEMORY.md and DECISIONS.md.
//

import Foundation
import Combine
import AgentCore

@MainActor
final class ProjectMemoryEditorViewModel: ObservableObject {
    @Published var kind: ProjectMemoryFileKind = .memory {
        didSet {
            if oldValue != kind { load() }
        }
    }
    @Published var draft: String = ""
    @Published private(set) var diskSnapshot: String = ""
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError: Bool = false
    @Published private(set) var fileExistsOnDisk: Bool = false

    /// Active project folder (conversation projectRoot or opened project).
    @Published var projectRoot: URL? {
        didSet {
            let oldPath = oldValue?.standardizedFileURL.path
            let newPath = projectRoot?.standardizedFileURL.path
            if oldPath != newPath { load() }
        }
    }

    var isDirty: Bool {
        draft != diskSnapshot
    }

    var fileURL: URL? {
        guard let root = projectRoot else { return nil }
        return ProjectMemoryFiles.url(kind: kind, projectRoot: root)
    }

    var relativePathLabel: String {
        kind.rawValue
    }

    func load() {
        statusMessage = nil
        statusIsError = false
        guard let root = projectRoot else {
            draft = ""
            diskSnapshot = ""
            fileExistsOnDisk = false
            return
        }
        fileExistsOnDisk = ProjectMemoryFiles.exists(kind: kind, projectRoot: root)
        let text = ProjectMemoryFiles.read(kind: kind, projectRoot: root)
        draft = text
        diskSnapshot = text
    }

    @discardableResult
    func save() -> Bool {
        statusMessage = nil
        statusIsError = false
        guard let root = projectRoot else {
            statusIsError = true
            statusMessage = "No project open — open a project or bind a conversation first."
            return false
        }
        var text = draft
        // First save of empty MEMORY/DECISIONS: seed a minimal template so inject has structure.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !fileExistsOnDisk {
            text = ProjectMemoryFiles.defaultTemplate(kind: kind)
            draft = text
        }
        do {
            try ProjectMemoryFiles.write(kind: kind, projectRoot: root, text: text)
            diskSnapshot = text
            fileExistsOnDisk = true
            statusIsError = false
            statusMessage = "Saved \(kind.rawValue)"
            return true
        } catch {
            statusIsError = true
            statusMessage = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    func revert() {
        draft = diskSnapshot
        statusMessage = nil
        statusIsError = false
    }

    func insertTemplateIfEmpty() {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = ProjectMemoryFiles.defaultTemplate(kind: kind)
        }
    }
}
