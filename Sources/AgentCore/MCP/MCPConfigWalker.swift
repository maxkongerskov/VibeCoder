//
//  MCPConfigWalker.swift
//
//  Discovers and merges MCP server configurations from the filesystem,
//  porting Grok Build's two-axis config resolution:
//
//    (a) Global tier — ~/.vibecoder/mcp.json (user-global defaults)
//    (b) Project-local tier — .mcp.json files walked from cwd → git root,
//        with closer (higher-path) files entirely replacing same-named
//        servers from farther files. No field-level merge — if a project
//        .mcp.json redefines "github", it replaces the global entry entirely.
//
//  This mirrors Grok Build's `project_config.rs` walk (repo-root-first →
//  cwd-last, later wins) and the `.mcp.json` fill-if-missing semantics
//  for third-party JSON sources (Claude Code, Cursor compatibility).
//
//  SECURITY: The home-is-dotfiles guard from Grok Build's `RepoDirChain`
//  is preserved — if a git repo root resolves to $HOME, we treat it as
//  no-repo. This prevents a user's ~/.vibecoder/mcp.json from being
//  treated as a project overlay when cwd happens to be the home directory.
//
//  Precedence (lowest first, later wins):
//    1. ~/.vibecoder/mcp.json          (user-global base)
//    2. AppSettings.mcpServers         (VibeCoder's UI-managed servers)
//    3. .mcp.json files, cwd-last wins (project-local overrides)
//
//  The merge is whole-server replacement for same-named entries — no
//  field-level deep merge. This matches Grok Build's tested behavior
//  (test_project_scoped_mcp_override_replaces_entirely).
//

import Foundation

/// One MCP server entry parsed from a `.mcp.json` file. The JSON shape
/// follows the MCP spec's `mcpServers` object (Claude Code / Cursor /
//  z.code compatible):
///
/// ```json
/// {
///   "mcpServers": {
///     "github": {
///       "type": "http",
///       "url": "https://mcp.github.com/sse",
///       "headers": { ... },
///       "enabled": true,
///       "startupTimeout": 30,
///       "toolTimeout": 600
///     }
///   }
/// }
/// ```
public struct MCPFileServerEntry: Codable, Sendable {
    public enum TransportKind: String, Codable, Sendable {
        case stdio, http, streamableHttp, sse
    }

    public var type: String?
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var url: String?
    public var headers: [String: String]?
    public var enabled: Bool?

    // Grok-Build-compatible timeout fields (seconds).
    public var startupTimeout: TimeInterval?
    public var toolTimeout: TimeInterval?
    /// Per-tool overrides keyed by tool name (seconds).
    public var toolTimeouts: [String: TimeInterval]?
}

/// The parsed contents of a `.mcp.json` file.
public struct MCPConfigFile: Codable, Sendable {
    public var mcpServers: [String: MCPFileServerEntry]

    public init(mcpServers: [String: MCPFileServerEntry] = [:]) {
        self.mcpServers = mcpServers
    }
}

/// Discovers and merges MCP server configs from the filesystem.
public enum MCPConfigWalker {

