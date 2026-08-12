//
//  SlashCommandService.swift
//
//  Grok Build–parity slash commands for the composer. Detects text
//  starting with "/" and routes it to built-in session/model/mode
//  commands instead of sending it as a user message.
//
//  See ~/.grok/docs/user-guide/04-slash-commands.md for the CLI catalog.
//  This service advertises the subset that maps cleanly onto the macOS app.
//

import Foundation
import AgentCore

/// The result of attempting to parse and run a slash command.
enum SlashCommandResult: Equatable {
    /// The text was consumed as a command. `message` is optional
    /// feedback shown in the status line.
    case handled(message: String?)
    /// The text was NOT a slash command — send it as a normal message.
    case notACommand
}

/// A slash command definition (name + description for /help and autocomplete).
struct SlashCommand: Identifiable, Equatable {
    let name: String
    let description: String
    /// Optional argument hint shown in autocomplete (e.g. "[context]").
    let argumentHint: String
    /// Alternate names that resolve to the same handler (e.g. `/m` → `/model`).
    let aliases: [String]
    /// Category for /help grouping.
    let category: String

    var id: String { name }

    init(
        name: String,
        description: String,
        argumentHint: String = "",
        aliases: [String] = [],
        category: String = "Other"
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.aliases = aliases
        self.category = category
    }

    /// Primary name plus aliases, for matching.
    var allNames: [String] { [name] + aliases }
}

enum SlashCommandService {

    /// All available slash commands, for /help, autocomplete, and docs.
    static let allCommands: [SlashCommand] = [
        // Session
        SlashCommand(
            name: "/new",
            description: "Start a new conversation",
            category: "Session"),
        SlashCommand(
            name: "/clear",
            description: "Delete all messages in this conversation",
            category: "Session"),
        SlashCommand(
            name: "/compact",
            description: "Compress conversation history to free context window space",
            argumentHint: "[preserve context…]",
            category: "Session"),
        SlashCommand(
            name: "/context",
            description: "Show context window usage and category breakdown",
            category: "Session"),
        SlashCommand(
            name: "/session-info",
            description: "Show model, turn count, and context usage",
            category: "Session"),
        SlashCommand(
            name: "/fork",
            description: "Branch this conversation into a new chat with the same history",
            category: "Session"),
        SlashCommand(
            name: "/rewind",
            description: "Rewind last turn: restore agent-touched files + chat transcript",
            category: "Session"),
        SlashCommand(
            name: "/undo",
            description: "Undo last send: restore files from checkpoint + pre-send chat",
            category: "Session"),
        SlashCommand(
            name: "/restore-checkpoint",
            description: "Restore project files from the latest turn checkpoint (code only)",
            aliases: ["/restore"],
            category: "Session"),
        SlashCommand(
            name: "/copy",
            description: "Copy the latest assistant reply (or Nth-latest)",
            argumentHint: "[n]",
            category: "Session"),
        SlashCommand(
            name: "/export",
            description: "Export this conversation as Markdown",
            category: "Session"),
        SlashCommand(
            name: "/rename",
            description: "Rename this conversation",
            argumentHint: "<title>",
            aliases: ["/title"],
            category: "Session"),
        SlashCommand(
            name: "/home",
            description: "Return to a fresh chat",
            aliases: ["/welcome"],
            category: "Session"),
        SlashCommand(
            name: "/quit",
            description: "Quit the application",
            aliases: ["/exit"],
            category: "Session"),

        // Model & mode
        SlashCommand(
            name: "/model",
            description: "Switch model by name, or open the model picker",
            argumentHint: "[name]",
            aliases: ["/m"],
            category: "Model"),
        SlashCommand(
            name: "/effort",
            description: "Set reasoning effort on the current model",
            argumentHint: "<off|low|medium|high|max>",
            category: "Model"),
        SlashCommand(
            name: "/plan",
            description: "Enter Plan mode (read-only inspection)",
            argumentHint: "[description]",
            category: "Mode"),
        SlashCommand(
            name: "/view-plan",
            description: "Show the current session plan",
            aliases: ["/show-plan", "/plan-view"],
            category: "Mode"),
        SlashCommand(
            name: "/approve-plan",
            description: "Approve the plan checklist, switch to Ask mode, and continue the agent",
            aliases: ["/approve"],
            category: "Mode"),
        SlashCommand(
            name: "/stay-plan",
            description: "Keep Plan mode (do not start implementing)",
            aliases: ["/reject-plan"],
            category: "Mode"),
        SlashCommand(
            name: "/always-approve",
            description: "Toggle Full access (skip permission prompts)",
            category: "Mode"),
        SlashCommand(
            name: "/auto",
            description: "Toggle Auto edit mode (edit without per-file review)",
            category: "Mode"),

        // Goal
        SlashCommand(
            name: "/goal",
            description: "Set, check, pause, resume, or clear an autonomous goal",
            argumentHint: "<objective|status|pause|resume|clear>",
            category: "Goal"),

        // Memory / schedule
        SlashCommand(
            name: "/remember",
            description: "Save a note for this session (pinned into the next user turns)",
            argumentHint: "<note>",
            category: "Memory"),
        SlashCommand(
            name: "/loop",
            description: "Schedule a recurring prompt",
            argumentHint: "[interval] <prompt>",
            category: "Schedule"),

        // Git (Product S3)
        SlashCommand(
            name: "/commit",
            description: "Stage all changes and commit with a message",
            argumentHint: "<message>",
            aliases: ["/git-commit"],
            category: "Git"),
        SlashCommand(
            name: "/pr",
            description: "Open a GitHub pull request via gh (honest error if missing)",
            argumentHint: "<title> [| body…]",
            aliases: ["/pull-request", "/pull_request"],
            category: "Git"),

        // Skills (user-invocable; injects body without model calling load_skill)
        SlashCommand(
            name: "/skill",
            description: "Load a skill into the next message, or list skills",
            argumentHint: "[name] [args…]",
            aliases: ["/skills"],
            category: "Skills"),

        // Config / UI
        SlashCommand(
            name: "/settings",
            description: "Open Settings",
            aliases: ["/config", "/preferences", "/prefs"],
            category: "Config"),
        SlashCommand(
            name: "/mcps",
            description: "Open MCP server settings",
            category: "Config"),
        SlashCommand(
            name: "/history",
            description: "Show recent prompts (use ↑/↓ in an empty composer to cycle)",
            category: "Config"),
        SlashCommand(
            name: "/help",
            description: "List available slash commands",
            argumentHint: "[command]",
            aliases: ["/?"],
            category: "Config"),
    ]

