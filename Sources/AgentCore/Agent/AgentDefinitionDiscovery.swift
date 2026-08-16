//
//  AgentDefinitionDiscovery.swift
//  Markdown agent defs with YAML frontmatter (Grok xai-grok-agent discovery).
//
//  Phase B PB5: tools / allowed-tools / allowed_tools frontmatter;
//  unknown tool names are stripped at spawn time (see AgentToolAllowlist).
//  ZCode profile fields: model, thoughtLevel/effort, permissionMode,
//  maxTurns, background (see AgentProfileSettings).
//

import Foundation

public struct DiscoveredAgentDefinition: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var systemPrompt: String
    /// Declared tool names from frontmatter (`tools` / `allowed-tools`).
    /// Empty means "unspecified" — spawn path fails closed to read-only.
    /// Unknown names are kept here for diagnostics; `AgentToolAllowlist`
    /// strips them against the registry when building the live allowlist.
    public var tools: [String]
    public var fileURL: URL?

    /// Optional model id from frontmatter (`model:`).
    public var model: String?
    /// Optional thought / effort string (`thoughtLevel` or `effort`).
    public var thoughtLevel: String?
    /// Mapped permission mode (`acceptEdits`→edit, `bypassPermissions`→yolo).
    public var permissionMode: ExecutionMode?
    /// Optional child iteration cap (`maxTurns`).
    public var maxTurns: Int?
    /// Optional default background spawn (`background:`).
    public var background: Bool?

    public init(name: String, description: String, systemPrompt: String,
                tools: [String] = [], fileURL: URL? = nil,
                model: String? = nil,
                thoughtLevel: String? = nil,
                permissionMode: ExecutionMode? = nil,
                maxTurns: Int? = nil,
                background: Bool? = nil) {
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.fileURL = fileURL
        self.model = model
        self.thoughtLevel = thoughtLevel
        self.permissionMode = permissionMode
        self.maxTurns = maxTurns
        self.background = background
    }

    /// Typed bag for `SubAgentRunner` / `AgentDefinition.profileSettings`.
    public var profileSettings: AgentProfileSettings {
        AgentProfileSettings(
            model: model,
            thoughtLevel: thoughtLevel,
            permissionMode: permissionMode,
            maxTurns: maxTurns,
            background: background
        )
    }

    /// Resolve a spawn allowlist for this definition against known tools.
    public func resolvedToolAllowlist(
        known: Set<String>,
        capability: SubagentCapabilityMode? = nil
    ) -> Set<String> {
        AgentToolAllowlist.resolveCustom(
            declaredTools: tools,
            known: known,
            capability: capability
        )
    }
}

public enum AgentDefinitionDiscovery {

    public static func discover(projectRoot: URL?) -> [DiscoveredAgentDefinition] {
        var dirs: [URL] = []
        if let root = projectRoot {
            dirs.append(root.appendingPathComponent(".vibecoder/agents", isDirectory: true))
            dirs.append(root.appendingPathComponent(".grok/agents", isDirectory: true))
            dirs.append(root.appendingPathComponent(".agentos/agents", isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent(".vibecoder/agents", isDirectory: true))
        dirs.append(home.appendingPathComponent(".grok/agents", isDirectory: true))

        var found: [DiscoveredAgentDefinition] = []
        var seen = Set<String>()
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "md" {
                if let def = parse(file: f), seen.insert(def.name).inserted {
                    found.append(def)
                }
            }
        }
        return found.sorted { $0.name < $1.name }
    }

    public static func byName(_ name: String, projectRoot: URL?) -> DiscoveredAgentDefinition? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return discover(projectRoot: projectRoot).first { $0.name == key }
    }

