//
//  Tool.swift
//
//  The single-protocol tool system that replaces the original AgentOS's
//  6-file registration checklist. A new tool is one file: declare a type
//  conforming to `Tool`, add `register(MyTool.self)` to the registry's
//  `registerBuiltins()` call, and you're done.
//
//  See DESIGN.md §6 for the rationale.
//

import Foundation

public enum ToolCategory: String, Sendable, Codable, CaseIterable {
    case filesystem, shell, git, build, web, planning, memory, agent, search, debug
}

public enum ToolPermission: Sendable, Codable, Equatable {
    /// Always safe; doesn't touch the filesystem outside the project.
    case readOnly
    /// Mutates files under the active project root or worktree.
    case mutates
    /// Runs arbitrary shell commands.
    case executes
    /// Reaches outbound to the network.
    case network
}

public enum ToolAvailability: Sendable, Codable {
    /// Always shipped in the tool schemas.
    case core
    /// Hidden behind `tool_search`. Revealed lazily so small models
    /// aren't drowned in 30+ schemas at once.
    case deferred
    /// Available only when the host can satisfy a precondition (e.g.,
    /// LSP installed, Xcode toolchain present).
    case platformGated(check: @Sendable () async -> Bool)

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .core: try c.encode("core")
        case .deferred: try c.encode("deferred")
        case .platformGated: try c.encode("platformGated")
        }
    }
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "core": self = .core
        case "deferred": self = .deferred
        case "platformGated": self = .deferred   // can't restore the closure — fail closed (hidden) rather than silently .core
        default: self = .deferred
        }
    }
}

/// JSON-schema-compatible representation of a tool's parameters. We
/// keep the shape OpenAI-shaped because every HTTP backend speaks that
/// dialect and the MLX adapter normalizes to the same form.
public struct ToolSchema: Sendable, Codable {
    public let name: String
    public let description: String
    public let parameters: Parameters

    public init(name: String, description: String, parameters: Parameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public struct Parameters: Sendable, Codable {
        public let type: String           // always "object"
        public let properties: [String: Property]
        public let required: [String]

        public init(properties: [String: Property], required: [String] = []) {
            self.type = "object"
            self.properties = properties
            self.required = required
        }
    }

    public struct Property: Sendable, Codable {
        public let type: String           // "string" | "integer" | "number" | "boolean" | "array" | "object"
        public let description: String
        public let `enum`: [String]?
        public let items: ItemSpec?

        public init(type: String, description: String, `enum`: [String]? = nil, items: ItemSpec? = nil) {
            self.type = type
            self.description = description
            self.enum = `enum`
            self.items = items
        }
    }

    public struct ItemSpec: Sendable, Codable {
        public let type: String
        public init(type: String) { self.type = type }
    }
}

/// Arguments passed to a tool at dispatch time. Backed by a JSON object;
/// helpers read typed values out.
///
/// `@unchecked Sendable`: the underlying [String: Any] is mutable in
/// principle but we treat it as read-only after init. Tools must not
/// mutate `raw`. This keeps the storage simple — alternatives (JSONValue
/// enum) added too much rote conversion code for the value they
/// provided in P0.
public struct ToolArguments: @unchecked Sendable {
    public let raw: [String: Any]

    public init(json: String) throws {
        guard let data = json.data(using: .utf8) else {
            throw ToolError.invalidArguments("Could not encode JSON as UTF-8: \(json.prefix(200))")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            // Malformed JSON. Re-throw as a ToolError so callers don't get
            // a raw NSCocoaError 3840 leaking out of the tool boundary.
            throw ToolError.invalidArguments("Could not parse JSON: \(json.prefix(200))")
        }
        guard let obj = parsed as? [String: Any] else {
            throw ToolError.invalidArguments("Expected JSON object, got: \(json.prefix(200))")
        }
        self.raw = obj
    }

    public init(dictionary: [String: Any]) {
        self.raw = dictionary
    }