    // MARK: - Parse

    /// Canonical command names (lowercase) → definition name as stored.
    private static let aliasMap: [String: String] = {
        var map: [String: String] = [:]
        for cmd in allCommands {
            for name in cmd.allNames {
                map[name.lowercased()] = cmd.name
            }
        }
        return map
    }()

    /// Parse a text string. If it starts with "/", extract the command
    /// name (first token) and remaining args. Aliases are resolved to
    /// the canonical command name.
    static func parse(_ text: String) -> (command: String, args: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let rawCommand = String(first).lowercased()
        let args = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        // Resolve aliases (e.g. /m → /model, /title → /rename).
        let command = aliasMap[rawCommand] ?? String(first)
        return (command, args)
    }

    /// Check if a text string is a slash command (for live preview
    /// without running it). Bare `/` alone is treated as "starting a command"
    /// for autocomplete, but not as a runnable command.
    static func isSlashCommand(_ text: String) -> Bool {
        parse(text) != nil
    }

    /// Whether the text is currently a slash-command draft (starts with `/`).
    static func isSlashDraft(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("/")
    }

    /// Canonical definition for a parsed command name, if known.
    static func command(named name: String) -> SlashCommand? {
        let key = name.lowercased()
        let canonical = aliasMap[key] ?? name
        return allCommands.first { $0.name.lowercased() == canonical.lowercased() }
    }

    // MARK: - Autocomplete

    /// Filter commands whose name/alias/description match the draft after `/`.
    /// Empty filter (just `/`) returns the full catalog.
    static func matchingCommands(draft: String, limit: Int = 12) -> [SlashCommand] {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return [] }

        // Only autocomplete while the user is still on the command token
        // (no space yet), or on bare `/`.
        if trimmed.contains(" "), trimmed != "/" {
            // After the first space, hide the menu — they're typing args.
            return []
        }

        let filter = String(trimmed.dropFirst()).lowercased() // drop leading /
        if filter.isEmpty {
            return Array(allCommands.prefix(limit))
        }

