//
//  NoteStore.swift
//
//  JSON-file persistence for notes, one file per note at
//  `<baseDirectory>/notes/<uuid>.json`. Direct successor to the old
//  SkillStore — stripped of bundled-content seeding, restore hooks,
//  and the bundled-vs-user source distinction (every note is the
//  user's own).
//
//  An optional `DispatchSource.makeFileSystemObjectSource` watcher
//  fires the supplied callback whenever the notes folder changes, so
//  multi-window or external-editor scenarios keep the in-app list in
//  sync without polling.
//

import Foundation

public actor NoteStore {

    /// Process-wide default instance backed by
    /// `~/Library/Application Support/VibeCoder/notes/`. Used by the
    /// NotesViewModel; tests instantiate their own with a temp folder.
    /// Safe under Swift 6 strict concurrency because `NoteStore` is
    /// an actor — every access serialises through the executor.
    public static let shared = NoteStore()

    /// On-disk folder this store reads/writes. Exposed for the
    /// "Reveal in Finder" affordance.
    public let folderURL: URL

    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: Int32 = -1

    /// - Parameter folderURL: Directory the JSON files live in. Created on
    ///   init if missing. Production passes
    ///   `~/Library/Application Support/VibeCoder/notes`; tests pass a
    ///   temp dir.
    public init(folderURL: URL? = nil) {
        if let custom = folderURL {
            self.folderURL = custom
        } else {
            self.folderURL = AppSupport.directory("notes")
        }
        try? FileManager.default.createDirectory(at: self.folderURL,
                                                 withIntermediateDirectories: true)
    }

    deinit {
        watcher?.cancel()
        if watcherFD >= 0 { close(watcherFD) }
    }

    // MARK: Public API

    /// Persist a single note atomically. Used by create / edit flows.
    public func save(_ note: Note) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(note) else { return }
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: note.id), options: .atomic)
        } catch {
            Diagnostics.warn("NoteStore: failed to save note \(note.id.uuidString): \(error.localizedDescription)")
        }
    }

    /// Load every JSON file in the folder, sorted by `updatedAt` desc
    /// so the most-recently-edited note appears first.
    public func loadAll() -> [Note] {
        try? FileManager.default.createDirectory(at: folderURL,
                                                 withIntermediateDirectories: true)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { file -> Note? in
                guard let data = try? Data(contentsOf: file) else {
                    Diagnostics.warn("NoteStore: could not read note file \(file.path)")
                    return nil
                }
                guard let note = try? dec.decode(Note.self, from: data) else {
                    Diagnostics.warn("NoteStore: could not decode note file \(file.path)")
                    return nil
                }
                return note
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Re-scan the folder and return the fresh list.
    @discardableResult
    public func reload() -> [Note] { loadAll() }

    /// Public accessor for the in-memory list. Computed (no cache) —
    /// every call hits disk, which is fine for the note-folder size
    /// we expect (hand-authored, dozens to low-hundreds).
    public var notes: [Note] { loadAll() }

    /// Delete a note. All notes are user-owned, so there's no
    /// bundled-content guard (unlike the old SkillStore).
    public func delete(_ note: Note) {
        try? FileManager.default.removeItem(at: fileURL(for: note.id))
    }

    /// Delete every note. Triggered by the "Delete all" button in the
    /// Notes landing footer.
    public func deleteAll() {
        for note in loadAll() {
            delete(note)
        }
    }

    // MARK: File-system watcher

    /// Start watching `folderURL` for changes. On each event the
    /// callback fires with the fresh list. Returns immediately if a
    /// watcher is already running.
    public func startWatching(onChange: @escaping @Sendable ([Note]) async -> Void) {
        guard watcher == nil else { return }
        let fd = open(folderURL.path, O_EVTONLY)
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
                let fresh = await self.loadAll()
                await onChange(fresh)
            }
        }
        source.setCancelHandler { [weak self] in
            Task { [weak self] in
                await self?.closeWatcherFD()
            }
        }
        source.resume()
        watcher = source
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func closeWatcherFD() {
        if watcherFD >= 0 {
            close(watcherFD)
            watcherFD = -1
        }
    }

    // MARK: Helpers

    private func fileURL(for id: UUID) -> URL {
        folderURL.appendingPathComponent("\(id.uuidString).json")
    }
}
