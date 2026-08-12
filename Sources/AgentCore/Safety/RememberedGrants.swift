//
//  RememberedGrants.swift
//
//  Per-project remembered tool/command/path approvals. Dangerous
//  commands never match. Used by ToolAuthorization + MutationReview.
//

import Foundation

public enum GrantDecision: String, Sendable, Codable, Equatable {
    case allow
    case never
}

public struct GrantKey: Hashable, Sendable, Codable {
    public let projectKey: String
    public let toolName: String
    /// Optional shell command prefix, or `path:` / `dir:` fingerprints.
    public let commandFingerprint: String?

    public init(projectKey: String, toolName: String, commandFingerprint: String? = nil) {
        self.projectKey = projectKey
        self.toolName = toolName
        self.commandFingerprint = commandFingerprint
    }
}

/// In-memory remembered grants (process lifetime). Hosts may snapshot
/// elsewhere later; the harness path is this actor.
///
/// **Important:** only call `remember` on an explicit user choice such as
/// "Always allow" / "Never allow". One-shot Accept/Reject in Ask mode must
/// not write grants — that would brick or auto-approve all future edits.
public actor RememberedGrants {
    public static let shared = RememberedGrants()

    /// Tool name used for path/directory grants that apply to every tool.
    public static let pathGrantToolName = "__path__"

    private var store: [GrantKey: GrantDecision] = [:]

    public func decision(for key: GrantKey) -> GrantDecision? {
        store[key]
    }

    /// All grants for a project (including path/dir fingerprints).
    public func snapshot(projectKey: String) -> [GrantKey: GrantDecision] {
        store.filter { $0.key.projectKey == projectKey }
    }

    public func allEntries() -> [GrantKey: GrantDecision] {
        store
    }

    public func rememberInMemoryOnly(_ decision: GrantDecision, for key: GrantKey) {
        store[key] = decision
    }

    /// Explicit Always/Never allow — process + durable disk.
    public func remember(_ decision: GrantDecision, for key: GrantKey) async {
        store[key] = decision
        await DurableGrantStore.shared.rememberProcessMirror(decision, for: key)
    }

    /// Remember durable access for a directory and all descendants.
    public func alwaysAllowDirectory(_ directory: URL, projectKey: String) async {
        let key = GrantKey(
            projectKey: projectKey,
            toolName: Self.pathGrantToolName,
            commandFingerprint: PathConfinement.directoryGrantFingerprint(directory)
        )
        await remember(.allow, for: key)
    }

    /// Clear process grants and matching durable disk entries.
    /// Durable clear is awaited so the next auth hydrate cannot resurrect
    /// a just-cleared Never/Always (Wave C bug-hunt).
    public func clear(projectKey: String? = nil) async {
        clearProcessOnly(projectKey: projectKey)
        await DurableGrantStore.shared.clear(projectKey: projectKey)
    }

    /// Revoke a single Always/Never grant from process memory **and** durable
    /// disk without clearing other keys (Polish P1 — Settings grant manager).
    ///
    /// Awaits durable removal so a subsequent hydrate cannot resurrect the
    /// entry. Returns true when the process store had the key (or durable did
    /// and was removed); false when neither store contained it.
    @discardableResult
    public func forget(_ key: GrantKey) async -> Bool {
        let hadProcess = store.removeValue(forKey: key) != nil
        let hadDurable = await DurableGrantStore.shared.forget(key)
        return hadProcess || hadDurable
    }

    /// Drop **process memory only** — leave durable disk intact so hydrate
    /// tests (and cold-restart simulation) can re-load Always/Never grants.
    /// Production "forget grants" UI must use `clear` / `forget` (process + disk).
    public func clearProcessOnly(projectKey: String? = nil) {
        if let projectKey {
            store = store.filter { $0.key.projectKey != projectKey }
        } else {
            store.removeAll()
        }
    }

    /// Command grant fingerprint (Always/Never for shell).
    ///
    /// Fingerprints the **full chain** so Always on `git status` never
    /// also matches `git status && npm install`. Each segment is peeled
    /// (wrappers) and capped at 8 tokens; segments join with ` && `.
    public static func fingerprint(command: String) -> String {
        let segs = SafeBash.segments(of: command)
        guard !segs.isEmpty else {
            return command.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = segs.map { seg -> String in
            let tokens = SafeBash.peelWrappers(SafeBash.tokenize(seg))
            if tokens.isEmpty {
                return seg.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return tokens.prefix(8).joined(separator: " ")
        }
        return parts.joined(separator: " && ")
    }

    public static func projectKey(from context: ToolContext) -> String {
        context.projectRoot?.path
            ?? context.worktreeRoot?.path
            ?? context.workingDirectory.path
    }

    /// Whether grants allow access to `resolved` (exact path or under a `dir:` grant).
    /// Tool-level allow (`toolName` with nil fingerprint) also matches.
    public static func allowsPath(
        _ resolved: URL,
        toolName: String,
        projectKey: String,
        grants: [GrantKey: GrantDecision]
    ) -> Bool {
        let normalized = SafeModeConfig.normalizePath(resolved.path)
        guard !normalized.isEmpty else { return false }

        // Tool-level always-allow for this tool.
        let toolKey = GrantKey(projectKey: projectKey, toolName: toolName, commandFingerprint: nil)
        if grants[toolKey] == .allow { return true }

        // Exact path grant (path: or legacy bare).
        let pathFP = PathConfinement.pathGrantFingerprint(resolved)
        let pathKey = GrantKey(
            projectKey: projectKey,
            toolName: pathGrantToolName,
            commandFingerprint: pathFP
        )
        if grants[pathKey] == .allow { return true }
        let pathKeyTool = GrantKey(projectKey: projectKey, toolName: toolName, commandFingerprint: pathFP)
        if grants[pathKeyTool] == .allow { return true }

        // Path-specific .never grants override directory .allow (most specific wins).
        let pathKeyNever = GrantKey(projectKey: projectKey, toolName: Self.pathGrantToolName, commandFingerprint: "path:" + normalized)
        if grants[pathKeyNever] == .never { return false }
        let pathToolKeyNever = GrantKey(projectKey: projectKey, toolName: toolName, commandFingerprint: "path:" + normalized)
        if grants[pathToolKeyNever] == .never { return false }

        // Directory grants: any ancestor dir: grant.
        for (key, decision) in grants {
            guard decision == .allow,
                  key.projectKey == projectKey,
                  let fp = key.commandFingerprint,
                  fp.hasPrefix("dir:") else { continue }
            let dirPath = String(fp.dropFirst(4))
            if dirPath.isEmpty { continue }
            if normalized == dirPath || normalized.hasPrefix(dirPath + "/") {
                return true
            }
        }
        return false
    }
}
