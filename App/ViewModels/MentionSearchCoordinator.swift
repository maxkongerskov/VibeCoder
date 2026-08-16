//
//  MentionSearchCoordinator.swift
//
//  @MainActor mention autocomplete: owns debounce, generation coalescing,
//  and cache warmup so SwiftUI views only bind published state.
//
//  Triggers: `@` files/folders/symbols, `$` skills, `#` sessions.
//

import Foundation
import AgentCore

/// Composer token that opened the mention popup.
enum MentionTriggerKind: String, Sendable, Equatable {
    case at = "@"
    case skill = "$"
    case session = "#"
}

/// Kind of mention hit for the composer popup.
enum MentionCandidateKind: String, Sendable, Equatable {
    case file
    case folder
    case symbol
    case skill
    case session
}

/// Unified picker row (file / folder / symbol / skill / session).
struct MentionCandidate: Identifiable, Equatable, Sendable {
    var id: String { "\(kind.rawValue)|\(path)|\(displayName)|\(symbolName ?? "")" }
    let kind: MentionCandidateKind
    let path: String
    let relativePath: String
    let displayName: String
    /// Symbols: matched name. Skills: description (fallback pin text).
    let symbolName: String?
    let byteSize: Int?
    /// Second line in the popup.
    var subtitle: String {
        switch kind {
        case .file: return relativePath
        case .folder: return relativePath.isEmpty ? "folder" : "\(relativePath)/"
        case .symbol:
            let sym = symbolName ?? displayName
            return "\(sym) · \(relativePath)"
        case .skill:
            let src = relativePath.isEmpty ? "skill" : relativePath
            if let desc = symbolName, !desc.isEmpty {
                return "\(desc) · \(src)"
            }
            return src
        case .session:
            return relativePath.isEmpty ? path : relativePath
        }
    }

    var systemImage: String {
        switch kind {
        case .file: return "doc"
        case .folder: return "folder"
        case .symbol: return "function"
        case .skill: return "sparkles"
        case .session: return "bubble.left.and.bubble.right"
        }
    }

    init(kind: MentionCandidateKind,
         path: String,
         relativePath: String,
         displayName: String,
         symbolName: String? = nil,
         byteSize: Int? = nil) {
        self.kind = kind
        self.path = path
        self.relativePath = relativePath
        self.displayName = displayName
        self.symbolName = symbolName
        self.byteSize = byteSize
    }

    init(file: ProjectFileCandidate) {
        self.init(
            kind: .file,
            path: file.path,
            relativePath: file.relativePath,
            displayName: file.displayName,
            byteSize: file.byteSize
        )
    }

    init(skill: DiscoveredSkill) {
        let desc = skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            kind: .skill,
            path: skill.fileURL?.path ?? skill.name,
            relativePath: skill.source.rawValue,
            displayName: skill.name,
            symbolName: desc.isEmpty ? nil : desc
        )
    }

    init(session conv: Conversation, preview: String = "") {
        let trimmed = conv.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "Untitled" : trimmed
        let shortID = String(conv.id.uuidString.prefix(8)).lowercased()
        let flatPreview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let sub: String
        if flatPreview.isEmpty {
            sub = shortID
        } else {
            sub = "\(shortID) · \(flatPreview)"
        }
        self.init(
            kind: .session,
            path: conv.id.uuidString,
            relativePath: sub,
            displayName: display
        )
    }
}

@MainActor
final class MentionSearchCoordinator: ObservableObject {

    @Published private(set) var candidates: [MentionCandidate] = []
    @Published private(set) var showPopup = false
    /// Keyboard highlight index into `candidates` (↑/↓). Reset when results change.
    @Published private(set) var selectedIndex: Int = 0
    /// Which trigger opened the current popup (`@` / `$` / `#`).
    @Published private(set) var activeTriggerKind: MentionTriggerKind?

    /// Tunable for XCTest (defaults match production UX).
    var debounceNanosecondsWarm: UInt64 = 80_000_000
    var debounceNanosecondsCold: UInt64 = 150_000_000

    /// Max rows shown in the popup (mixed kinds).
    /// `nonisolated` so `searchAll` (background) can read it under Swift 6.
    nonisolated static let maxCandidates = 14

    private var searchGeneration = 0

    /// `@` only — emails like `user@example.com` are not mentions.
    nonisolated static func activeMentionQuery(in value: String) -> String? {
        // Only treat `@` as a mention if it starts a token (start of string
        // or after whitespace). The last `@` in `user@example.com` is not one.
        var search = value.endIndex
        while search > value.startIndex {
            search = value.index(before: search)
            guard value[search] == "@" else { continue }
            if search > value.startIndex {
                let prev = value[value.index(before: search)]
                if !prev.isWhitespace { continue }
            }
            let tail = value[search...]
            if tail.contains(where: { $0.isNewline }) { return nil }
            let afterAt = tail.dropFirst()
            if afterAt.contains(" ") { return nil }
            return String(afterAt)
        }
        return nil
    }

