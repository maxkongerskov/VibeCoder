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
//      { "kind": "allow","tool": "run_shell", "commandContains": "npm test" },
//      { "kind": "allow","tool": "run_shell", "ruleContent": "git status" },
//      { "kind": "deny", "tool": "fetch_url", "ruleContent": "*.evil.com" }
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
//  - `ruleContent` / `commandPrefix`: ZCode-style prefix for run_shell
//    (`git status`, `git status:*`, `npm run`) — equals prefix or
//    `prefix + space/tab`. Hosts for fetch_url / web_search (`*.example.com`).
//  - `alwaysAllow` / `alwaysDeny`: session grants via AuthorizationConfig.remembered
//    (not written to DurableGrantStore — deleting the file revokes on next turn).
//    Shell entries use commandPrefix/command fingerprinted like
//    RememberedGrants.fingerprint. Dangerous shell never auto-allows.
//
//  Claude subset in .claude/settings.json:
//    "permissions": { "allow": ["Read","Bash(git status)"], "deny": [...], "ask": [...] }
//  Bare tool names map to VibeCoder tools when known; `Bash(...)` → run_shell
//  + ruleContent prefix. `WebFetch(*.example.com)` → fetch_url host rule.
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
        let tool = nonempty(item["tool"] as? String)
            ?? nonempty(item["toolName"] as? String)
            ?? nonempty(item["name"] as? String)
        let ruleContent = nonempty(item["ruleContent"] as? String)
            ?? nonempty(item["host"] as? String)
            ?? nonempty(item["domain"] as? String)
            ?? nonempty(item["commandPrefix"] as? String)
        let contains = nonempty(item["commandContains"] as? String)
            ?? nonempty(item["command"] as? String)
        guard tool != nil || contains != nil || ruleContent != nil else { return nil }
        return AuthorizationRule(
            kind: kind, toolName: tool, commandContains: contains, ruleContent: ruleContent)
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
            let content = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            let needle = inner
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if needle.isEmpty && content.isEmpty {
                return [AuthorizationRule(kind: kind, toolName: "run_shell")]
            }
            return [AuthorizationRule(
                kind: kind,
                toolName: "run_shell",
                commandContains: needle.isEmpty ? nil : needle,
                ruleContent: content.isEmpty ? nil : content)]
        }

        if trimmed.contains("("),
           let inner = extractParenContents(trimmed) {
            let namePart = String(trimmed[..<(trimmed.firstIndex(of: "(") ?? trimmed.endIndex)])
            if let tool = mapClaudeToolName(namePart) {
                let content = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if content.isEmpty {
                    return [AuthorizationRule(kind: kind, toolName: tool)]
                }
                return [AuthorizationRule(kind: kind, toolName: tool, ruleContent: content)]
            }
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

    private static func nonempty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Stable 1–2 token prefix for approval suggestions (`git status`, `npm run`).
    public static func normalizedCommandPrefix(_ command: String) -> String? {
        CommandPrefixNormalizer.prefix(for: command)
    }

    /// `Always allow git status` style updates for wave-2 UI.
    public static func suggestions(forShellCommand command: String) -> [SuggestedPermissionUpdate] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if SafeBash.isDangerous(trimmed) { return [] }
        guard let prefix = CommandPrefixNormalizer.prefix(for: trimmed), !prefix.isEmpty else {
            return []
        }
        return [
            SuggestedPermissionUpdate(
                toolName: "run_shell",
                ruleContent: prefix,
                behavior: .allow)
        ]
    }
}

// MARK: - Command prefix + host match

/// Common multi-word tools: first 1–2 tokens (`git`, `npm run`, `docker compose`, `kubectl`).
public enum CommandPrefixNormalizer: Sendable {
    public static func prefix(for command: String) -> String? {
        let segs = SafeBash.segments(of: command)
        guard let first = segs.first else { return nil }
        let tokens = SafeBash.peelWrappers(SafeBash.tokenize(first))
        guard let primaryRaw = tokens.first else { return nil }
        let primary = executableBasename(primaryRaw).lowercased()
        let rest = Array(tokens.dropFirst())

        switch primary {
        case "git", "kubectl":
            if let sub = rest.first(where: { !$0.hasPrefix("-") }) {
                return "\(primary) \(sub)"
            }
            return primary
        case "npm", "pnpm", "yarn", "bun":
            if let verb = rest.first, verb == "run" || verb == "run-script" {
                return "\(primary) run"
            }
            if let sub = rest.first(where: { !$0.hasPrefix("-") }) {
                return "\(primary) \(sub)"
            }
            return primary
        case "docker":
            if let sub = rest.first, sub == "compose" {
                return "docker compose"
            }
            if let sub = rest.first(where: { !$0.hasPrefix("-") }) {
                return "docker \(sub)"
            }
            return primary
        default:
            return primary
        }
    }

