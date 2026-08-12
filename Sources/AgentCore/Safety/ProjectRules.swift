//
//  ProjectRules.swift
//
//  Hierarchical project rules: walk from repo root to cwd, collect
//  AGENTS.md / CLAUDE.md / Cursor rule files and rules directories;
//  nearer files win on conflict; inject with a hard length cap.
//
//  Wave B S8: always used on the live AgentLoop path (no root-only
//  AGENTS.md shadowing). Multi-convention names match Grok/Claude/Cursor.
//

import Foundation

public struct ProjectRulesSnapshot: Sendable {
    public let files: [(path: String, content: String)]
    public let injectedText: String
    public let truncated: Bool

    public init(files: [(path: String, content: String)], injectedText: String, truncated: Bool) {
        self.files = files
        self.injectedText = injectedText
        self.truncated = truncated
    }
}

public enum ProjectRules {

    /// Standalone instruction filenames checked in each directory (order is
    /// discovery order within a dir; later dirs in the root→cwd chain still
    /// appear later in the prompt and take precedence).
    ///
    /// Includes Claude Code and Cursor aliases so those repos “just work.”
    public static let defaultFileNames = [
        "AGENTS.md", "Agents.md", "agents.md", ".agents.md",
        "AGENT.md",
        "CLAUDE.md", "Claude.md", "CLAUDE.local.md",
        ".cursorrules",
    ]

    /// Nested files under each directory (Claude Code project memory layout).
    public static let defaultNestedFilePaths = [
        ".claude/CLAUDE.md",
        ".claude/CLAUDE.local.md",
    ]

    /// Directories of `*.md` rule files scanned at each level (alphabetical).
    public static let defaultRulesSubdirs = [
        ".claude/rules",
        ".cursor/rules",
        ".grok/rules",
        ".vibecoder/rules",
    ]

    /// Home-level rules dirs (lowest precedence; loaded before project chain).
    /// Relative to the user home directory.
    public static let defaultHomeRulesSubdirs = [
        ".vibecoder/rules",
        ".grok/rules",
        ".claude/rules",
        ".cursor/rules",
    ]

    /// Shared budget for all collected rule text in the system prompt.
    public static let defaultMaxChars = 8_000

    /// Load rules from `root` down to `cwd` (cwd must be under root when possible).
    /// Order: home rules → root → … → cwd (later entries override / append).
    ///
    /// Per directory: all matching standalone names + nested CLAUDE paths +
    /// `*.md` under rules subdirs. Case-insensitive path dedup (macOS APFS).
    public static func load(
        projectRoot: URL?,
        cwd: URL,
        fileNames: [String] = defaultFileNames,
        nestedFilePaths: [String] = defaultNestedFilePaths,
        rulesSubdirs: [String] = defaultRulesSubdirs,
        homeRulesSubdirs: [String] = defaultHomeRulesSubdirs,
        /// Off by default so unit tests / tight loads stay hermetic; AgentLoop
        /// and `ChatLoop.loadAgentsMd` pass true for production parity.
        includeHomeRules: Bool = false,
        maxChars: Int = defaultMaxChars,
        fileManager: FileManager = .default
    ) -> ProjectRulesSnapshot {
        let root = projectRoot ?? cwd
        let chain = directoryChain(from: root, to: cwd)
        var collected: [(String, String)] = []
        var seenPaths = Set<String>()

        // Home rules first (lowest precedence).
        if includeHomeRules {
            let home = fileManager.homeDirectoryForCurrentUser
            for sub in homeRulesSubdirs {
                let rulesDir = home.appendingPathComponent(sub, isDirectory: true)
                guard fileManager.fileExists(atPath: rulesDir.path) else { continue }
                for url in listMarkdownFiles(in: rulesDir, fileManager: fileManager) {
                    appendIfReadable(
                        url,
                        stripFrontmatter: true,
                        into: &collected,
                        seen: &seenPaths,
                        fileManager: fileManager)
                }
            }
            // Home-level CLAUDE.md / AGENTS.md (Claude Code / Grok home guidance).
            for name in ["AGENTS.md", "CLAUDE.md", "CLAUDE.local.md"] {
                appendIfReadable(
                    home.appendingPathComponent(name),
                    stripFrontmatter: false,
                    into: &collected,
                    seen: &seenPaths,
                    fileManager: fileManager)
            }
            appendIfReadable(
                home.appendingPathComponent(".claude/CLAUDE.md"),
                stripFrontmatter: false,
                into: &collected,
                seen: &seenPaths,
                fileManager: fileManager)
        }

        for dir in chain {
            for name in fileNames {
                appendIfReadable(
                    dir.appendingPathComponent(name),
                    stripFrontmatter: false,
                    into: &collected,
                    seen: &seenPaths,
                    fileManager: fileManager)
            }
            for rel in nestedFilePaths {
                appendIfReadable(
                    dir.appendingPathComponent(rel),
                    stripFrontmatter: false,
                    into: &collected,
                    seen: &seenPaths,
                    fileManager: fileManager)
            }
            for sub in rulesSubdirs {
                let rulesDir = dir.appendingPathComponent(sub, isDirectory: true)
                guard fileManager.fileExists(atPath: rulesDir.path) else { continue }
                let mdFiles = listMarkdownFiles(in: rulesDir, fileManager: fileManager)
                for url in mdFiles {
                    appendIfReadable(
                        url,
                        stripFrontmatter: true,
                        into: &collected,
                        seen: &seenPaths,
                        fileManager: fileManager)
                }
            }
        }

        // Nearest (last) files have highest precedence — list them last in prompt.
        var body = ""
        var truncated = false
        for (path, content) in collected {
            let header = "\n## Rules from \(path)\n"
            let piece = header + content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            if body.count + piece.count > maxChars {
                let remaining = max(0, maxChars - body.count - header.count - 32)
                if remaining > 80 {
                    body += header + String(content.prefix(remaining)) + "\n… [truncated]\n"
                }
                truncated = true
                break
            }
            body += piece
        }

        let injected: String
        if body.isEmpty {
            injected = ""
        } else {
            injected = """
            # Project rules (AGENTS.md / CLAUDE.md hierarchy; nearer paths override)
            Follow these instructions. When working in subdirectories not covered above, check for additional AGENTS.md / CLAUDE.md / rules files there.
            \(body)
            """
        }
        return ProjectRulesSnapshot(files: collected, injectedText: injected, truncated: truncated)
    }

