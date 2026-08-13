//
//  PermissionRules.swift
//
//  Project / user permission rules loaded from disk and merged into
//  `AuthorizationConfig` (rules + always-allow grants).
//
//  Search order (later wins on conflict for always-allow; deny rules
//  accumulate — project files load after user so project can refine):
//
//    1. ~/.vibecoder/permissions.json
//    2. ~/.agentos/permissions.json
//    3. <project>/.vibecoder/permissions.json
//    4. <project>/.agentos/permissions.json
//    5. <project>/.claude/settings.json  →  permissions.allow|deny|ask (subset)
//
//  # permissions.json format (v1)
//
//  ```json
//  {
//    "version": 1,
//    "rules": [
//      { "kind": "deny", "tool": "run_shell", "commandContains": "rm -rf" },
//      { "kind": "ask",  "tool": "delete_file" },
//      { "kind": "allow","tool": "run_shell", "commandContains": "npm test" }
//    ],
//    "alwaysAllow": [
//      { "tool": "edit_file" },
//      { "tool": "run_shell", "commandPrefix": "git status" }
//    ],
//    "alwaysDeny": [
//      { "tool": "run_shell", "commandPrefix": "curl" }
//    ]
//  }
//  ```
//
//  - `kind`: deny | ask | allow  (deny wins first in ToolAuthorization)
//  - `tool` / `toolName`: exact tool name (e.g. write_file, run_shell)
//  - `commandContains`: case-insensitive substring on shell command
//  - `alwaysAllow` / `alwaysDeny`: session grants via AuthorizationConfig.remembered
//    (not written to DurableGrantStore — deleting the file revokes on next turn).
//    Shell entries use commandPrefix/command fingerprinted like
//    RememberedGrants.fingerprint. Dangerous shell never auto-allows.
//
//  Claude subset in .claude/settings.json:
//    "permissions": { "allow": ["Read","Bash(git status)"], "deny": [...], "ask": [...] }
//  Bare tool names map to VibeCoder tools when known; `Bash(...)` → run_shell.
//

import Foundation

// MARK: - Snapshot

public struct PermissionRulesSnapshot: Sendable, Equatable {
    public var rules: [AuthorizationRule]
    /// Session always-allow / never grants seeded from rules files (not disk durable).
    public var grants: [GrantKey: GrantDecision]
    /// Absolute paths that contributed rules (diagnostics / tests).
    public var sourcePaths: [String]

    public init(
        rules: [AuthorizationRule] = [],
        grants: [GrantKey: GrantDecision] = [:],
        sourcePaths: [String] = []
    ) {
        self.rules = rules
        self.grants = grants
        self.sourcePaths = sourcePaths
    }

    public static let empty = PermissionRulesSnapshot()

    public var isEmpty: Bool { rules.isEmpty && grants.isEmpty }
}

// MARK: - Loader

public enum PermissionRules {

    public static let projectRelativePaths = [
        ".vibecoder/permissions.json",
        ".agentos/permissions.json",
    ]

    public static let homeRelativePaths = [
        ".vibecoder/permissions.json",
        ".agentos/permissions.json",
    ]

    public static let claudeSettingsRelativePath = ".claude/settings.json"

    /// Load merged permission rules for a project.
    public static func load(
        projectRoot: URL?,
        includeHome: Bool = true,
        includeClaudeSettings: Bool = true,
        projectKey: String? = nil
    ) -> PermissionRulesSnapshot {
        let key = projectKey
            ?? projectRoot?.path
            ?? "global"

        var rules: [AuthorizationRule] = []
        var grants: [GrantKey: GrantDecision] = [:]
        var sources: [String] = []

        var urls: [URL] = []
        if includeHome {
            let home = FileManager.default.homeDirectoryForCurrentUser
            for rel in homeRelativePaths {
                urls.append(home.appendingPathComponent(rel))
            }
        }
        if let root = projectRoot {
            for rel in projectRelativePaths {
                urls.append(root.appendingPathComponent(rel))
            }
            if includeClaudeSettings {
                urls.append(root.appendingPathComponent(claudeSettingsRelativePath))
            }
        }

        var seenPaths = Set<String>()
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            guard FileManager.default.isReadableFile(atPath: path),
                  let data = try? Data(contentsOf: url) else { continue }

            let parsed: PermissionRulesSnapshot
            if url.lastPathComponent == "settings.json"
                && url.deletingLastPathComponent().lastPathComponent == ".claude" {
                parsed = parseClaudeSettings(data: data, projectKey: key)
            } else {
                parsed = parsePermissionsJSON(data: data, projectKey: key)
            }
            if parsed.isEmpty {
                continue
            }
            rules.append(contentsOf: parsed.rules)
            for (gKey, decision) in parsed.grants {
                grants[gKey] = decision
            }
            sources.append(path)
        }