    /// Last `@` / `$` / `#` token that starts after whitespace (or BOS).
    /// Space ends the query; a newline in the token cancels it.
    nonisolated static func activeTrigger(in value: String) -> (kind: MentionTriggerKind, query: String)? {
        var search = value.endIndex
        while search > value.startIndex {
            search = value.index(before: search)
            let kind: MentionTriggerKind?
            switch value[search] {
            case "@": kind = .at
            case "$": kind = .skill
            case "#": kind = .session
            default: kind = nil
            }
            guard let kind else { continue }
            if search > value.startIndex {
                let prev = value[value.index(before: search)]
                if !prev.isWhitespace { continue }
            }
            let tail = value[search...]
            if tail.contains(where: { $0.isNewline }) { return nil }
            let after = tail.dropFirst()
            if after.contains(" ") { return nil }
            return (kind, String(after))
        }
        return nil
    }

    /// Drop a trailing `@…` / `$…` / `#…` token. Leaves emails intact.
    nonisolated static func stripActiveTriggerToken(from text: String) -> String {
        var text = text
        if let range = text.range(
            of: #"(?:(?<=^)|(?<=\s))[@$#][^\s\n]*$"#,
            options: .regularExpression
        ) {
            text.removeSubrange(range)
        }
        return text
    }

    func warm(root: URL) async {
        await ProjectFileIndex.warmCache(for: root)
    }

    func invalidate(root: URL) async {
        await ProjectFileIndex.invalidateCache(for: root)
    }

    func refresh(
        text: String,
        root: URL?,
        sessions: [Conversation] = [],
        currentID: UUID? = nil
    ) async {
        searchGeneration &+= 1
        let ticket = searchGeneration

        guard let trigger = Self.activeTrigger(in: text) else {
            candidates = []
            showPopup = false
            selectedIndex = 0
            activeTriggerKind = nil
            return
        }
        activeTriggerKind = trigger.kind

        switch trigger.kind {
        case .at:
            guard let root else {
                candidates = []
                showPopup = false
                selectedIndex = 0
                return
            }

            let warm = await ProjectFileIndex.isCacheWarm(for: root)
            if !warm {
                await ProjectFileIndex.warmCache(for: root)
            }
            guard ticket == searchGeneration else { return }

            let debounce = warm ? debounceNanosecondsWarm : debounceNanosecondsCold
            try? await Task.sleep(nanoseconds: debounce)
            guard ticket == searchGeneration else { return }

            let mixed = await Self.searchAll(query: trigger.query, root: root)
            guard ticket == searchGeneration else { return }
            publish(mixed)

        case .skill:
            try? await Task.sleep(nanoseconds: debounceNanosecondsWarm)
            guard ticket == searchGeneration else { return }
            let query = trigger.query
            let projectRoot = root
            let mixed = await Task.detached(priority: .utility) {
                Self.searchSkills(query: query, projectRoot: projectRoot)
            }.value
            guard ticket == searchGeneration else { return }
            publish(mixed)

        case .session:
            try? await Task.sleep(nanoseconds: debounceNanosecondsWarm)
            guard ticket == searchGeneration else { return }
            let query = trigger.query
            let snapshot = sessions
            let exclude = currentID
            let mixed = await Task.detached(priority: .utility) {
                Self.searchSessions(query: query, sessions: snapshot, currentID: exclude)
            }.value
            guard ticket == searchGeneration else { return }
            publish(mixed)
        }
    }

    func dismiss() {
        candidates = []
        showPopup = false
        selectedIndex = 0
        activeTriggerKind = nil
        searchGeneration &+= 1
    }

    private func publish(_ mixed: [MentionCandidate]) {
        candidates = mixed
        showPopup = !mixed.isEmpty
        selectedIndex = 0
    }

    // MARK: - Keyboard navigation (↑/↓/Enter/Esc)

    func moveSelection(by delta: Int) {
        guard showPopup, !candidates.isEmpty else { return }
        let count = candidates.count
        selectedIndex = (selectedIndex + delta + count) % count
    }

    func selectPrevious() { moveSelection(by: -1) }
    func selectNext() { moveSelection(by: 1) }

    /// Currently highlighted candidate, if any.
    var selectedCandidate: MentionCandidate? {
        guard showPopup, candidates.indices.contains(selectedIndex) else { return nil }
        return candidates[selectedIndex]
    }

    // MARK: - Search

    /// Files + folders + symbols under `root` matching `query`.
    nonisolated static func searchAll(query: String, root: URL) async -> [MentionCandidate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootStd = root.standardizedFileURL

        async let filesTask = ProjectFileIndex.searchAsync(query: needle, root: rootStd)
        let folders = await Task.detached(priority: .utility) {
            listFolders(query: needle, root: rootStd, limit: 6)
        }.value
        let symbols: [MentionCandidate]
        if needle.count >= 2 {
            symbols = await Task.detached(priority: .utility) {
                symbolCandidates(query: needle, root: rootStd, limit: 6)
            }.value
        } else {
            symbols = []
        }
        let files = await filesTask

        var out: [MentionCandidate] = []
        var seen = Set<String>()
        func push(_ c: MentionCandidate) {
            guard !seen.contains(c.id) else { return }
            seen.insert(c.id)
            out.append(c)
        }

        // Prefer files, then folders, then symbols — then fill to max.
        for f in files.prefix(8) { push(MentionCandidate(file: f)) }
        for f in folders { push(f) }
        for s in symbols { push(s) }

        return Array(out.prefix(maxCandidates))
    }