    /// Directories from root to cwd inclusive.
    ///
    /// When `cwd` is under `root`, walks every intermediate directory.
    /// When `cwd` is **outside** `root` (git worktree siblings, external
    /// folders), still returns `[root, cwd]` so project-level AGENTS/CLAUDE
    /// are not dropped — previously returned only `[cwd]` and silently
    /// lost root rules in worktree mode.
    public static func directoryChain(from root: URL, to cwd: URL) -> [URL] {
        let rootPath = SafeModeConfig.normalizePath(root.path)
        let cwdPath = SafeModeConfig.normalizePath(cwd.path)
        if cwdPath == rootPath { return [root] }
        guard cwdPath.hasPrefix(rootPath + "/") else {
            // Outside root: keep both so monorepo/worktree still sees project rules.
            return [root, cwd]
        }
        var chain: [URL] = [root]
        let rel = String(cwdPath.dropFirst(rootPath.count + 1))
        var current = root
        for part in rel.split(separator: "/") where !part.isEmpty {
            current = current.appendingPathComponent(String(part))
            chain.append(current)
        }
        return chain
    }

    // MARK: - Helpers

    private static func dedupeKey(for url: URL) -> String {
        SafeModeConfig.normalizePath(url.path).lowercased()
    }

    private static func appendIfReadable(
        _ url: URL,
        stripFrontmatter: Bool,
        into collected: inout [(String, String)],
        seen: inout Set<String>,
        fileManager: FileManager
    ) {
        let key = dedupeKey(for: url)
        if seen.contains(key) { return }
        guard let data = fileManager.contents(atPath: url.path),
              var text = String(data: data, encoding: .utf8) else { return }
        if stripFrontmatter {
            text = stripYAMLFrontmatter(text)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        seen.insert(key)
        collected.append((url.path, trimmed))
    }

    /// Sorted `*.md` / `*.mdc` files directly under `dir` (not recursive).
    private static func listMarkdownFiles(in dir: URL, fileManager: FileManager) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "md" || ext == "mdc"
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Strip leading YAML frontmatter (`---` … `---`) used by Claude/Cursor rules.
    public static func stripYAMLFrontmatter(_ text: String) -> String {
        let trimmedStart = text
        guard trimmedStart.hasPrefix("---") else { return text }
        let lines = trimmedStart.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return text
        }
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                let rest = lines[(i + 1)...].joined(separator: "\n")
                return rest
            }
        }
        return text
    }
}
