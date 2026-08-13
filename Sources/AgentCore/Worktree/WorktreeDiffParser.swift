//
//  WorktreeDiffParser.swift
//
//  Pure parsers for `git status --short`, `git diff --numstat`, and
//  unified `git diff HEAD` output → structured worktree review rows.
//

import Foundation

public enum WorktreeDiffParser: Sendable {

    public enum ChangeKind: String, Sendable, Equatable {
        case modified
        case added
        case deleted
    }

    public enum LineKind: String, Sendable, Equatable {
        case context
        case added
        case removed
    }

    public struct DiffLine: Sendable, Equatable {
        public let kind: LineKind
        public let text: String
        public init(kind: LineKind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public struct FileChange: Sendable, Equatable {
        public let path: String
        public let kind: ChangeKind
        public let linesAdded: Int
        public let linesRemoved: Int
        public let diffLines: [DiffLine]

        public init(path: String,
                    kind: ChangeKind,
                    linesAdded: Int,
                    linesRemoved: Int,
                    diffLines: [DiffLine]) {
            self.path = path
            self.kind = kind
            self.linesAdded = linesAdded
            self.linesRemoved = linesRemoved
            self.diffLines = diffLines
        }
    }

    /// Build a review list from git command outputs.
    /// - Parameters:
    ///   - statusShort: `git status --short`
    ///   - numstat: `git diff --numstat HEAD` (and optionally `--cached`)
    ///   - unified: `git diff HEAD` (full unified diff)
    public static func parse(statusShort: String,
                             numstat: String,
                             unified: String) -> [FileChange] {
        let statusKinds = parseStatusShort(statusShort)
        let stats = parseNumstat(numstat)
        let hunks = parseUnifiedDiff(unified)

        // Union of paths from all sources (order: status, then numstat, then diff).
        var orderedPaths: [String] = []
        var seen = Set<String>()
        for path in statusKinds.keys.sorted() {
            if seen.insert(path).inserted { orderedPaths.append(path) }
        }
        for path in stats.keys.sorted() {
            if seen.insert(path).inserted { orderedPaths.append(path) }
        }
        for path in hunks.keys.sorted() {
            if seen.insert(path).inserted { orderedPaths.append(path) }
        }

        return orderedPaths.map { path in
            let kind = statusKinds[path] ?? inferKind(from: hunks[path] ?? [])
            let (add, del) = stats[path] ?? countLines(hunks[path] ?? [])
            return FileChange(
                path: path,
                kind: kind,
                linesAdded: add,
                linesRemoved: del,
                diffLines: hunks[path] ?? []
            )
        }
    }

    // MARK: - status --short

    /// Parses porcelain short status. First two columns are XY status.
    public static func parseStatusShort(_ raw: String) -> [String: ChangeKind] {
        var map: [String: ChangeKind] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            guard s.count >= 4 else { continue }
            // "XY path" or "XY orig -> path" for renames
            let xy = s.prefix(2)
            var pathPart = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if let arrow = pathPart.range(of: " -> ") {
                pathPart = String(pathPart[arrow.upperBound...])
            }
            // `git status --short` quotes paths that contain spaces:
            // `?? "my file.txt"` — strip wrapping quotes so review/UI paths resolve.
            pathPart = unquoteGitPath(pathPart)
            guard !pathPart.isEmpty else { continue }
            let kind: ChangeKind
            if xy.contains("A") || xy.contains("?") {
                kind = .added
            } else if xy.contains("D") {
                kind = .deleted
            } else {
                kind = .modified
            }
            map[pathPart] = kind
        }
        return map
    }

    // MARK: - numstat

    /// `added\tremoved\tpath` — binary shows `-` for counts.
    public static func parseNumstat(_ raw: String) -> [String: (Int, Int)] {
        var map: [String: (Int, Int)] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let add = Int(parts[0]) ?? 0
            let del = Int(parts[1]) ?? 0
            let path = destinationPathFromNumstat(parts[2])
            guard !path.isEmpty else { continue }
            map[path] = (add, del)
        }
        return map
    }

    /// Git rename numstat uses `old => new` or `prefix{old => new}suffix`.
    /// Counts belong to the destination path.
    static func destinationPathFromNumstat(_ raw: String) -> String {
        let path = raw.trimmingCharacters(in: .whitespaces)
        guard let arrow = path.range(of: " => ") else { return path }
        if let open = path.range(of: "{"),
           open.upperBound <= arrow.lowerBound,
           let close = path.range(of: "}", range: arrow.upperBound..<path.endIndex) {
            let prefix = String(path[..<open.lowerBound])
            let destMid = String(path[arrow.upperBound..<close.lowerBound])
            let suffix = String(path[close.upperBound...])
            return prefix + destMid + suffix
        }
        return String(path[arrow.upperBound...])
    }

