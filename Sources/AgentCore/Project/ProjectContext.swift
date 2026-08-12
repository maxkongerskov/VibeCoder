//
//  ProjectContext.swift
//
//  Per-process active-project handle. The CLI sets it once on launch
//  from --project or pwd; the app sets it when a conversation binds to
//  a folder. Tools read it through the ToolContext that's plumbed
//  per-call, not through this singleton — but the singleton is the
//  fallback for surfaces that don't pass a context (the local API
//  server, for example).
//

import Foundation

public actor ProjectContext {
    public static let shared = ProjectContext()

    private var root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    public func setRoot(_ url: URL) {
        root = url.standardized
        Diagnostics.info("Project root set to \(root.path)")
    }

    public func currentRoot() -> URL { root }
}