    private static func executableBasename(_ token: String) -> String {
        let unified = token.replacingOccurrences(of: "\\", with: "/")
        guard let slash = unified.lastIndex(of: "/") else { return token }
        let base = String(unified[unified.index(after: slash)...])
        return base.isEmpty ? token : base
    }
}

public enum PermissionRuleMatch: Sendable {
    public static func toolNamesMatch(_ ruleTool: String, _ invoked: String) -> Bool {
        if ruleTool == invoked { return true }
        let aliases: [String: Set<String>] = [
            "run_shell": ["run_shell", "run_shell_command", "Bash", "bash"],
            "run_shell_command": ["run_shell", "run_shell_command", "Bash", "bash"],
            "Bash": ["run_shell", "run_shell_command", "Bash", "bash"],
            "bash": ["run_shell", "run_shell_command", "Bash", "bash"],
            "fetch_url": ["fetch_url", "WebFetch", "webfetch"],
            "WebFetch": ["fetch_url", "WebFetch", "webfetch"],
            "web_search": ["web_search", "WebSearch", "websearch"],
            "WebSearch": ["web_search", "WebSearch", "websearch"],
        ]
        if let group = aliases[ruleTool], group.contains(invoked) { return true }
        if let mapped = PermissionRules.mapClaudeToolName(ruleTool), mapped == invoked {
            return true
        }
        return false
    }

    public static func matches(
        tool: String,
        ruleContent: String,
        command: String?,
        url: String?,
        query: String?
    ) -> Bool {
        if isNetworkTool(tool) {
            if let host = hostname(from: url)
                ?? hostname(from: query)
                ?? siteHost(fromQuery: query) {
                return hostMatches(host, rule: ruleContent)
            }
            return false
        }
        if let command {
            return commandMatches(command, ruleContent: ruleContent)
        }
        if let url {
            return commandHasPrefix(url, prefix: stripPrefixMarker(ruleContent))
                || wildcardMatches(ruleContent, subject: url)
        }
        return false
    }

    public static func commandMatches(_ command: String, ruleContent: String) -> Bool {
        let content = ruleContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return true }
        let subjects = commandSubjects(command)
        if content.hasSuffix(":*") || !content.contains("*") {
            let prefix = stripPrefixMarker(content)
            return subjects.contains { commandHasPrefix($0, prefix: prefix) }
        }
        return subjects.contains { wildcardMatches(content, subject: $0) }
    }

    /// Equals prefix or starts with `prefix + space/tab`.
    public static func commandHasPrefix(_ command: String, prefix: String) -> Bool {
        let subject = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if subject == prefix { return true }
        if subject.hasPrefix(prefix + " ") || subject.hasPrefix(prefix + "\t") {
            return true
        }
        return false
    }

    public static func hostMatches(_ host: String, rule: String) -> Bool {
        var pattern = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if pattern.hasPrefix("domain:") {
            pattern = String(pattern.dropFirst("domain:".count))
        }
        if pattern.contains("://"), let fromURL = hostname(from: rule) {
            pattern = fromURL
        }
        let h = normalizeHost(host)
        pattern = normalizeHost(pattern)
        guard !pattern.isEmpty else { return false }
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return h == suffix || h.hasSuffix("." + suffix)
        }
        if pattern.contains("*") {
            return wildcardMatches(pattern, subject: h)
        }
        return h == pattern
    }

    public static func hostname(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let host = urlHost(trimmed) { return host }
        if trimmed.contains("://") { return nil }
        if trimmed.contains("/") || trimmed.contains("?") { return urlHost("https://\(trimmed)") }
        if trimmed.contains(".") && !trimmed.contains(" "),
           let host = urlHost("https://\(trimmed)") {
            return host
        }
        return nil
    }

    private static func isNetworkTool(_ tool: String) -> Bool {
        switch tool {
        case "fetch_url", "web_search", "fetch_rss",
             "WebFetch", "WebSearch", "webfetch", "websearch":
            return true
        default:
            return false
        }
    }

    private static func commandSubjects(_ command: String) -> [String] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        var subjects = [trimmed]
        for seg in SafeBash.segments(of: command) {
            let t = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !subjects.contains(t) { subjects.append(t) }
        }
        return subjects
    }

    private static func stripPrefixMarker(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix(":*") { return String(t.dropLast(2)) }
        return t
    }

    private static func wildcardMatches(_ pattern: String, subject: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var regex = "^"
        for (i, part) in parts.enumerated() {
            if i > 0 { regex += ".*" }
            regex += NSRegularExpression.escapedPattern(for: part)
        }
        regex += "$"
        return subject.range(of: regex, options: [.regularExpression]) != nil
    }

    private static func siteHost(fromQuery query: String?) -> String? {
        guard let query else { return nil }
        let ns = query as NSString
        let pattern = #"site:([A-Za-z0-9.-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: query, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2,
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return ns.substring(with: match.range(at: 1)).lowercased()
    }

    private static func urlHost(_ raw: String) -> String? {
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            return nil
        }
        return normalizeHost(host)
    }

    private static func normalizeHost(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }
}