        // Prefer prefix matches on name/aliases, then substring, then description.
        var scored: [(Int, SlashCommand)] = []
        for cmd in allCommands {
            let names = cmd.allNames.map { $0.lowercased() }
            if let best = names.map({ score(query: filter, against: $0) }).min(),
               best < Int.max {
                scored.append((best, cmd))
                continue
            }
            let desc = cmd.description.lowercased()
            if desc.contains(filter) {
                scored.append((50 + filter.count, cmd))
            }
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1.name < rhs.1.name
            }
            .prefix(limit)
            .map(\.1)
    }

    /// Lower score = better. Prefix match on command body (without `/`) wins.
    private static func score(query: String, against fullName: String) -> Int {
        // fullName like "/compact" or "/m"
        let body = fullName.hasPrefix("/") ? String(fullName.dropFirst()) : fullName
        if body == query { return 0 }
        if body.hasPrefix(query) { return 1 }
        if fullName.hasPrefix("/" + query) || fullName.hasPrefix(query) { return 2 }
        if body.contains(query) { return 10 }
        if fullName.contains(query) { return 15 }
        // simple fuzzy: all query chars in order
        if fuzzyContains(haystack: body, needle: query) { return 25 }
        return Int.max
    }

    private static func fuzzyContains(haystack: String, needle: String) -> Bool {
        var i = haystack.startIndex
        for ch in needle {
            guard let found = haystack[i...].firstIndex(of: ch) else { return false }
            i = haystack.index(after: found)
        }
        return true
    }

    /// Help text for /help [command].
    static func helpText(filter: String = "") -> String {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            let needle = q.hasPrefix("/") ? q : "/" + q
            if let cmd = command(named: needle) {
                var lines = ["\(cmd.name) — \(cmd.description)"]
                if !cmd.argumentHint.isEmpty {
                    lines.append("  args: \(cmd.argumentHint)")
                }
                if !cmd.aliases.isEmpty {
                    lines.append("  aliases: \(cmd.aliases.joined(separator: ", "))")
                }
                return lines.joined(separator: "\n")
            }
            // Fall through to filtered list
        }

        let cmds: [SlashCommand]
        if q.isEmpty {
            cmds = allCommands
        } else {
            cmds = matchingCommands(draft: "/" + q, limit: 50)
        }

        var byCategory: [String: [SlashCommand]] = [:]
        var order: [String] = []
        for cmd in cmds {
            if byCategory[cmd.category] == nil {
                order.append(cmd.category)
            }
            byCategory[cmd.category, default: []].append(cmd)
        }

        var lines: [String] = ["Available commands:"]
        for cat in order {
            lines.append("")
            lines.append("\(cat):")
            for cmd in byCategory[cat] ?? [] {
                let hint = cmd.argumentHint.isEmpty ? "" : " \(cmd.argumentHint)"
                lines.append("  \(cmd.name)\(hint) — \(cmd.description)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - /skill

    /// Outcome of evaluating `/skill` / `/skills` without mutating UI state.
    enum SkillSlashOutcome: Equatable {
        /// Catalog listing (bare `/skill` or `/skills`).
        case list(String)
        /// Skill body ready to inject into the next user turn.
        case loaded(skillName: String, envelope: String, statusMessage: String)
        /// Unknown skill or bad usage.
        case failed(String)
    }

    /// Parse `/skill` arguments: first token = skill name, remainder = skill args
    /// (same split as `load_skill`'s `skill` + `args`).
    static func parseSkillArgs(_ args: String) -> (name: String, skillArgs: String)? {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let name = String(first)
        let skillArgs = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (name, skillArgs)
    }

    /// Human-readable catalog of discovered skills for `/skill` with no args.
    static func formatSkillCatalog(
        projectRoot: URL?,
        worktreeRoot: URL? = nil,
        includeBundled: Bool = true,
        home: URL? = nil
    ) -> String {
        let skills = SkillDiscovery.discover(
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            includeBundled: includeBundled,
            home: home
        )
        if skills.isEmpty {
            return """
            No skills discovered.
            Add `.vibecoder/skills/<name>/SKILL.md` (or `.grok` / `.claude` skills dirs).
            Usage: /skill <name> [args…]
            """
        }
        var lines: [String] = ["Available skills:"]
        for skill in skills {
            let desc = skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let oneLine = desc.isEmpty
                ? skill.name
                : "\(skill.name) — \(desc)"
            lines.append("  \(oneLine)  [\(skill.source.rawValue)]")
        }
        lines.append("")
        lines.append("Usage: /skill <name> [args…] — inject skill body into the next message")
        lines.append("(Same envelope as load_skill; no model tool call required.)")
        return lines.joined(separator: "\n")
    }

    /// Resolve a skill by name into the same `<skill>` envelope as `load_skill`.
    static func evaluateSkillCommand(
        args: String,
        projectRoot: URL?,
        worktreeRoot: URL? = nil,
        includeBundled: Bool = true,
        home: URL? = nil
    ) -> SkillSlashOutcome {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .list(formatSkillCatalog(
                projectRoot: projectRoot,
                worktreeRoot: worktreeRoot,
                includeBundled: includeBundled,
                home: home
            ))
        }
        guard let parsed = parseSkillArgs(trimmed) else {
            return .failed("Usage: /skill <name> [args…]")
        }
        guard let skill = SkillDiscovery.byName(
            parsed.name,
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            includeBundled: includeBundled,
            home: home
        ) else {
            let available = SkillDiscovery.discover(
                projectRoot: projectRoot,
                worktreeRoot: worktreeRoot,
                includeBundled: includeBundled,
                home: home
            )
            .map(\.name)
            .sorted()
            let list = available.isEmpty
                ? "(none — add .vibecoder/skills/<name>/SKILL.md)"
                : available.joined(separator: ", ")
            return .failed("Unknown skill '\(parsed.name)'. Available: \(list)")
        }
        let argsOpt: String? = parsed.skillArgs.isEmpty ? nil : parsed.skillArgs
        let envelope = SkillDiscovery.formatSkillMessage(skill, args: argsOpt)
        let status: String
        if let argsOpt {
            status = "Skill \"\(skill.name)\" loaded (args: \(argsOpt)) for next message."
        } else {
            status = "Skill \"\(skill.name)\" loaded for next message."
        }
        return .loaded(skillName: skill.name, envelope: envelope, statusMessage: status)
    }
}