    // MARK: - unified diff

    public static func parseUnifiedDiff(_ raw: String) -> [String: [DiffLine]] {
        var result: [String: [DiffLine]] = [:]
        var currentPath: String?
        var lines: [DiffLine] = []

        func flush() {
            if let p = currentPath {
                result[p] = lines
            }
            lines = []
            currentPath = nil
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flush()
                // diff --git a/foo b/foo
                if let bRange = line.range(of: " b/") {
                    currentPath = String(line[bRange.upperBound...])
                }
                continue
            }
            if line.hasPrefix("+++ b/") {
                currentPath = String(line.dropFirst("+++ b/".count))
                continue
            }
            if line.hasPrefix("+++ /dev/null") || line.hasPrefix("--- ") || line.hasPrefix("index ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                || line.hasPrefix("similarity") || line.hasPrefix("rename ") {
                continue
            }
            if line.hasPrefix("@@") {
                lines.append(DiffLine(kind: .context, text: line))
                continue
            }
            guard currentPath != nil else { continue }
            if line.hasPrefix("+") {
                lines.append(DiffLine(kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                lines.append(DiffLine(kind: .removed, text: String(line.dropFirst())))
            } else if line.hasPrefix(" ") {
                lines.append(DiffLine(kind: .context, text: String(line.dropFirst())))
            } else if line == "\\ No newline at end of file" {
                continue
            } else if !line.isEmpty {
                lines.append(DiffLine(kind: .context, text: line))
            }
        }
        flush()
        return result
    }

    private static func countLines(_ lines: [DiffLine]) -> (Int, Int) {
        var add = 0, del = 0
        for l in lines {
            switch l.kind {
            case .added: add += 1
            case .removed: del += 1
            case .context: break
            }
        }
        return (add, del)
    }

    private static func inferKind(from lines: [DiffLine]) -> ChangeKind {
        let hasAdd = lines.contains { $0.kind == .added }
        let hasDel = lines.contains { $0.kind == .removed }
        if hasAdd && !hasDel { return .added }
        if hasDel && !hasAdd { return .deleted }
        return .modified
    }

    /// Strip git short-status quoting (`"path with space"` / C-style escapes lightly).
    public static func unquoteGitPath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, s.first == "\"", s.last == "\"" {
            s = String(s.dropFirst().dropLast())
            s = s.replacingOccurrences(of: "\\\"", with: "\"")
            s = s.replacingOccurrences(of: "\\\\", with: "\\")
        }
        return s
    }

    /// Max lines loaded from disk for untracked/new files in the review sheet.
    public static let maxUntrackedPreviewLines = 400

    /// Fill empty `diffLines` for added/untracked paths by reading UTF-8 content.
    public static func enrichUntrackedContent(
        _ files: [FileChange],
        worktreeRoot: String,
        maxLines: Int = maxUntrackedPreviewLines,
        fileManager: FileManager = .default
    ) -> [FileChange] {
        let root = (worktreeRoot as NSString).expandingTildeInPath
        return files.map { change in
            guard change.kind == .added, change.diffLines.isEmpty else { return change }
            let path = change.path
            // Absolute path already, or relative to worktree.
            let url: URL
            if path.hasPrefix("/") {
                url = URL(fileURLWithPath: path)
            } else {
                url = URL(fileURLWithPath: root).appendingPathComponent(path)
            }
            guard let data = fileManager.contents(atPath: url.path),
                  !data.prefix(8192).contains(0),
                  let text = String(data: data, encoding: .utf8) else {
                return change
            }
            var rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var truncated = false
            if rawLines.count > maxLines {
                rawLines = Array(rawLines.prefix(maxLines))
                truncated = true
            }
            var diffLines = rawLines.map { DiffLine(kind: .added, text: $0) }
            if truncated {
                diffLines.append(DiffLine(kind: .context, text: "…[truncated untracked preview]"))
            }
            return FileChange(
                path: change.path,
                kind: .added,
                linesAdded: rawLines.count,
                linesRemoved: 0,
                diffLines: diffLines
            )
        }
    }
}