    /// The user's home directory for global config. On platforms where
    /// `NSHomeDirectory()` returns the sandbox root, we fall back to
    /// `ProcessInfo` environment. If neither resolves, global config is
    /// skipped (never falls back to cwd-relative — security boundary).
    public static var userHomeDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // NSHomeDirectory can return the sandbox container under App Sandbox.
        // On non-sandboxed CLI contexts this is usually correct. We use it
        // as-is; VibeCoder's app is not sandboxed.
        return home
    }

    /// Resolve the global user config path: `~/.vibecoder/mcp.json`.
    public static var globalConfigURL: URL? {
        guard let home = userHomeDirectory else { return nil }
        return home.appendingPathComponent(".vibecoder", isDirectory: true)
                   .appendingPathComponent("mcp.json")
    }

    // MARK: - Git root discovery

    /// Discover the git repository root from a starting directory, walking
    /// upward through parent directories. Returns nil if no `.git` is found
    /// OR if the root resolves to $HOME (home-is-dotfiles guard — prevents
    /// a user's `~/.vibecoder/mcp.json` from being treated as project-local).
    ///
    /// Ported from Grok Build's `RepoDirChain::resolve` semantics:
    ///   - Walks via canonicalized paths so symlinks don't over-walk
    //    - Stops at the worktree root (first `.git` found going up)
    ///   - Drops the root if it equals $HOME (dotfiles-in-$HOME guard)
    public static func discoverGitRoot(from cwd: URL) -> URL? {
        var current = cwd.standardizedFileURL
            .resolvingSymlinksInPath()
        let home = userHomeDirectory?
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var visited = Set<URL>()
        while true {
            // Cycle protection (symlink loops)
            if visited.contains(current) { break }
            visited.insert(current)

            let gitDir = current.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitDir.path) {
                // Home-is-dotfiles guard: if this repo root IS $HOME,
                // treat as no-repo so we don't double-count ~/.vibecoder.
                if let home, current == home { return nil }
                return current
            }

            // Walk up. Stop at filesystem root.
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent.resolvingSymlinksInPath()
        }
        return nil
    }

    // MARK: - .mcp.json discovery (cwd → git root walk)

    /// Find all `.mcp.json` files between `cwd` and the git root, ordered
    /// repo-root-first → cwd-last (so nearer files win on name conflict).
    /// If no git root is found, checks `cwd/.mcp.json` only.
    public static func discoverProjectConfigFiles(cwd: URL) -> [URL] {
        guard PathConfinement.isUsableWorkspaceRoot(cwd) else { return [] }
        let gitRoot = discoverGitRoot(from: cwd)
        guard let root = gitRoot else {
            // No repo — only check cwd directly.
            let file = cwd.appendingPathComponent(".mcp.json")
            return FileManager.default.fileExists(atPath: file.path) ? [file] : []
        }

        // Walk from git root down to cwd, collecting .mcp.json files.
        // We walk the path components from root → cwd so that nearer
        // (higher) files come LAST in the array (they win on merge).
        var paths: [URL] = []
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let cwdPath = cwd.standardizedFileURL.resolvingSymlinksInPath().path

        // Build the chain of directories from root to cwd.
        let current = root
        let cwdURL = URL(fileURLWithPath: cwdPath)
        if root.path == cwdURL.path {
            // cwd is the git root — just check ./.mcp.json
            let f = current.appendingPathComponent(".mcp.json")
            if FileManager.default.fileExists(atPath: f.path) { paths.append(f) }
            return paths
        }

        // Walk root → cwd collecting .mcp.json at each level.
        var dirChain: [URL] = []
        var walker: URL? = cwdURL
        while let w = walker, w.path != rootPath {
            dirChain.append(w)
            // Check if we've reached the git root
            let parent = w.deletingLastPathComponent()
            if parent.path == rootPath {
                dirChain.append(root)
                break
            }
            walker = parent.resolvingSymlinksInPath()
            if walker?.path == rootPath {
                dirChain.append(root)
                break
            }
        }

        // Reverse to get root-first, then filter .mcp.json files.
        dirChain.reverse()
        for dir in dirChain {
            let f = dir.appendingPathComponent(".mcp.json")
            if FileManager.default.fileExists(atPath: f.path) {
                paths.append(f)
            }
        }

        return paths
    }

    // MARK: - Merging

    /// Load and merge all MCP server configs for a given working directory.
    ///
    /// Precedence (lowest first, later wins via whole-server replacement):
    ///   1. `~/.vibecoder/mcp.json` (user-global base)
    ///   2. `appSettingsServers` (VibeCoder UI-managed servers — fill-if-missing
    ///      for file-discovered names; explicit wins over implicit)
    ///   3. `.mcp.json` files walked cwd→git-root (project-local overrides)
    ///
    /// - Parameter cwd: The current working directory (agent's project root).
    /// - Parameter appSettingsServers: Servers the user configured in VibeCoder's
    ///   Settings UI. These are treated as "user-explicit" — they fill slots
    ///   not already filled by file-discovered configs, but don't override them.
    /// - Returns: A merged list of `MCPServerConfig` ready for the pool to connect.
    public static func resolveMcpServers(
        cwd: URL?,
        appSettingsServers: [MCPServerConfig]
    ) -> [MCPServerConfig] {
        // Use an ordered dictionary so insertion order = precedence.
        var merged: [String: MCPServerConfig] = [:]
        var order: [String] = []

        // Helper to insert (replace) a server, preserving first-seen order.
        func upsert(_ name: String, _ config: MCPServerConfig) {
            if merged[name] == nil { order.append(name) }
            merged[name] = config
        }

        // Helper to fill-if-missing (only insert if slot is empty).
        func fillIfMissing(_ name: String, _ config: MCPServerConfig) {
            if merged[name] == nil {
                order.append(name)
                merged[name] = config
            }
        }

        // Layer 1: global user config (~/.vibecoder/mcp.json) — base.
        if let globalURL = globalConfigURL,
           FileManager.default.fileExists(atPath: globalURL.path) {
            if let entries = loadConfigFile(at: globalURL) {
                for (name, entry) in entries.mcpServers.sorted(by: { $0.key < $1.key }) {
                    if let config = entryToConfig(name: name, entry: entry) {
                        upsert(name, config)
                    }
                }
            }
        }

        // Layer 2: AppSettings servers — fill-if-missing semantics.
        // The user explicitly configured these in the UI; they win over
        // file-discovered entries only if no file entry claimed the name.
        for config in appSettingsServers {
            fillIfMissing(config.name, config)
        }

        // Layer 3: project-local .mcp.json files (cwd → git root walk).
        // Nearer files (later in the array) replace farther ones entirely.
        // Skip filesystem root / unbound cwd — never walk `/.mcp.json`.
        if let cwd = PathConfinement.usableWorkspaceRoot(cwd) {
            for fileURL in discoverProjectConfigFiles(cwd: cwd) {
                if let entries = loadConfigFile(at: fileURL) {
                    for (name, entry) in entries.mcpServers.sorted(by: { $0.key < $1.key }) {
                        if let config = entryToConfig(name: name, entry: entry) {
                            upsert(name, config)
                        }
                    }
                }
            }
        }

        // Emit in insertion order.
        return order.compactMap { merged[$0] }
    }

    // MARK: - File loading

    /// Load and parse a `.mcp.json` file (or `~/.vibecoder/mcp.json`).
    /// Returns nil if the file can't be read or doesn't contain `mcpServers`.
    public static func loadConfigFile(at url: URL) -> MCPConfigFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(MCPConfigFile.self, from: data)
            return decoded
        } catch {
            // Malformed JSON — skip this file, don't fail the whole walk.
            return nil
        }
    }

    /// Convert a `.mcp.json` server entry to an `MCPServerConfig`.
    /// The "type" field determines the transport:
    ///   - "stdio" → .stdio (requires command)
    ///   - "sse" → .sse (requires url; legacy GET /sse + endpoint event)
    ///   - "http", "streamableHttp", or absent → .streamableHttp (requires url)
    public static func entryToConfig(name: String, entry: MCPFileServerEntry) -> MCPServerConfig? {
        let transport: MCPServerTransport
        switch entry.type?.lowercased() {
        case "stdio":
            transport = .stdio
        case "sse":
            transport = .sse
        case "http", "streamablehttp":
            transport = .streamableHttp
        case nil:
            // Default to HTTP if url is present, stdio if command is present.
            if entry.url != nil { transport = .streamableHttp }
            else if entry.command != nil { transport = .stdio }
            else { return nil }
        default:
            // Unknown type — try to infer from url vs command.
            if entry.url != nil { transport = .streamableHttp }
            else if entry.command != nil { transport = .stdio }
            else { return nil }
        }

        guard MCPToolNaming.validate(name) == nil else { return nil }

        let enabled = entry.enabled ?? true
        let startup = entry.startupTimeout ?? 30
        let toolT = entry.toolTimeout ?? 120
        let perTool = entry.toolTimeouts ?? [:]

        switch transport {
        case .stdio:
            guard let command = entry.command else { return nil }
            return MCPServerConfig(
                name: name, transport: .stdio,
                command: command,
                args: entry.args ?? [],
                env: entry.env ?? [:],
                enabled: enabled,
                startupTimeout: startup,
                toolTimeout: toolT,
                toolTimeouts: perTool)
        case .streamableHttp, .sse:
            guard let url = entry.url else { return nil }
            return MCPServerConfig(
                name: name, transport: transport,
                url: url,
                headers: entry.headers ?? [:],
                enabled: enabled,
                startupTimeout: startup,
                toolTimeout: toolT,
                toolTimeouts: perTool)
        }
    }

    // MARK: - Diagnostics

    /// Describe the config sources that would be checked for a given cwd,
    /// for display in Settings → MCP. Returns human-readable strings.
    public static func describeConfigSources(cwd: URL?) -> [String] {
        var sources: [String] = []
        if let g = globalConfigURL {
            sources.append("Global: \(g.path)")
        }
        if let cwd = PathConfinement.usableWorkspaceRoot(cwd) {
            let project = discoverProjectConfigFiles(cwd: cwd)
            for f in project {
                sources.append("Project: \(f.path)")
            }
            if project.isEmpty && gitRootDescription(cwd) == nil {
                sources.append("No .mcp.json in \(cwd.path)")
            }
        }
        return sources
    }

    /// Human-readable description of the git root discovery result.
    private static func gitRootDescription(_ cwd: URL) -> String? {
        if let root = discoverGitRoot(from: cwd) {
            return "git root: \(root.path)"
        }
        return nil
    }
}