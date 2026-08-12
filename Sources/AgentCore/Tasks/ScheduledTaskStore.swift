//
//  ScheduledTaskStore.swift
//
//  JSON-file persistence for scheduled tasks, one file per task at
//  `<directoryURL>/<uuid>.json`. Ported from the DEV PLAN's class-with-
//  singleton + `@unchecked Sendable` pattern into a proper `public actor`
//  for Swift 6 strict concurrency.
//
//  Errors during folder creation / directory scan / decode are logged
//  through `SessionLog` so corrupt files surface in the post-mortem trail
//  while valid tasks still load.
//

import Foundation

public actor ScheduledTaskStore {

    /// On-disk folder this store reads/writes. Exposed for the
    /// "Reveal in Finder" affordance.
    public let directoryURL: URL

    private let log: SessionLog?
    private var cache: [ScheduledTask] = []
    private var didInitialLoad = false
    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: Int32 = -1

    /// - Parameters:
    ///   - directoryURL: Directory the JSON files live in. Created on
    ///     demand. Production passes
    ///     `~/Library/Application Support/VibeCoder/scheduled`; tests pass
    ///     a temp dir.
    ///   - log: Where folder-creation / decode failures get reported.
    ///     Defaults to `SessionLog.shared`.
    public init(directoryURL: URL? = nil, log: SessionLog? = nil) {
        self.directoryURL = directoryURL ?? Self.defaultDirectory()
        self.log = log ?? SessionLog.shared
    }

    /// Canonical on-disk location for scheduled-task JSON files. BOTH the
    /// App's `ScheduledTasksViewModel` and the boot-time `SchedulerService`
    /// must use this — previously they disagreed (`scheduledTasks/` vs
    /// `scheduled/`), so the scheduler never saw tasks the UI created.
    public static func defaultDirectory() -> URL {
        AppSupport.directory("scheduledTasks")
    }

    // MARK: Public API

    /// Lazily reads the folder on first call, then returns the cached list.
    /// Call `reload()` to force a re-scan.
    public func load() async -> [ScheduledTask] {
        if !didInitialLoad {
            cache = await loadFromDiskSorted()
            didInitialLoad = true
        }
        return cache
    }

    /// Returns the cached list without re-scanning. Returns `[]` if
    /// `load()` has never been called.
    public func current() -> [ScheduledTask] { cache }

    /// Re-scan the folder. Returns the fresh list.
    @discardableResult
    public func reload() async -> [ScheduledTask] {
        cache = await loadFromDiskSorted()
        didInitialLoad = true
        return cache
    }

    /// Persist `task` atomically and refresh the cache slot in place.
    public func save(_ task: ScheduledTask) async {
        await ensureDirectory()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(task) {
            try? data.write(to: fileURL(for: task.id), options: .atomic)
        }
        // Update cache in place — caller doesn't need to call reload().
        if let idx = cache.firstIndex(where: { $0.id == task.id }) {
            cache[idx] = task
        } else {
            cache.insert(task, at: 0)
        }
    }

    /// Add a new task. Convenience over `save(_:)` that makes the
    /// "insert into cache" intent explicit.
    public func add(_ task: ScheduledTask) async {
        await save(task)
    }

    /// Update an existing task. Same effect as `save(_:)` — kept as a
    /// named method so callers can express intent.
    public func update(_ task: ScheduledTask) async {
        await save(task)
    }

    /// Lookup by id from the cache.
    public func task(id: UUID) -> ScheduledTask? {
        cache.first(where: { $0.id == id })
    }

    /// Delete a task by id.
    public func remove(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        cache.removeAll { $0.id == id }
    }

    /// Delete a task by value. Calls through to `remove(id:)`.
    public func delete(_ task: ScheduledTask) {
        remove(id: task.id)
    }

    // MARK: File-system watcher

    /// Watch `directoryURL` for external create/delete/rename and reload.
    public func startWatching(onChange: @escaping @Sendable ([ScheduledTask]) async -> Void) {
        guard watcher == nil else { return }
        // Ensure folder exists so open() succeeds.
        try? FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watcherFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                let fresh = await self.reload()
                await onChange(fresh)
            }
        }
        source.setCancelHandler { [weak self] in
            Task { [weak self] in await self?.closeWatcherFD() }
        }
        source.resume()
        watcher = source
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func closeWatcherFD() {
        if watcherFD >= 0 { close(watcherFD); watcherFD = -1 }
    }

    // MARK: Internals

    private func ensureDirectory() async {
        do {
            try FileManager.default.createDirectory(at: directoryURL,
                                                    withIntermediateDirectories: true)
        } catch {
            await log?.write("ScheduledTaskStore: folder creation failed at \(directoryURL.path): \(error)")
        }
    }

    private func loadFromDiskSorted() async -> [ScheduledTask] {
        await ensureDirectory()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil)
        } catch {
            await log?.write("ScheduledTaskStore: contentsOfDirectory failed at \(directoryURL.path): \(error)")
            return []
        }

        var tasks: [ScheduledTask] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let task = try dec.decode(ScheduledTask.self, from: data)
                tasks.append(task)
            } catch {
                await log?.write("ScheduledTaskStore: failed to load \(file.lastPathComponent): \(error)")
            }
        }
        return tasks.sorted { $0.createdAt > $1.createdAt }
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }
}
