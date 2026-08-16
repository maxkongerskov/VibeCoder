//
//  TerminalDockSupport.swift
//  Wave U3 — notification, persistence keys, cwd identity.
//

import Foundation

extension Notification.Name {
    /// View menu / palette — toggle the bottom terminal dock (⌘J).
    static let toggleTerminalRequested = Notification.Name("agentos.toggleTerminal")
}

enum TerminalDockStorage {
    static let visibilityKey = "vc.terminalDockVisible"
    static let visibilityDefault = false
    static let heightKey = "vc.terminalDockHeight"
    static let defaultHeight: Double = 200
    static let minHeight: Double = 120
    static let maxHeight: Double = 420

    static func clampHeight(_ value: Double) -> Double {
        min(maxHeight, max(minHeight, value))
    }
}

enum TerminalCwd {
    /// Selected conversation `worktreeRootURL ?? projectRoot`, else `fallback`.
    static func resolve(
        worktreeRoot: URL?,
        projectRoot: URL?,
        fallback: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let worktreeRoot { return worktreeRoot }
        if let projectRoot { return projectRoot }
        return fallback
    }

    /// Path-string identity used to decide whether the PTY must be recreated.
    static func identity(of url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func resolvedShell() -> String {
        let env = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if FileManager.default.isExecutableFile(atPath: env) { return env }
        if FileManager.default.isExecutableFile(atPath: "/bin/zsh") { return "/bin/zsh" }
        return "/bin/sh"
    }

    /// argv[0] for a login shell (`-zsh`).
    static func loginArgv0(forShell path: String) -> String {
        let base = URL(fileURLWithPath: path).lastPathComponent
        let name = base.isEmpty ? "zsh" : base
        return "-\(name)"
    }
}