    /// Disk + bundled skills whose name or description contains `query`.
    nonisolated static func searchSkills(
        query: String,
        projectRoot: URL?,
        home: URL? = nil,
        includeBundled: Bool = true
    ) -> [MentionCandidate] {
        let skills = SkillDiscovery.discover(
            projectRoot: projectRoot,
            worktreeRoot: nil,
            includeBundled: includeBundled,
            home: home,
            metadataOnly: true
        )
        return filterSkills(skills, query: query)
    }

    nonisolated static func filterSkills(
        _ skills: [DiscoveredSkill],
        query: String,
        limit: Int = maxCandidates
    ) -> [MentionCandidate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out: [MentionCandidate] = []
        for skill in skills {
            if !needle.isEmpty {
                let nameHit = skill.name.lowercased().contains(needle)
                let descHit = skill.description.lowercased().contains(needle)
                guard nameHit || descHit else { continue }
            }
            out.append(MentionCandidate(skill: skill))
            if out.count >= limit { break }
        }
        return out
    }

    /// Non-archived sessions whose title or preview contains `query`.
    nonisolated static func searchSessions(
        query: String,
        sessions: [Conversation],
        currentID: UUID?,
        limit: Int = maxCandidates
    ) -> [MentionCandidate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ordered = sessions.sorted { $0.updatedAt > $1.updatedAt }
        var out: [MentionCandidate] = []
        for conv in ordered {
            if conv.archived { continue }
            if let currentID, conv.id == currentID { continue }
            let preview = sessionPreview(for: conv)
            let title = conv.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = title.isEmpty ? "Untitled" : title
            if !needle.isEmpty {
                let titleHit = display.lowercased().contains(needle)
                let previewHit = preview.lowercased().contains(needle)
                let idHit = conv.id.uuidString.lowercased().contains(needle)
                guard titleHit || previewHit || idHit else { continue }
            }
            out.append(MentionCandidate(session: conv, preview: preview))
            if out.count >= limit { break }
        }
        return out
    }

    /// First 72 chars of the last user/assistant body.
    nonisolated static func sessionPreview(for conv: Conversation) -> String {
        guard let msg = conv.messages.last(where: { $0.role == .user || $0.role == .assistant }) else {
            return ""
        }
        let flat = msg.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return "" }
        if flat.count <= 72 { return flat }
        return String(flat.prefix(72))
    }

    /// Directory names / paths matching the query (shallow-biased).
    nonisolated static func listFolders(query: String, root: URL, limit: Int) -> [MentionCandidate] {
        let needle = query.lowercased()
        let fm = FileManager.default
        var results: [MentionCandidate] = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        let rootPath = root.path + "/"
        let skip: Set<String> = [
            ".git", ".build", "DerivedData", "node_modules", ".swiftpm",
            "Pods", "Carthage", "Vendor"
        ]

        outer: for case let url as URL in enumerator {
            if results.count >= limit { break }
            guard let vals = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  vals.isDirectory == true else { continue }
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            for component in url.pathComponents where skip.contains(component) {
                enumerator.skipDescendants()
                continue outer
            }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath)
                ? String(path.dropFirst(rootPath.count))
                : path
            if !needle.isEmpty {
                let hit = relative.lowercased().contains(needle)
                    || name.lowercased().contains(needle)
                guard hit else { continue }
            }
            results.append(MentionCandidate(
                kind: .folder,
                path: path,
                relativePath: relative,
                displayName: name
            ))
        }
        return results.sorted {
            $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }
    }

    nonisolated static func symbolCandidates(query: String, root: URL, limit: Int) -> [MentionCandidate] {
        let hits = SymbolIndex.find(symbol: query, projectRoot: root, maxResults: limit)
        let rootPath = root.path + "/"
        return hits.map { hit in
            let path = hit.path
            let relative = path.hasPrefix(rootPath)
                ? String(path.dropFirst(rootPath.count))
                : path
            let name = URL(fileURLWithPath: path).lastPathComponent
            // Prefer symbol text from snippet when present.
            let snippet = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            let sym = extractSymbolName(from: snippet) ?? query
            return MentionCandidate(
                kind: .symbol,
                path: path,
                relativePath: relative,
                displayName: "\(sym) · \(name)",
                symbolName: sym
            )
        }
    }

    /// Best-effort extract `func Foo` / `class Foo` name from a snippet line.
    nonisolated static func extractSymbolName(from snippet: String) -> String? {
        let patterns = [
            #"\b(?:func|class|struct|enum|protocol|actor|extension|typealias)\s+(\w+)"#,
            #"\b(?:def|class|interface|type|const|let|var)\s+(\w+)"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: snippet, range: NSRange(snippet.startIndex..., in: snippet)),
               m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: snippet) {
                return String(snippet[r])
            }
        }
        return nil
    }
}