    public func string(_ key: String) throws -> String {
        guard let v = raw[key] as? String else { throw ToolError.invalidArguments("Missing string '\(key)'") }
        return v
    }
    public func stringOptional(_ key: String) -> String? { raw[key] as? String }
    /// Integer access. Accepts JSON ints and integral/fractional doubles
    /// (truncating toward zero). Doubles whose truncated value cannot be
    /// represented as `Int` (e.g. a model emitting `1e20`) throw /
    /// return nil instead of trapping `Int(Double)` — same crash class
    /// already fixed in `MCPStdioClient` and `ArgumentCoercer`.
    public func int(_ key: String) throws -> Int {
        if let v = raw[key] as? Int { return v }
        if let v = raw[key] as? Double, v.isFinite,
           v >= Double(Int.min), v < Double(Int.max) {
            return Int(v)
        }
        throw ToolError.invalidArguments(
            "Missing or unrepresentable integer '\(key)': \(String(describing: raw[key]).prefix(40))")
    }
    public func intOptional(_ key: String) -> Int? {
        if let v = raw[key] as? Int { return v }
        guard let v = raw[key] as? Double, v.isFinite,
              v >= Double(Int.min), v < Double(Int.max) else { return nil }
        return Int(v)
    }
    public func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        if let b = raw[key] as? Bool { return b }
        // Models often emit JSON *strings* "true"/"false" (and sometimes "1"/"0").
        // Do **not** coerce raw JSON numbers — numeric 1 must not become true
        // (avoids accidental flags from integer args). Schema-level coercers
        // in Harness may still rewrite values before they reach here.
        if let s = raw[key] as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: break
            }
        }
        return defaultValue
    }
    public func stringArray(_ key: String) -> [String] {
        raw[key] as? [String] ?? []
    }
}

/// Context the registry hands every tool at dispatch time. Holds the
/// active project root, the worktree branch if any, permission mode,
/// and a reference to the conversation for memory-related tools.
public struct ToolContext: Sendable {
    public let projectRoot: URL?
    public let worktreeRoot: URL?         // if worktree mode is active
    public let safeMode: SafeModeConfig?
    public let conversationID: UUID
    /// Optional gate the host app installs so mutating tools can show
    /// the user what they're about to do before writing to disk. When
    /// non-nil, `ApplyPatchTool` builds per-file previews and awaits
    /// the reviewer's decision in place of an unconditional write.
    public let patchReviewer: PatchReviewer?
    public let userQuestionReviewer: UserQuestionReviewer?
    /// Optional host gate for `exit_plan_mode`. When nil, the tool
    /// auto-approves (same as today). When set, the tool awaits Approve.
    public let planApprovalReviewer: PlanApprovalReviewer?
    /// Interactive Once/Always/Never for shell / MCP / executes `.ask`.
    /// When nil, those asks hard-deny (headless / fail-closed). Wave B S4.
    public let shellApprovalCoordinator: ShellApprovalCoordinator?

    /// Compatibility name for sites that still call the handle a "reviewer".
    public var shellApprovalReviewer: ShellApprovalReviewer? {
        shellApprovalCoordinator
    }

    /// Parent agent backend — required for the `task` (subagent) tool.
    public let inferenceBackend: (any InferenceBackend)?
    /// Parent model — subagents inherit this unless overridden later.
    public let model: ModelDescriptor?
    /// Nesting depth: 0 = top-level agent, 1 = first subagent (max).
    public let subagentDepth: Int
    /// Active execution mode from the input-card chip (plan/ask/auto/full).
    public let executionMode: ExecutionMode?
    /// Authorization rules + optional inline remembered grants (tests).
    public let authorization: AuthorizationConfig
    /// Paths read this session (for read-before-edit guard). Absolute.
    public let sessionReadPaths: Set<String>
    /// Optional override for the session plan file (defaults under .agentos/plans/).
    public let sessionPlanFileURL: URL?
    /// PreToolUse hook denials (hooks stub).
    public let preToolHookDenials: [PreToolHookDenial]?
    /// When true, plan mode has been exited/approved for this turn.
    public let planModeExited: Bool
    /// Tools the user disabled in Settings — subagents must honor this too.
    public let disabledToolNames: Set<String>