    public static func parse(file: URL) -> DiscoveredAgentDefinition? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parse(markdown: text, fileURL: file)
    }

    public static func parse(markdown: String, fileURL: URL? = nil) -> DiscoveredAgentDefinition? {
        var name = fileURL?.deletingPathExtension().lastPathComponent ?? "agent"
        var description = ""
        var tools: [String] = []
        var model: String?
        var thoughtLevel: String?
        var permissionMode: ExecutionMode?
        var maxTurns: Int?
        var background: Bool?
        var body = markdown

        if markdown.hasPrefix("---") {
            let parts = markdown.split(separator: "---", maxSplits: 2, omittingEmptySubsequences: false)
            // ["", frontmatter, body...]
            if parts.count >= 3 {
                let fm = String(parts[1])
                body = parts.dropFirst(2).joined(separator: "---")
                let fields = parseFrontmatterFields(fm)
                if let n = fields["name"], !n.isEmpty { name = n }
                if let d = fields["description"] { description = d }
                // Prefer explicit tools:, then allowed-tools / allowed_tools (skill parity).
                if let t = firstToolsValue(fields) {
                    tools = parseToolsList(t)
                }
                model = AgentProfileSettings.nonEmpty(
                    firstField(fields, keys: Self.modelFrontmatterKeys))
                thoughtLevel = AgentProfileSettings.parseThoughtLevel(
                    thoughtLevel: firstField(fields, keys: Self.thoughtLevelFrontmatterKeys),
                    effort: firstField(fields, keys: Self.effortFrontmatterKeys))
                permissionMode = AgentProfileSettings.parsePermissionMode(
                    firstField(fields, keys: Self.permissionModeFrontmatterKeys))
                maxTurns = AgentProfileSettings.parseMaxTurns(
                    firstField(fields, keys: Self.maxTurnsFrontmatterKeys))
                background = AgentProfileSettings.parseBackground(
                    firstField(fields, keys: Self.backgroundFrontmatterKeys))
            }
        }
        let prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        return DiscoveredAgentDefinition(
            name: name, description: description, systemPrompt: prompt,
            tools: tools, fileURL: fileURL,
            model: model, thoughtLevel: thoughtLevel,
            permissionMode: permissionMode, maxTurns: maxTurns,
            background: background)
    }

    // MARK: - Frontmatter (minimal YAML-ish)

    /// Keys that declare a tool allowlist (first hit wins).
    public static let toolsFrontmatterKeys = ["tools", "allowed-tools", "allowed_tools"]
    public static let modelFrontmatterKeys = ["model"]
    public static let thoughtLevelFrontmatterKeys = ["thoughtLevel", "thought_level", "thought-level"]
    public static let effortFrontmatterKeys = ["effort"]
    public static let permissionModeFrontmatterKeys = [
        "permissionMode", "permission_mode", "permission-mode",
    ]
    public static let maxTurnsFrontmatterKeys = ["maxTurns", "max_turns", "max-turns"]
    public static let backgroundFrontmatterKeys = ["background"]

    /// First non-empty value among exact keys, then case-insensitive key match.
    static func firstField(_ fields: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let v = fields[key], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v
            }
        }
        var lower: [String: String] = [:]
        for (k, v) in fields where lower[k.lowercased()] == nil {
            lower[k.lowercased()] = v
        }
        for key in keys {
            if let v = lower[key.lowercased()],
               !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v
            }
        }
        return nil
    }

    static func firstToolsValue(_ fields: [String: String]) -> String? {
        for key in toolsFrontmatterKeys {
            if let v = fields[key], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v
            }
        }
        // Empty explicit `tools:` still counts as declared empty (fail closed).
        for key in toolsFrontmatterKeys {
            if fields[key] != nil { return "" }
        }
        return nil
    }

    /// Parse comma / bracket / newline / semicolon tool lists (skill parity).
    public static func parseToolsList(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var text = trimmed
        if text.hasPrefix("[") && text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        return text
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { part -> String in
                var out = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if out.hasPrefix("-") {
                    out = String(out.drop(while: { $0 == "-" || $0.isWhitespace }))
                }
                if (out.hasPrefix("\"") && out.hasSuffix("\"") && out.count >= 2)
                    || (out.hasPrefix("'") && out.hasSuffix("'") && out.count >= 2) {
                    out = String(out.dropFirst().dropLast())
                }
                return out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    /// Simple `key: value` map; continuation lines for list-style tools are joined.
    static func parseFrontmatterFields(_ frontmatter: String) -> [String: String] {
        var out: [String: String] = [:]
        let lines = frontmatter.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let l = rawLine.trimmingCharacters(in: .whitespaces)
            i += 1
            if l.isEmpty || l.hasPrefix("#") { continue }
            guard let colon = l.firstIndex(of: ":") else { continue }
            let key = String(l[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            var value = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Strip surrounding quotes on scalar values.
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
                || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            }

            // YAML list block under tools: / allowed-tools: with indented `- item` lines.
            if value.isEmpty || value == "|" || value == ">" {
                var items: [String] = []
                while i < lines.count {
                    let cont = lines[i]
                    let t = cont.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty {
                        i += 1
                        continue
                    }
                    // Stop when next top-level key (no leading whitespace on raw, has colon).
                    if !cont.first!.isWhitespace, t.contains(":") {
                        break
                    }
                    if t.hasPrefix("-") {
                        var item = String(t.drop(while: { $0 == "-" || $0.isWhitespace }))
                        if (item.hasPrefix("\"") && item.hasSuffix("\"") && item.count >= 2)
                            || (item.hasPrefix("'") && item.hasSuffix("'") && item.count >= 2) {
                            item = String(item.dropFirst().dropLast())
                        }
                        if !item.isEmpty { items.append(item) }
                        i += 1
                        continue
                    }
                    // Non-list continuation: only absorb if indented under empty key.
                    if cont.first?.isWhitespace == true, toolsFrontmatterKeys.contains(key) {
                        items.append(t)
                        i += 1
                        continue
                    }
                    break
                }
                if !items.isEmpty {
                    value = items.joined(separator: ", ")
                }
            }

            out[key] = value
        }
        return out
    }
}
