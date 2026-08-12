//
//  MentionSearchCoordinator.swift
//
//  @MainActor mention autocomplete: owns debounce, generation coalescing,
//  and cache warmup so SwiftUI views only bind published state.
//
//  S1: candidates include files, folders, and symbols (SymbolIndex text scan).
//

import Foundation
import AgentCore

/// Kind of @-mention hit for the composer popup.
enum MentionCandidateKind: String, Sendable, Equatable {
    case file
    case folder
    case symbol
}

/// Unified @-picker row (file / folder / symbol).
struct MentionCandidate: Identifiable, Equatable, Sendable {
    var id: String { "\(kind.rawValue)|\(path)|\(displayName)|\(symbolName ?? "")" }
    let kind: MentionCandidateKind
    let path: String
    let relativePath: String
    let displayName: String
    /// For symbols: the matched symbol name (optional).
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
        }
    }

    var systemImage: String {
        switch kind {
        case .file: return "doc"
        case .folder: return "folder"
        case .symbol: return "function"
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
}

@MainActor
final class MentionSearchCoordinator: ObservableObject {

    @Published private(set) var candidates: [MentionCandidate] = []
    @Published private(set) var showPopup = false
    /// Keyboard highlight index into `candidates` (↑/↓). Reset when results change.
    @Published private(set) var selectedIndex: Int = 0

    /// Tunable for XCTest (defaults match production UX).
    var debounceNanosecondsWarm: UInt64 = 80_000_000
    var debounceNanosecondsCold: UInt64 = 150_000_000

    /// Max rows shown in the popup (mixed kinds).
    /// `nonisolated` so `searchAll` (background) can read it under Swift 6.
    nonisolated static let maxCandidates = 14

    private var searchGeneration = 0

    static func activeMentionQuery(in value: String) -> String? {
        guard let atRange = value.range(of: "@", options: .backwards) else { return nil }
        let tail = value[atRange.lowerBound...]
        if tail.contains(where: { $0.isNewline }) { return nil }
        let afterAt = tail.dropFirst()
        if afterAt.contains(" ") { return nil }
        return String(afterAt)
    }

    func warm(root: URL) async {
        await ProjectFileIndex.warmCache(for: root)
    }

    func invalidate(root: URL) async {
        await ProjectFileIndex.invalidateCache(for: root)
    }

    func refresh(text: String, root: URL?) async {
        searchGeneration &+= 1
        let ticket = searchGeneration

        guard let query = Self.activeMentionQuery(in: text) else {
            candidates = []
            showPopup = false
            selectedIndex = 0
            return
        }
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

        let mixed = await Self.searchAll(query: query, root: root)
        guard ticket == searchGeneration else { return }

        candidates = mixed
        showPopup = !mixed.isEmpty
        selectedIndex = 0
    }

    func dismiss() {
        candidates = []
        showPopup = false
        selectedIndex = 0
        searchGeneration &+= 1
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
