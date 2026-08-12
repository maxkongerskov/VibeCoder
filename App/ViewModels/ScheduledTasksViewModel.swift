//
//  ScheduledTasksViewModel.swift
//  AgentOS — Claude Edition
//
//  Observable bridge between the AgentCore `ScheduledTaskStore` actor and
//  `TasksListView`. The store persists one JSON file per task under a
//  directory (default `~/Library/Application Support/AgentOS/scheduled`),
//  and this view model mirrors the current list into a `@Published`
//  array the SwiftUI view can render.
//
//  `ScheduledTask` does not carry an `archived` flag — archiving is a
//  per-conversation presentational concern in the App target, so the
//  archive set is persisted to a separate sidecar JSON file at
//  `~/Library/Application Support/AgentOS/scheduledTaskArchive.json`.
//
//  File-system watcher reloads when the scheduled-tasks directory changes
//  on disk (external create/delete).
//

import Foundation
import Combine
import AgentCore

@MainActor
final class ScheduledTasksViewModel: ObservableObject {

    // MARK: - Published state

    @Published var tasks: [ScheduledTask] = []
    /// Sidecar archive ids — `AgentCore.ScheduledTask` has no `archived`
    /// field, so the view tracks archived ids alongside and persists them
    /// to a separate JSON file. See file header.
    @Published var archivedIds: Set<UUID> = []
    /// Surfaced for the view if it wants to render a banner.
    @Published var lastError: String?

    // MARK: - Dependencies

    private let store: ScheduledTaskStore
    private let archiveFileURL: URL

    // MARK: - Init

    /// - Parameters:
    ///   - tasksDirectory: Folder the per-task JSON files live in. Defaults
    ///     to `~/Library/Application Support/VibeCoder/scheduledTasks/`.
    ///   - archiveFileURL: Sidecar file for the archived-ids set. Defaults
    ///     to `~/Library/Application Support/VibeCoder/scheduledTaskArchive.json`.
    init(tasksDirectory: URL? = nil,
         archiveFileURL: URL? = nil) {
        // Use the SAME canonical directory the boot-time SchedulerService
        // reads from (ScheduledTaskStore.defaultDirectory) so tasks created
        // here actually fire. They previously disagreed.
        let resolvedDirectory = tasksDirectory ?? ScheduledTaskStore.defaultDirectory()
        self.store = ScheduledTaskStore(directoryURL: resolvedDirectory)

        self.archiveFileURL = archiveFileURL
            ?? AppSupport.file("scheduledTaskArchive.json")

        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            await self.store.startWatching { [weak self] fresh in
                await MainActor.run {
                    self?.tasks = fresh
                }
            }
        }
    }


    // MARK: - Public API

    /// Reload tasks from disk and rehydrate the archive sidecar.
    func refresh() async {
        let fresh = await store.reload()
        self.tasks = fresh
        self.archivedIds = loadArchiveFromDisk()
    }

    /// Persist a new task and prepend into the in-memory list.
    func add(_ task: ScheduledTask) async {
        await store.add(task)
        let snapshot = await store.current()
        self.tasks = snapshot
    }

    /// Persist updates to an existing task and refresh the cache slot.
    func update(_ task: ScheduledTask) async {
        await store.update(task)
        let snapshot = await store.current()
        self.tasks = snapshot
    }

    /// Delete a task by value and drop its archive bit.
    func delete(_ task: ScheduledTask) async {
        await store.delete(task)
        let snapshot = await store.current()
        self.tasks = snapshot
        if archivedIds.contains(task.id) {
            archivedIds.remove(task.id)
            persistArchive()
        }
    }

    /// Convenience for the "Delete All" affordance — calls delete per task
    /// so the store's per-file storage stays consistent.
    func deleteAll() async {
        let snapshot = await store.current()
        for t in snapshot {
            await store.delete(t)
        }
        let after = await store.current()
        self.tasks = after
        if !archivedIds.isEmpty {
            archivedIds.removeAll()
            persistArchive()
        }
    }

    /// Delete a set of task ids. Used by "Delete Selected".
    func delete(ids: Set<UUID>) async {
        let snapshot = await store.current()
        for t in snapshot where ids.contains(t.id) {
            await store.delete(t)
        }
        let after = await store.current()
        self.tasks = after
        let intersected = archivedIds.intersection(ids)
        if !intersected.isEmpty {
            archivedIds.subtract(intersected)
            persistArchive()
        }
    }

    /// Flip the sidecar archive bit for a task and persist.
    func toggleArchived(_ task: ScheduledTask) {
        if archivedIds.contains(task.id) {
            archivedIds.remove(task.id)
        } else {
            archivedIds.insert(task.id)
        }
        persistArchive()
    }

    // MARK: - Archive sidecar

    private func loadArchiveFromDisk() -> Set<UUID> {
        guard let data = try? Data(contentsOf: archiveFileURL) else { return [] }
        if let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            return Set(ids)
        }
        return []
    }

    private func persistArchive() {
        let parent = archiveFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent,
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(Array(archivedIds).sorted { $0.uuidString < $1.uuidString })
            try data.write(to: archiveFileURL, options: .atomic)
        } catch {
            self.lastError = "Archive sidecar write failed: \(error.localizedDescription)"
            print("ScheduledTasksViewModel: archive write failed: \(error)")
        }
    }
}
