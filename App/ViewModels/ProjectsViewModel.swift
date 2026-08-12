//
//  ProjectsViewModel.swift
//  AgentOS — Claude Edition
//
//  MainActor ObservableObject that bridges the `AgentCore.ProjectsService`
//  actor to the SwiftUI `ProjectsView`. Owns the actor handle, exposes a
//  `@Published [Project]` snapshot, and forwards UI actions
//  (create / rename / delete / refresh) to the actor.
//
//  Concurrency: methods that mutate are `async` and hop into the actor.
//  After each mutation we re-read `projects()` from the service and assign
//  the snapshot on MainActor, so SwiftUI sees a fresh array.
//
//  Persistence: the service is constructed with a `rootFolderURL` (the App
//  passes `~/Library/Application Support/AgentOS/Projects/`) and creates
//  the directory if missing. Each project = one subfolder there, so the
//  list survives across launches purely by virtue of the folder existing.
//
//  File-system watcher: `ProjectsService.startWatching` reloads when the
//  managed projects root changes on disk (external create/delete/rename).
//
//  Error UI is limited to a `@Published lastError` string plus
//  `Diagnostics.error` logging.
//

import Foundation
import Combine
import AgentCore

@MainActor
final class ProjectsViewModel: ObservableObject {

    // MARK: - Published state

    @Published var projects: [Project] = []

    /// Last user-visible error message, or `nil` if the most recent
    /// operation succeeded. Cleared on the next successful call.
    @Published var lastError: String? = nil

    // MARK: - Dependencies

    /// The AgentCore actor that owns the on-disk project list.
    private let service: ProjectsService

    // MARK: - Init

    /// - Parameter rootFolderURL: Directory that holds one sub-directory
    ///   per project. The service creates it on init if missing.
    init(rootFolderURL: URL = ProjectsViewModel.defaultRootFolderURL()) {
        // Ensure the directory exists up-front. `ProjectsService.init`
        // does this too, but doing it here means a non-default URL passed
        // by a test or preview also gets created without relying on the
        // actor's init side-effect.
        try? FileManager.default.createDirectory(
            at: rootFolderURL,
            withIntermediateDirectories: true
        )
        self.service = ProjectsService(rootURL: rootFolderURL)
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            await self.service.startWatching { [weak self] fresh in
                await MainActor.run {
                    self?.projects = fresh
                }
            }
        }
    }


    // MARK: - Default folder location

    /// `~/VibeCoder Projects/` (managed project folders home).
    static func defaultRootFolderURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(AppBranding.projectsFolderName, isDirectory: true)
    }

    // MARK: - Reads

    /// Re-read the current list from the actor and replace the snapshot.
    func refresh() async {
        let fresh = await service.projects()
        self.projects = fresh
    }

    // MARK: - Mutations

    /// Create a new project subfolder. On success the snapshot is
    /// reloaded so the new card appears immediately.
    func create(named name: String) async {
        _ = await createReturning(name)
    }

    /// The full "Start from scratch" path: create the folder (managed or
    /// at a chosen location), then seed it with the user's instructions
    /// and starter files. Seeding warnings (skipped files, etc.) are
    /// surfaced via `lastError` but never fail the creation.
    @discardableResult
    func createFromScratch(name: String, location: URL?,
                           instructions: String, files: [URL]) async -> Result<Project, ProjectsError> {
        let result: Result<Project, ProjectsError>
        if let location {
            result = await service.create(named: name, in: location)
        } else {
            result = await service.create(named: name)
        }
        if case .success(let project) = result {
            let warnings = await service.seed(at: project.url, instructions: instructions, fileURLs: files)
            lastError = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            if !warnings.isEmpty {
                Diagnostics.warn("ProjectsViewModel.createFromScratch seeding: \(warnings.joined(separator: "; "))")
            }
            await refresh()
        } else if case .failure(let err) = result {
            lastError = err.message
            Diagnostics.error("ProjectsViewModel.createFromScratch: \(err.message)")
        }
        return result
    }

    /// Register a folder the user already owns as an external project.
    /// This is the "Use an existing folder" path — AgentOS points at the
    /// folder in place and never copies or moves it.
    @discardableResult
    func register(folder url: URL) async -> Result<Project, ProjectsError> {
        let result = await service.register(existingFolder: url)
        await applyResult(result, context: "register-folder")
        return result
    }

    /// Shared success/error handling for the create/register paths.
    private func applyResult(_ result: Result<Project, ProjectsError>, context: String) async {
        switch result {
        case .success:
            lastError = nil
            await refresh()
        case .failure(let err):
            lastError = err.message
            Diagnostics.error("ProjectsViewModel.\(context): \(err.message)")
        }
    }

    /// Same as `create(named:)` but surfaces the underlying
    /// `Result<Project, ProjectsError>` so callers can branch on the
    /// freshly-created project — used by `MoveToProjectSheet` to
    /// create + bind the conversation in one gesture.
    @discardableResult
    func createReturning(_ name: String) async -> Result<Project, ProjectsError> {
        let result = await service.create(named: name)
        switch result {
        case .success:
            lastError = nil
            await refresh()
        case .failure(let err):
            lastError = err.message
            Diagnostics.error("ProjectsViewModel.create: \(err.message)")
        }
        return result
    }

    /// Rename a project. `ProjectsService.rename` moves the folder on
    /// disk and returns a fresh `Project` carrying the same `id` and
    /// `createdAt` but a new `name` + `url`. We re-read the snapshot
    /// rather than splicing the returned value in by hand so the
    /// service stays the single source of truth.
    /// Returns the updated project on success (folder URL may change for managed projects).
    @discardableResult
    func rename(_ project: Project, to newName: String) async -> Project? {
        let result = await service.rename(project, to: newName)
        switch result {
        case .success(let updated):
            lastError = nil
            await refresh()
            return updated
        case .failure(let err):
            lastError = err.message
            Diagnostics.error("ProjectsViewModel.rename: \(err.message)")
            return nil
        }
    }

    /// Delete a project — removes the folder from disk and reloads.
    func delete(_ project: Project) async {
        let result = await service.delete(project)
        switch result {
        case .success:
            lastError = nil
            await refresh()
        case .failure(let err):
            lastError = err.message
            Diagnostics.error("ProjectsViewModel.delete: \(err.message)")
        }
    }
}
