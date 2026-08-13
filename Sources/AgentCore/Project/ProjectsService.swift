//
//  ProjectsService.swift
//
//  The project list, backed by a small on-disk registry so a project can
//  point at a folder ANYWHERE on the machine — not just a sub-directory
//  of the managed root.
//
//  History: the original DEV PLAN service discovered projects purely by
//  scanning sub-directories of `~/AgentOSProjects/`. That made "use an
//  existing folder on my Desktop" impossible — an external folder isn't a
//  sub-directory of the managed root, so it vanished on the next scan.
//  (Observed 2026-06-10: New Project silently wrote into the managed root
//  regardless of the folder the user picked.) The registry fixes that:
//
//    • `.registry.json` in the managed root records every project as
//      {id, name, path, createdAt, isExternal}. Projects persist by being
//      in the registry, not by their location.
//    • MANAGED projects (created by us) live under the managed root.
//      Deleting one removes its folder.
//    • EXTERNAL projects point at a user-owned folder anywhere on disk.
//      We NEVER create or delete that folder — delete only unregisters,
//      rename only relabels. The user's files are theirs.
//    • Migration is automatic: on first load the registry is seeded by
//      scanning the managed root, so projects made before the registry
//      existed still appear.
//
//  Concurrency: `public actor`. All IO + cache mutation happen inside the
//  actor; callers `await`. An optional file-system watcher can be started
//  with `startWatching(onChange:)`.
//

import Foundation

// MARK: - Model

public struct Project: Identifiable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let url: URL
    public let createdAt: Date
    /// True when the folder lives outside the managed root — i.e. the user
    /// pointed AgentOS at a folder they already own. External folders are
    /// never created or deleted by AgentOS.
    public let isExternal: Bool

    public init(id: UUID = UUID(), name: String, url: URL,
                createdAt: Date, isExternal: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.createdAt = createdAt
        self.isExternal = isExternal
    }
}

public struct ProjectsError: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Service

