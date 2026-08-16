//
//  SettingsManagersSupport.swift
//  Disk helpers for Settings → Skills / Subagents.
//  AgentCore discovery stays read-only; this layer writes YAML the parsers already accept.
//

import Foundation
import AppKit
import AgentCore

enum SettingsManagersError: Error, LocalizedError, Equatable {
    case invalidName
    case emptyPrompt
    case emptySkillBody
    case missingSkillMarkdown
    case noProject
    case io(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Name may only contain letters, numbers, and hyphens."
        case .emptyPrompt:
            return "System prompt cannot be empty."
        case .emptySkillBody:
            return "Skill body cannot be empty."
        case .missingSkillMarkdown:
            return "The selection does not contain a SKILL.md file."
        case .noProject:
            return "Open a project to use workspace scope."
        case .io(let message):
            return message
        }
    }
}

enum SettingsManagersPaths {
    static func userSkillsRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".vibecoder/skills", isDirectory: true)
    }

    static func projectSkillsRoot(_ projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".vibecoder/skills", isDirectory: true)
    }

    static func userAgentsRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".vibecoder/agents", isDirectory: true)
    }

    static func projectAgentsRoot(_ projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".vibecoder/agents", isDirectory: true)
    }

    static func reveal(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([fm.homeDirectoryForCurrentUser])
    }
}

// MARK: - Name / slug

enum SettingsManagersNaming {
    /// Subagent / skill slugs: letters, numbers, hyphens only.
    static func isValidName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
        }
    }

    static func slugify(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(trimmed.prefix(SkillDiscovery.maxNameLen))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let mapped = clipped.unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) { return Character(scalar) }
            if CharacterSet.whitespaces.contains(scalar) || scalar == "_" || scalar == "." {
                return "-"
            }
            return "-"
        }
        var dashed = String(mapped)
        while dashed.contains("--") {
            dashed = dashed.replacingOccurrences(of: "--", with: "-")
        }
        return dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
    }
}

// MARK: - Skill frontmatter

enum SkillFrontmatterWriter {
    /// Flip `disable-model-invocation` while preserving other frontmatter keys and the body.
    static func setDisableModelInvocation(_ markdown: String, disabled: Bool) -> String {
        var text = markdown
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.contains("\r\n") {
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
        } else if text.contains("\r") {
            text = text.replacingOccurrences(of: "\r", with: "\n")
        }

        let value = disabled ? "true" : "false"
        if let split = splitFrontmatter(text) {
            let rewritten = upsertDisableFlag(in: split.fields, disabled: disabled)
            return "---\n\(rewritten)\n---\n\(split.remainder)"
        }

        return """
        ---
        disable-model-invocation: \(value)
        ---
        \(text)
        """
    }

    static func applyDisableModelInvocation(at fileURL: URL, disabled: Bool) throws {
        let original = try String(contentsOf: fileURL, encoding: .utf8)
        let updated = setDisableModelInvocation(original, disabled: disabled)
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func encodeNewSkill(name: String, description: String, body: String) -> String {
        var lines = ["---", "name: \(yamlScalar(name))"]
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty {
            lines.append("description: \(yamlScalar(desc))")
        }
        lines.append("---")
        lines.append("")
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(trimmedBody.isEmpty ? "# \(name)\n" : trimmedBody)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func writeNewSkill(
        name: String,
        description: String,
        body: String,
        root: URL
    ) throws -> URL {
        let slug = SettingsManagersNaming.slugify(name)
        guard SettingsManagersNaming.isValidName(slug) else {
            throw SettingsManagersError.invalidName
        }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = encodeNewSkill(
            name: slug,
            description: description,
            body: trimmedBody.isEmpty ? "# \(slug)\n" : trimmedBody
        )
        guard SkillDiscovery.parse(markdown: markdown, defaultName: slug) != nil else {
            throw SettingsManagersError.emptySkillBody
        }
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("SKILL.md")
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Copy a picked `SKILL.md` or skill folder into `root`.
    static func importSkill(from picked: URL, into root: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: picked.path, isDirectory: &isDir) else {
            throw SettingsManagersError.missingSkillMarkdown
        }

        if isDir.boolValue {
            let skillFile = findSkillMarkdown(in: picked)
            guard let skillFile else { throw SettingsManagersError.missingSkillMarkdown }
            let slug = SettingsManagersNaming.slugify(
                SkillDiscovery.parse(file: skillFile)?.name ?? picked.lastPathComponent
            )
            guard SettingsManagersNaming.isValidName(slug) else {
                throw SettingsManagersError.invalidName
            }
            let dest = root.appendingPathComponent(slug, isDirectory: true)
            if dest.standardizedFileURL.path != picked.standardizedFileURL.path {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: picked, to: dest)
            }
            return dest.appendingPathComponent(skillFile.lastPathComponent)
        }

        let parsed = SkillDiscovery.parse(file: picked)
        let fallback = picked.deletingLastPathComponent().lastPathComponent
        let rawName = parsed?.name.isEmpty == false
            ? parsed!.name
            : (fallback.caseInsensitiveCompare("skills") == .orderedSame
               ? picked.deletingPathExtension().lastPathComponent
               : fallback)
        let slug = SettingsManagersNaming.slugify(rawName)
        guard SettingsManagersNaming.isValidName(slug) else {
            throw SettingsManagersError.invalidName
        }
        let destDir = root.appendingPathComponent(slug, isDirectory: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("SKILL.md")
        if dest.standardizedFileURL.path != picked.standardizedFileURL.path {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: picked, to: dest)
        }
        return dest
    }

    private static func findSkillMarkdown(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries.first {
            $0.lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame
        }
    }

    private static func upsertDisableFlag(in fields: String, disabled: Bool) -> String {
        let replacement = "disable-model-invocation: \(disabled ? "true" : "false")"
        var lines = fields.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found = false
        for idx in lines.indices {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("disable-model-invocation:")
                || trimmed.hasPrefix("disable_model_invocation:") {
                lines[idx] = replacement
                found = true
                break
            }
        }
        if !found {
            if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeLast()
            }
            lines.append(replacement)
        }
        return lines.joined(separator: "\n")
    }