    public var workingDirectory: URL {
        worktreeRoot ?? projectRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// Project/worktree root safe for durable writes and project-tier config.
    /// Nil when unbound or when the only fallback would be filesystem root.
    public var usableWorkspaceRoot: URL? {
        PathConfinement.usableWorkspaceRoot(worktree: worktreeRoot, project: projectRoot)
    }

    public init(projectRoot: URL?, worktreeRoot: URL? = nil,
                safeMode: SafeModeConfig? = nil,
                patchReviewer: PatchReviewer? = nil,
                userQuestionReviewer: UserQuestionReviewer? = nil,
                planApprovalReviewer: PlanApprovalReviewer? = nil,
                shellApprovalCoordinator: ShellApprovalCoordinator? = nil,
                shellApprovalReviewer: ShellApprovalReviewer? = nil,
                conversationID: UUID,
                inferenceBackend: (any InferenceBackend)? = nil,
                model: ModelDescriptor? = nil,
                subagentDepth: Int = 0,
                executionMode: ExecutionMode? = nil,
                authorization: AuthorizationConfig = .empty,
                sessionReadPaths: Set<String> = [],
                sessionPlanFileURL: URL? = nil,
                preToolHookDenials: [PreToolHookDenial]? = nil,
                planModeExited: Bool = false,
                disabledToolNames: Set<String> = []) {
        self.projectRoot = projectRoot
        self.worktreeRoot = worktreeRoot
        self.safeMode = safeMode
        self.patchReviewer = patchReviewer
        self.userQuestionReviewer = userQuestionReviewer
        self.planApprovalReviewer = planApprovalReviewer
        // Coordinator and reviewer are the same concrete type (typealias).
        self.shellApprovalCoordinator = shellApprovalCoordinator ?? shellApprovalReviewer
        self.conversationID = conversationID
        self.inferenceBackend = inferenceBackend
        self.model = model
        self.subagentDepth = subagentDepth
        // After plan exit, treat as Auto for authorization even if chip still says plan briefly.
        self.executionMode = planModeExited && executionMode == .plan ? .edit : executionMode
        self.authorization = authorization
        self.sessionReadPaths = sessionReadPaths
        if let sessionPlanFileURL {
            self.sessionPlanFileURL = sessionPlanFileURL
        } else if let root = PathConfinement.usableWorkspaceRoot(
            worktree: worktreeRoot, project: projectRoot
        ) {
            self.sessionPlanFileURL = ToolAuthorization.sessionPlanURL(
                workingDirectory: root, conversationID: conversationID)
        } else {
            self.sessionPlanFileURL = nil
        }
        self.preToolHookDenials = preToolHookDenials
        self.planModeExited = planModeExited
        self.disabledToolNames = disabledToolNames
    }

    /// Copy this context after `exit_plan_mode` extras (loop integrator).
    public func replacing(executionMode: ExecutionMode?, planModeExited: Bool) -> ToolContext {
        ToolContext(
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            safeMode: safeMode,
            patchReviewer: patchReviewer,
            userQuestionReviewer: userQuestionReviewer,
            planApprovalReviewer: planApprovalReviewer,
            shellApprovalCoordinator: shellApprovalCoordinator,
            conversationID: conversationID,
            inferenceBackend: inferenceBackend,
            model: model,
            subagentDepth: subagentDepth,
            executionMode: executionMode,
            authorization: authorization,
            sessionReadPaths: sessionReadPaths,
            sessionPlanFileURL: sessionPlanFileURL,
            preToolHookDenials: preToolHookDenials,
            planModeExited: planModeExited,
            disabledToolNames: disabledToolNames
        )
    }
}

public struct SafeModeConfig: Sendable {
    public let allowedPathPrefixes: [String]
    public let allowedShellPrefixes: [String]

    public init(allowedPathPrefixes: [String], allowedShellPrefixes: [String]) {
        self.allowedPathPrefixes = allowedPathPrefixes
        self.allowedShellPrefixes = allowedShellPrefixes
    }

    // MARK: - Plan/Ask auto-SafeMode reconcile (Wave B S10a)

