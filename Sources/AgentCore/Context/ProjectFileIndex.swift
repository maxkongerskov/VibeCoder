//
//  ProjectFileIndex.swift
//
//  Lightweight project file search for @-mention autocomplete.
//

import Foundation

public struct ProjectFileCandidate: Sendable, Equatable {
    public let path: String
    public let relativePath: String
    public let displayName: String
    public let byteSize: Int?

    public init(path: String, relativePath: String, displayName: String, byteSize: Int? = nil) {
        self.path = path
        self.relativePath = relativePath
        self.displayName = displayName
        self.byteSize = byteSize
    }
}

private actor ProjectFileIndexCache {
    private var filesByRoot: [String: [ProjectFileCandidate]] = [:]

    func files(for root: URL) async -> [ProjectFileCandidate] {
        let key = root.standardizedFileURL.path
        if let cached = filesByRoot[key] { return cached }
        let rootCopy = root
        let indexed = await Task.detached(priority: .utility) {
            ProjectFileIndex.listFiles(root: rootCopy)
        }.value
        filesByRoot[key] = indexed
        return indexed
    }

    func invalidate(root: URL) {
        filesByRoot.removeValue(forKey: root.standardizedFileURL.path)
    }

    func isWarm(root: URL) -> Bool {
        filesByRoot[root.standardizedFileURL.path] != nil
    }
}

public enum ProjectFileIndex {

    public static let maxResults = 12
    public static let maxIndexedFiles = 5_000

    private static let cache = ProjectFileIndexCache()

    private static let skipDirectoryNames: Set<String> = [
        ".git", ".build", "DerivedData", "node_modules", ".swiftpm",
        "Pods", "Carthage", "Vendor", ".wrangler"
    ]

    private static let skipExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "ico", "pdf", "zip",
        "dmg", "app", "dylib", "o", "a", "framework"
    ]

    public static func search(query: String, root: URL) -> [ProjectFileCandidate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let files = listFiles(root: root.standardizedFileURL)
        return filter(files: files, needle: needle)
    }

    public static func searchAsync(query: String, root: URL) async -> [ProjectFileCandidate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let files = await cache.files(for: root.standardizedFileURL)
        return filter(files: files, needle: needle)
    }

    public static func invalidateCache(for root: URL) async {
        await cache.invalidate(root: root)
    }

    /// Pre-index project files on a background thread so the first `@` query
    /// does not block the main actor.
    public static func warmCache(for root: URL) async {
        _ = await cache.files(for: root.standardizedFileURL)
    }

    public static func isCacheWarm(for root: URL) async -> Bool {
        await cache.isWarm(root: root.standardizedFileURL)
    }

    /// Full project file listing for tree views (not capped to `maxResults`).
    public static func listAllFilesAsync(root: URL) async -> [ProjectFileCandidate] {
        await cache.files(for: root.standardizedFileURL)
    }

    private static func filter(files: [ProjectFileCandidate], needle: String) -> [ProjectFileCandidate] {
        let filtered: [ProjectFileCandidate]
        if needle.isEmpty {
            filtered = files
        } else {
            filtered = files.filter {
                $0.relativePath.lowercased().contains(needle)
                    || $0.displayName.lowercased().contains(needle)
            }
        }
        return Array(filtered.prefix(maxResults))
    }

    public static func listFiles(root: URL) -> [ProjectFileCandidate] {
        let fm = FileManager.default
        var results: [ProjectFileCandidate] = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isHiddenKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        let rootPath = root.path + "/"

        outer: for case let url as URL in enumerator {
            if results.count >= maxIndexedFiles { break }

            let name = url.lastPathComponent
            // Skip most dotfiles, but keep common project config the agent needs
            // via @-mention (C2 path/attachments UX).
            if name.hasPrefix(".") {
                let keepDot: Set<String> = [
                    ".env", ".env.local", ".env.example", ".gitignore", ".gitattributes",
                    ".editorconfig", ".swift-version", ".nvmrc", ".node-version",
                    ".eslintrc", ".eslintrc.js", ".eslintrc.cjs", ".prettierrc",
                    ".dockerignore", ".npmrc"
                ]
                if !keepDot.contains(name) { continue }
            }

            for component in url.pathComponents {
                if skipDirectoryNames.contains(component) {
                    // Only skip when this component is a directory we must not
                    // descend into. Avoid skipDescendants on a leaf file that
                    // merely sits under a skipped name (already filtered).
                    if let isDir = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                       isDir == true {
                        enumerator.skipDescendants()
                    }
                    continue outer
                }
            }

            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            if skipExtensions.contains(ext) { continue }

            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath)
                ? String(path.dropFirst(rootPath.count))
                : path
            let size = values.fileSize
            results.append(ProjectFileCandidate(
                path: path,
                relativePath: relative,
                displayName: name,
                byteSize: size
            ))
        }

        return results.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
    }
}