    private static func splitFrontmatter(_ markdown: String) -> (fields: String, remainder: String)? {
        guard markdown.hasPrefix("---") else { return nil }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---"
        else { return nil }
        var closeIndex: Int?
        for idx in 1..<lines.count {
            if lines[idx].trimmingCharacters(in: .whitespaces) == "---" {
                closeIndex = idx
                break
            }
        }
        guard let closeIndex else { return nil }
        let fields = lines[1..<closeIndex].joined(separator: "\n")
        let remainder = lines[(closeIndex + 1)...].joined(separator: "\n")
        return (fields, remainder)
    }
}

// MARK: - Subagent profile codec

struct SubagentProfileDraft: Equatable {
    var name: String
    var description: String
    var systemPrompt: String
    var model: String
    var maxTurns: Int?
    var background: Bool
    /// When true, omit `tools:` so discovery treats the allowlist as unspecified (inherit).
    var inheritAllTools: Bool
    var tools: [String]

    init(
        name: String = "",
        description: String = "",
        systemPrompt: String = "",
        model: String = "",
        maxTurns: Int? = nil,
        background: Bool = false,
        inheritAllTools: Bool = true,
        tools: [String] = []
    ) {
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.model = model
        self.maxTurns = maxTurns
        self.background = background
        self.inheritAllTools = inheritAllTools
        self.tools = tools
    }

    init(definition: DiscoveredAgentDefinition, inheritAllTools: Bool) {
        self.name = definition.name
        self.description = definition.description
        self.systemPrompt = definition.systemPrompt
        self.model = definition.model ?? ""
        self.maxTurns = definition.maxTurns
        self.background = definition.background ?? false
        self.inheritAllTools = inheritAllTools
        self.tools = definition.tools
    }
}

enum SubagentProfileCodec {
    static func encode(_ draft: SubagentProfileDraft) throws -> String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SettingsManagersNaming.isValidName(name) else {
            throw SettingsManagersError.invalidName
        }
        let prompt = draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw SettingsManagersError.emptyPrompt }

        var lines = ["---", "name: \(yamlScalar(name))"]
        let desc = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty {
            lines.append("description: \(yamlScalar(desc))")
        }
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            lines.append("model: \(yamlScalar(model))")
        }
        if let maxTurns = draft.maxTurns, maxTurns > 0 {
            lines.append("maxTurns: \(maxTurns)")
        }
        if draft.background {
            lines.append("background: true")
        }
        if !draft.inheritAllTools {
            let tools = draft.tools
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            lines.append("tools: \(tools.joined(separator: ", "))")
        }
        lines.append("---")
        lines.append("")
        lines.append(prompt)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func write(_ draft: SubagentProfileDraft, to fileURL: URL) throws {
        let markdown = try encode(draft)
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func fileURL(name: String, directory: URL) -> URL {
        directory.appendingPathComponent("\(name).md")
    }

    static func loadDirectory(_ directory: URL) -> [DiscoveredAgentDefinition] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { AgentDefinitionDiscovery.parse(file: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `tools:` omitted → inherit-all. An explicit empty `tools:` key is fail-closed.
    static func inheritsAllTools(markdown: String) -> Bool {
        guard markdown.hasPrefix("---") else { return true }
        let parts = markdown.split(separator: "---", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return true }
        let fields = String(parts[1])
        for line in fields.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("tools:")
                || trimmed.hasPrefix("allowed-tools:")
                || trimmed.hasPrefix("allowed_tools:") {
                return false
            }
        }
        return true
    }

    static func draft(from fileURL: URL) -> SubagentProfileDraft? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              let def = AgentDefinitionDiscovery.parse(markdown: text, fileURL: fileURL)
        else { return nil }
        return SubagentProfileDraft(definition: def, inheritAllTools: inheritsAllTools(markdown: text))
    }
}

func yamlScalar(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "\"\"" }
    let needsQuotes = trimmed.contains(where: { $0 == ":" || $0 == "#" || $0 == "\"" || $0 == "'" || $0.isWhitespace })
        || trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        || trimmed == "true" || trimmed == "false" || trimmed == "null"
        || Int(trimmed) != nil
    if !needsQuotes { return trimmed }
    let escaped = trimmed
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}