        return PermissionRulesSnapshot(rules: rules, grants: grants, sourcePaths: sources)
    }

    /// Merge a rules snapshot into an existing AuthorizationConfig.
    /// File grants fill empty keys; existing remembered entries win on conflict
    /// (user Always/Never from UI outranks static file alwaysAllow).
    public static func merge(
        into config: AuthorizationConfig,
        snapshot: PermissionRulesSnapshot
    ) -> AuthorizationConfig {
        var out = config
        // Deny first so first-match consumers cannot let an earlier ask
        // mask alwaysDeny / deny rules (ToolAuthorization also deny-wins).
        let combined = snapshot.rules + config.rules
        out.rules = combined.filter { $0.kind == .deny }
            + combined.filter { $0.kind != .deny }
        var rem = snapshot.grants
        for (k, v) in config.remembered {
            rem[k] = v
        }
        out.remembered = rem
        return out
    }

    // MARK: - Parse native permissions.json

    public static func parsePermissionsJSON(data: Data, projectKey: String) -> PermissionRulesSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        return parsePermissionsObject(root, projectKey: projectKey)
    }

    public static func parsePermissionsJSON(string: String, projectKey: String) -> PermissionRulesSnapshot {
        guard let data = string.data(using: .utf8) else { return .empty }
        return parsePermissionsJSON(data: data, projectKey: projectKey)
    }

    private static func parsePermissionsObject(
        _ root: [String: Any],
        projectKey: String
    ) -> PermissionRulesSnapshot {
        var rules: [AuthorizationRule] = []
        var grants: [GrantKey: GrantDecision] = [:]

        if let arr = root["rules"] as? [[String: Any]] {
            for item in arr {
                if let rule = ruleFromDict(item) {
                    rules.append(rule)
                }
            }
        }

        if let arr = root["alwaysAllow"] as? [[String: Any]] {
            for item in arr {
                if let key = grantKeyFromDict(item, projectKey: projectKey) {
                    grants[key] = .allow
                }
            }
        }

        if let arr = root["alwaysDeny"] as? [[String: Any]] {
            for item in arr {
                if let key = grantKeyFromDict(item, projectKey: projectKey) {
                    grants[key] = .never
                }
                if let rule = ruleFromDict(item, forceKind: .deny) {
                    rules.append(rule)
                }
            }
        }

        for (field, kind) in [
            ("allow", AuthorizationRule.Kind.allow),
            ("deny", AuthorizationRule.Kind.deny),
            ("ask", AuthorizationRule.Kind.ask),
        ] as [(String, AuthorizationRule.Kind)] {
            if let arr = root[field] as? [String] {
                for entry in arr {
                    rules.append(contentsOf: rulesFromClaudeStyleEntry(entry, kind: kind))
                }
            }
        }

        if rules.isEmpty && grants.isEmpty {
            return .empty
        }
        return PermissionRulesSnapshot(rules: rules, grants: grants, sourcePaths: [])
    }

    // MARK: - Claude settings subset

    public static func parseClaudeSettings(data: Data, projectKey: String) -> PermissionRulesSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let perms = root["permissions"] as? [String: Any] else {
            return .empty
        }
        var rules: [AuthorizationRule] = []
        for (field, kind) in [
            ("allow", AuthorizationRule.Kind.allow),
            ("deny", AuthorizationRule.Kind.deny),
            ("ask", AuthorizationRule.Kind.ask),
        ] as [(String, AuthorizationRule.Kind)] {
            if let arr = perms[field] as? [String] {
                for entry in arr {
                    rules.append(contentsOf: rulesFromClaudeStyleEntry(entry, kind: kind))
                }
            }
        }
        var grants: [GrantKey: GrantDecision] = [:]
        if let allow = perms["allow"] as? [String] {
            for entry in allow {
                if let tool = mapClaudeToolName(entry), !entry.contains("(") {
                    grants[GrantKey(projectKey: projectKey, toolName: tool)] = .allow
                }
            }
        }
        if rules.isEmpty && grants.isEmpty { return .empty }
        return PermissionRulesSnapshot(
            rules: rules, grants: grants, sourcePaths: [])
    }

    // MARK: - Helpers

    private static func ruleFromDict(
        _ item: [String: Any],
        forceKind: AuthorizationRule.Kind? = nil
    ) -> AuthorizationRule? {
        let kind: AuthorizationRule.Kind
        if let forceKind {
            kind = forceKind
        } else if let raw = (item["kind"] as? String)?.lowercased(),
                  let k = AuthorizationRule.Kind(rawValue: raw) {
            kind = k
        } else {
            return nil
        }
        let tool = (item["tool"] as? String)
            ?? (item["toolName"] as? String)
            ?? (item["name"] as? String)
        let contains = (item["commandContains"] as? String)
            ?? (item["command"] as? String)
            ?? (item["commandPrefix"] as? String)
        guard tool != nil || contains != nil else { return nil }
        return AuthorizationRule(kind: kind, toolName: tool, commandContains: contains)
    }

    private static func grantKeyFromDict(
        _ item: [String: Any],
        projectKey: String
    ) -> GrantKey? {
        guard let tool = (item["tool"] as? String)
            ?? (item["toolName"] as? String)
            ?? (item["name"] as? String),
              !tool.isEmpty else { return nil }
        let cmd = (item["commandPrefix"] as? String)
            ?? (item["command"] as? String)
            ?? (item["commandContains"] as? String)
        if let cmd, !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let shellTool = (tool == "run_shell_command" || tool == "Bash") ? "run_shell" : tool
            if shellTool == "run_shell" {
                return GrantKey(
                    projectKey: projectKey,
                    toolName: "run_shell",
                    commandFingerprint: RememberedGrants.fingerprint(command: cmd)
                )
            }
            return GrantKey(
                projectKey: projectKey,
                toolName: tool,
                commandFingerprint: RememberedGrants.fingerprint(command: cmd)
            )
        }
        return GrantKey(projectKey: projectKey, toolName: tool, commandFingerprint: nil)
    }

    public static func rulesFromClaudeStyleEntry(
        _ entry: String,
        kind: AuthorizationRule.Kind
    ) -> [AuthorizationRule] {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.hasPrefix("Bash(") || trimmed.hasPrefix("bash(") {
            let inner = extractParenContents(trimmed) ?? ""
            let needle = inner
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if needle.isEmpty {
                return [AuthorizationRule(kind: kind, toolName: "run_shell")]
            }
            return [AuthorizationRule(
                kind: kind, toolName: "run_shell", commandContains: needle)]
        }

        if let tool = mapClaudeToolName(trimmed) {
            return [AuthorizationRule(kind: kind, toolName: tool)]
        }

        return [AuthorizationRule(kind: kind, toolName: trimmed)]
    }

    public static func mapClaudeToolName(_ raw: String) -> String? {
        let name: String
        if let open = raw.firstIndex(of: "(") {
            name = String(raw[..<open])
        } else {
            name = raw
        }
        switch name.lowercased() {
        case "read", "readfile": return "read_file"
        case "write", "writefile": return "write_file"
        case "edit", "editfile", "multiedit": return "edit_file"
        case "bash", "shell": return "run_shell"
        case "grep": return "grep_code"
        case "glob": return "glob_files"
        case "ls", "list": return "list_directory"
        case "webfetch", "fetch": return "fetch_url"
        case "websearch": return "web_search"
        case "task", "agent": return "task"
        default:
            if name.contains("_") || name.contains("__") { return name }
            return nil
        }
    }

    private static func extractParenContents(_ s: String) -> String? {
        guard let open = s.firstIndex(of: "("),
              let close = s.lastIndex(of: ")"),
              open < close else { return nil }
        return String(s[s.index(after: open)..<close])
    }
}
