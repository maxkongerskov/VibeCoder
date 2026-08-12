//
//  ProjectMemoryFiles.swift
//  S4 — Read/write project-root MEMORY.md / DECISIONS.md for the UI editor.
//
//  These are the files ChatLoop.loadProjectMemory injects (project folder),
//  distinct from AppSupport workspace MEMORY under MemoryStorage.
//

import Foundation

/// Project-folder durable memory files (not AppSupport hash store).
public enum ProjectMemoryFileKind: String, Sendable, CaseIterable, Identifiable {
    case memory = "MEMORY.md"
    case decisions = "DECISIONS.md"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .memory: return "MEMORY.md"
        case .decisions: return "DECISIONS.md"
        }
    }

    public var help: String {
        switch self {
        case .memory:
            return "Long-term project notes. Auto-loaded into agent context when inject is on."
        case .decisions:
            return "Design decisions log (also written by the memory tool). Recent entries inject into the prompt."
        }
    }
}

public enum ProjectMemoryFiles {
    public static func url(kind: ProjectMemoryFileKind, projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(kind.rawValue, isDirectory: false)
    }

    public static func exists(kind: ProjectMemoryFileKind, projectRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(kind: kind, projectRoot: projectRoot).path)
    }

    /// Full file text, or empty string if missing / unreadable.
    public static func read(kind: ProjectMemoryFileKind, projectRoot: URL) -> String {
        let path = url(kind: kind, projectRoot: projectRoot)
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    /// Atomically write UTF-8 text. Creates parent directories if needed.
    public static func write(
        kind: ProjectMemoryFileKind,
        projectRoot: URL,
        text: String
    ) throws {
        let path = url(kind: kind, projectRoot: projectRoot)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Default scaffold when the user saves an empty new MEMORY.md.
    public static func defaultTemplate(kind: ProjectMemoryFileKind) -> String {
        switch kind {
        case .memory:
            return """
            # Memory

            Curated long-term notes for this project. The agent loads this file
            (tail-capped) when project memory inject is enabled.

            """
        case .decisions:
            return """
            # Design Decisions

            This file is maintained by the agent and the Memory settings editor.
            Each entry records a non-obvious design choice with its rationale.

            """
        }
    }
}