    /// Ensure open project / worktree roots appear on the path allow-list.
    ///
    /// Plan and Ask auto-enable Safe Mode with defaults like `~/code/` that
    /// often exclude the real project (e.g. `~/Developer/…`). Path confinement
    /// already requires in-project writes; without seeding, Safe Mode then
    /// double-denies legitimate session plan files and Ask-mode edits.
    public func includingProjectRoots(_ roots: [URL]) -> SafeModeConfig {
        var paths = allowedPathPrefixes
        var seen = Set(paths.map { Self.normalizePath($0) }.filter { !$0.isEmpty })
        for root in roots {
            let norm = Self.normalizePath(root.path)
            guard !norm.isEmpty, !seen.contains(norm) else { continue }
            paths.append(root.path)
            seen.insert(norm)
        }
        return SafeModeConfig(
            allowedPathPrefixes: paths,
            allowedShellPrefixes: allowedShellPrefixes
        )
    }

    /// Union extra shell prefixes (de-duped, order preserved: existing first).
    public func unioningShellPrefixes(_ prefixes: [String]) -> SafeModeConfig {
        var shells = allowedShellPrefixes
        var seen = Set(shells.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        for p in prefixes {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !seen.contains(t) else { continue }
            shells.append(t)
            seen.insert(t)
        }
        return SafeModeConfig(
            allowedPathPrefixes: allowedPathPrefixes,
            allowedShellPrefixes: shells
        )
    }

    /// Runtime Safe Mode for Plan/Ask (and manual Safe Mode): seed project
    /// roots and optionally union SafeBash inspect primaries so the system
    /// prompt lists the same inspect tools Plan mode advertises.
    ///
    /// Shell enforcement still treats SafeBash-recognized read-only commands
    /// specially in `ToolAuthorization` (they skip the prefix filter so
    /// `cat`/`rg`/`echo` work even when the user's list is only `git`/`ls`).
    public func reconciledForAutoSafeMode(
        projectRoots: [URL],
        unionReadOnlyShellPrefixes: Bool = true
    ) -> SafeModeConfig {
        var cfg = includingProjectRoots(projectRoots)
        if unionReadOnlyShellPrefixes {
            cfg = cfg.unioningShellPrefixes(SafeBash.safeModeInspectShellPrefixes)
        }
        return cfg
    }

    // MARK: - Path policy

    /// True when `url` falls inside one of the allowed path prefixes.
    ///
    /// BOTH sides are normalized first — tilde-expanded, symlink-resolved,
    /// `..`/`.`-standardized, trailing slash stripped — so the comparison
    /// happens on canonical absolute paths. Without this, three bypasses
    /// exist (all found in review, 2026-06-09):
    ///   • absolute paths:  checked as `<wd>/etc/x`, written to `/etc/x`
    ///   • tilde paths:     checked as `<wd>/~/x`,  written to `$HOME/x`
    ///   • `..` traversal:  `<wd>/../../etc/x` passes a naive prefix check
    ///
    /// The prefix match requires a `/` boundary so allowing `/tmp/work`
    /// does not also allow `/tmp/work-evil`.
    public func isPathAllowed(_ url: URL) -> Bool {
        let target = Self.normalizePath(url.path)
        guard !target.isEmpty else { return false }
        for entry in allowedPathPrefixes {
            let allowed = Self.normalizePath(entry)
            if allowed.isEmpty { continue }
            if target == allowed { return true }
            if target.hasPrefix(allowed + "/") { return true }
        }
        return false
    }

    // MARK: - Shell policy

    /// Characters that allow a command to escape its allow-listed prefix
    /// by chaining, substitution, or redirection. `git status; curl …`
    /// has the allowed prefix `git ` but executes arbitrary code after
    /// the `;`. Safe Mode is the opt-in strict posture, so we reject the
    /// whole command rather than attempt quote-aware shell parsing.
    private static let shellMetacharacters: [String] = [
        ";", "&", "|", "`", "$(", ">", "<", "\n"
    ]

    /// Metacharacter-only denial (no prefix list). Used when SafeBash already
    /// classified a command as read-only — S10a skips the prefix allow-list
    /// for inspect shell but must still reject chaining/redirection.
    public func shellMetacharacterDenialReason(_ rawCommand: String) -> String? {
        let cmd = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return "empty command" }
        if let meta = Self.shellMetacharacters.first(where: { cmd.contains($0) }) {
            let shown = meta == "\n" ? "\\n" : meta
            return "command contains the shell metacharacter '\(shown)', which Safe Mode rejects "
                 + "(chaining/substitution/redirection can escape the allow-list). "
                 + "Run one plain command at a time, without quotes containing such characters."
        }
        return nil
    }