public actor ProjectsService {

    public let rootURL: URL
    private let registryURL: URL
    private var cache: [Project] = []

    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: Int32 = -1

    /// - Parameter rootURL: Directory that holds managed project folders
    ///   AND the `.registry.json`. Created on init if missing. Production
    ///   uses `~/VibeCoder Projects`; tests pass a temp dir.
    public init(rootURL: URL? = nil) {
        if let custom = rootURL {
            self.rootURL = custom
        } else {
            self.rootURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(AppBranding.projectsFolderName, isDirectory: true)
        }
        self.registryURL = self.rootURL.appendingPathComponent(".registry.json")
        try? FileManager.default.createDirectory(at: self.rootURL,
                                                 withIntermediateDirectories: true)
        self.cache = Self.load(rootURL: self.rootURL, registryURL: self.registryURL)
        // Persist the merged/migrated set so the registry is authoritative
        // from here on.
        Self.save(self.cache, to: self.registryURL)
    }

    deinit {
        watcher?.cancel()
        if watcherFD >= 0 { close(watcherFD) }
    }

    // MARK: Public API

    public func projects() -> [Project] { cache }

    /// Re-load from the registry (re-running managed-folder migration).
    /// Temporarily missing folders are kept so unmounted volumes return.
    /// Returns the fresh list.
    @discardableResult
    public func reload() -> [Project] {
        cache = Self.load(rootURL: rootURL, registryURL: registryURL)
        Self.save(cache, to: registryURL)
        return cache
    }

    /// Create a new MANAGED project folder inside the root.
    @discardableResult
    public func create(named rawName: String) -> Result<Project, ProjectsError> {
        let name = Self.sanitize(rawName)
        guard !name.isEmpty else {
            return .failure(ProjectsError(message: "Project name cannot be empty."))
        }
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            return .failure(ProjectsError(message: "A project named \"\(name)\" already exists."))
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return .success(insert(Project(name: name, url: url, createdAt: Date(), isExternal: false)))
        } catch {
            return .failure(ProjectsError(message: "Couldn't create folder: \(error.localizedDescription)"))
        }
    }

    /// Create a new project folder named `rawName` INSIDE `location` (a
    /// folder the user picked). The new folder is external whenever
    /// `location` is outside the managed root — which is the whole point
    /// of letting the user choose where their project lives.
    @discardableResult
    public func create(named rawName: String, in location: URL) -> Result<Project, ProjectsError> {
        let name = Self.sanitize(rawName)
        guard !name.isEmpty else {
            return .failure(ProjectsError(message: "Project name cannot be empty."))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDir), isDir.boolValue else {
            return .failure(ProjectsError(message: "That location doesn't exist."))
        }
        let url = location.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            return .failure(ProjectsError(message: "A folder named \"\(name)\" already exists there."))
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return .success(insert(Project(name: name, url: url, createdAt: Date(),
                                           isExternal: isExternal(url))))
        } catch {
            return .failure(ProjectsError(message: "Couldn't create folder: \(error.localizedDescription)"))
        }
    }

    /// Register a folder the user already has as an EXTERNAL project.
    /// Idempotent: registering an already-known folder returns the
    /// existing entry rather than duplicating it. The folder is never
    /// modified.
    @discardableResult
    public func register(existingFolder url: URL, name: String? = nil) -> Result<Project, ProjectsError> {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return .failure(ProjectsError(message: "That folder doesn't exist."))
        }
        let key = url.standardizedFileURL.path
        if let existing = cache.first(where: { $0.url.standardizedFileURL.path == key }) {
            return .success(existing)
        }
        let label = Self.sanitize(name ?? url.lastPathComponent)
        let project = Project(name: label.isEmpty ? url.lastPathComponent : label,
                              url: url, createdAt: Date(), isExternal: isExternal(url))
        return .success(insert(project))
    }

    /// Rename a project. MANAGED projects move their folder on disk;
    /// EXTERNAL projects are only relabeled — the user's folder is never
    /// touched.
    @discardableResult
    public func rename(_ project: Project, to rawNewName: String) -> Result<Project, ProjectsError> {
        let newName = Self.sanitize(rawNewName)
        guard !newName.isEmpty else {
            return .failure(ProjectsError(message: "Project name cannot be empty."))
        }
        if newName == project.name { return .success(project) }

        if project.isExternal {
            let updated = Project(id: project.id, name: newName, url: project.url,
                                  createdAt: project.createdAt, isExternal: true)
            replace(updated)
            return .success(updated)
        }

        let newURL = rootURL.appendingPathComponent(newName, isDirectory: true)
        if FileManager.default.fileExists(atPath: newURL.path) {
            return .failure(ProjectsError(message: "A project named \"\(newName)\" already exists."))
        }
        do {
            try FileManager.default.moveItem(at: project.url, to: newURL)
            let updated = Project(id: project.id, name: newName, url: newURL,
                                  createdAt: project.createdAt, isExternal: false)
            replace(updated)
            return .success(updated)
        } catch {
            return .failure(ProjectsError(message: "Couldn't rename: \(error.localizedDescription)"))
        }
    }

    /// Delete a project. MANAGED projects have their folder removed from
    /// disk. EXTERNAL projects are only UNREGISTERED — the user's folder
    /// and its files are left exactly where they are.
    @discardableResult
    public func delete(_ project: Project) -> Result<Void, ProjectsError> {
        cache.removeAll { $0.id == project.id }
        persist()
        guard !project.isExternal else { return .success(()) }
        do {
            try FileManager.default.removeItem(at: project.url)
            return .success(())
        } catch {
            return .failure(ProjectsError(
                message: "Unregistered the project, but couldn't delete its folder: \(error.localizedDescription)"))
        }
    }

    // MARK: Seeding (instructions + starter files)

    /// Write standing `instructions` and copy `fileURLs` into a project
    /// folder. Used right after `create(...)` so the "New Project" sheet's
    /// Instructions field and Add Files picker actually take effect.
    /// Runs on the actor (off the main thread). Returns human-readable
    /// warnings for anything skipped (never throws — a failed seed must
    /// not undo a successfully created project).
    @discardableResult
    public func seed(at folder: URL, instructions: String, fileURLs: [URL]) -> [String] {
        Self.seedFolder(at: folder, instructions: instructions, fileURLs: fileURLs)
    }

    /// Pure seeding helper (static so tests don't need an actor). Writes
    /// `.agentos/instructions.md` when instructions are non-empty, and
    /// copies each file in, skipping any that already exist.
    @discardableResult
    public static func seedFolder(at folder: URL, instructions: String, fileURLs: [URL]) -> [String] {
        var warnings: [String] = []
        let fm = FileManager.default

        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let dir = folder.appendingPathComponent(".agentos", isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try trimmed.write(to: dir.appendingPathComponent("instructions.md"),
                                  atomically: true, encoding: .utf8)
            } catch {
                warnings.append("Couldn't write project instructions: \(error.localizedDescription)")
            }
        }

        for src in fileURLs {
            let dst = folder.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) {
                warnings.append("Skipped \(src.lastPathComponent) — a file with that name already exists.")
                continue
            }
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                warnings.append("Couldn't copy \(src.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return warnings
    }

    // MARK: File-system watcher

    public func startWatching(onChange: @escaping @Sendable ([Project]) async -> Void) {
        guard watcher == nil else { return }
        let fd = open(rootURL.path, O_EVTONLY)
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

    // MARK: Cache mutation (persist after every change)

    private func insert(_ project: Project) -> Project {
        cache.append(project)
        cache.sort { $0.createdAt > $1.createdAt }
        persist()
        return project
    }

    private func replace(_ project: Project) {
        if let idx = cache.firstIndex(where: { $0.id == project.id }) {
            cache[idx] = project
        } else {
            cache.append(project)
        }
        cache.sort { $0.createdAt > $1.createdAt }
        persist()
    }

    private func persist() { Self.save(cache, to: registryURL) }

    private func isExternal(_ url: URL) -> Bool {
        !url.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path + "/")
    }

    // MARK: Pure helpers

    private static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad: CharacterSet = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        return trimmed.components(separatedBy: bad).joined()
    }

    /// One level of `root`, one `Project` per managed sub-directory.
    /// Hidden entries (including `.registry.json`) are skipped.
    private static func scanManaged(root: URL) -> [Project] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { url in
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                return Project(name: url.lastPathComponent, url: url, createdAt: created, isExternal: false)
            }
    }

    /// Load the registry, keep entries even when the folder is temporarily
    /// missing (unmounted volume, renamed-back path), then merge in any
    /// managed sub-folders not yet recorded (migration for projects created
    /// before the registry existed). Sorted newest first.
    private static func load(rootURL: URL, registryURL: URL) -> [Project] {
        var byPath: [String: Project] = [:]

        if let data = try? Data(contentsOf: registryURL),
           let records = try? Self.decoder.decode([Record].self, from: data) {
            for r in records {
                let url = URL(fileURLWithPath: r.path)
                // Do not drop registry rows whose folder is gone right now —
                // save() would otherwise permanently forget an unmounted disk.
                byPath[url.standardizedFileURL.path] = Project(
                    id: r.id, name: r.name, url: url, createdAt: r.createdAt, isExternal: r.isExternal)
            }
        }

        for p in scanManaged(root: rootURL) {
            let key = p.url.standardizedFileURL.path
            if byPath[key] == nil { byPath[key] = p }
        }

        return Array(byPath.values).sorted { $0.createdAt > $1.createdAt }
    }

    private static func save(_ projects: [Project], to registryURL: URL) {
        let records = projects.map {
            Record(id: $0.id, name: $0.name, path: $0.url.path,
                   createdAt: $0.createdAt, isExternal: $0.isExternal)
        }
        guard let data = try? Self.encoder.encode(records) else { return }
        try? data.write(to: registryURL, options: .atomic)
    }

    // MARK: Persistence record

    /// On-disk shape. Stores the folder as a plain `path` string (not a
    /// `URL`) so the JSON stays human-readable and dodges URL's quirky
    /// Codable encoding.
    private struct Record: Codable {
        let id: UUID
        let name: String
        let path: String
        let createdAt: Date
        let isExternal: Bool
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