    /// Returns nil when `rawCommand` is allowed, else a human-readable
    /// denial reason (fed back to the model so it can adapt).
    ///
    /// Rules:
    ///   1. The trimmed command must equal an allowed prefix exactly, or
    ///      start with `prefix + " "` — a word boundary, so allowing
    ///      `git` does NOT allow `github-anything`.
    ///   2. No shell metacharacters anywhere in the command. Conservative
    ///      by design: `git commit -m "a; b"` is also rejected. The
    ///      error message tells the model how to proceed.
    public func commandDenialReason(_ rawCommand: String) -> String? {
        let cmd = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return "empty command" }

        if let metaReason = shellMetacharacterDenialReason(cmd) {
            return metaReason
        }

        let matchesPrefix = allowedShellPrefixes.contains { prefix in
            let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { return false }
            return cmd == p || cmd.hasPrefix(p + " ")
        }
        guard matchesPrefix else {
            return "command does not start with an allow-listed prefix "
                 + "(allowed: \(allowedShellPrefixes.joined(separator: ", ")))"
        }
        return nil
    }

    // MARK: - System-prompt summary

    /// Injected into the system prompt so the model plans within the
    /// rules instead of discovering them through tool errors.
    public func systemPromptSummary() -> String {
        var lines: [String] = []
        lines.append("# Safe Mode is ACTIVE for this conversation.")
        if allowedPathPrefixes.isEmpty {
            lines.append("- Filesystem mutations are DENIED (no allowed paths).")
        } else {
            lines.append("- Filesystem mutations may only target these paths (and their descendants):")
            for p in allowedPathPrefixes { lines.append("    • \(p)") }
        }
        if allowedShellPrefixes.isEmpty {
            lines.append("- Shell commands are DENIED (no allowed command prefixes).")
        } else {
            lines.append("- Shell commands must start with one of these prefixes, and may not contain ; & | ` $( > < or newlines:")
            for p in allowedShellPrefixes { lines.append("    • \(p)") }
        }
        lines.append("Calls outside these scopes will be rejected. Plan within the rules.")
        return lines.joined(separator: "\n")
    }

    /// Canonicalize a path for policy comparison: expand `~`, resolve
    /// symlinks (works for non-existent leaves — deepest existing
    /// components are resolved, the rest kept literal), standardize
    /// `..`/`.`/double slashes, strip the trailing slash.
    public static func normalizePath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        let standard = (resolved as NSString).standardizingPath
        return standard.hasSuffix("/") && standard.count > 1
            ? String(standard.dropLast())
            : standard
    }
}

public struct ToolResult: Sendable {
    public let content: String
    public let isError: Bool
    /// If the tool mutated files, the relative paths it touched. Drives
    /// `BuildGuard` invalidation. Empty for read-only tools.
    public let mutatedPaths: [String]
    /// Opaque side-channel for the agent loop (e.g. `unlocked_deferred`
    /// from `tool_search`). Not shown to the model unless folded into content.
    public let extras: [String: String]

    public init(
        content: String,
        isError: Bool = false,
        mutatedPaths: [String] = [],
        extras: [String: String] = [:]
    ) {
        self.content = content
        self.isError = isError
        self.mutatedPaths = mutatedPaths
        self.extras = extras
    }
}

public enum ToolError: Error, LocalizedError {
    case invalidArguments(String)
    case permissionDenied(String)
    case execution(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let s): return "Invalid arguments: \(s)"
        case .permissionDenied(let s): return "Permission denied: \(s)"
        case .execution(let s): return "Execution failed: \(s)"
        case .unavailable(let s): return "Tool unavailable: \(s)"
        }
    }
}

public protocol Tool: Sendable {
    static var name: String { get }
    static var category: ToolCategory { get }
    static var permission: ToolPermission { get }
    static var availability: ToolAvailability { get }
    static var schema: ToolSchema { get }

    init()
    func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult
}
