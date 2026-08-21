//
//  SlashCommandDispatcher.swift
//
//  Parse → route slash commands and return SlashCommandResult.
//  ChatViewModel is the host (status line, model, compact, undo, session).
//  Git commit/PR run here via GitWorkflow so the switch does not live
//  inline in the frozen VM.
//

import Foundation

/// The result of attempting to parse and run a slash command.
public enum SlashCommandResult: Equatable, Sendable {
    /// The text was consumed as a command. `message` is optional
    /// feedback shown in the status line.
    case handled(message: String?)
    /// Markdown custom command expanded — send this string as the user turn.
    case expandToMessage(String)
    /// The text was NOT a slash command — send it as a normal message.
    case notACommand
}

/// Session/model/mode/git actions the dispatcher cannot own.
@MainActor
public protocol SlashCommandHost: AnyObject {
    /// Project or worktree cwd for `/commit` and `/pr`.
    var slashWorkingDirectory: URL? { get }
    /// Project root for custom-command discovery.
    var slashProjectRoot: URL? { get }

    func slashSetStatusLine(_ text: String)

    func slashNewConversation()
    func slashClearConversation()
    func slashHome()
    func slashFork() -> String
    func slashRename(to title: String) -> String
    func slashExport()
    func slashQuit()
    func slashOpenSettings(pane: String?)
    func slashHistoryPreview() -> String
    func slashContextUsage() -> String
    func slashSessionInfo() -> String

    func slashCompact(preserve: String) -> SlashCommandResult
    func slashUndo() -> SlashCommandResult
    func slashRewind() -> SlashCommandResult
    func slashRestoreCheckpoint() -> SlashCommandResult
    func slashCopy(nth: String) -> SlashCommandResult

    func slashModel(args: String) -> SlashCommandResult
    func slashEffort(args: String) -> SlashCommandResult

    func slashPlan(args: String) -> SlashCommandResult
    func slashViewPlan() -> SlashCommandResult
    func slashApprovePlan()
    func slashStayPlan()
    func slashToggleAlwaysApprove() -> SlashCommandResult
    func slashToggleAuto() -> SlashCommandResult

    func slashGoal(args: String) -> SlashCommandResult
    func slashRemember(args: String) -> SlashCommandResult
    func slashSkill(args: String) -> SlashCommandResult
    func slashLoop(args: String) -> SlashCommandResult

    func slashHelpText(filter: String) -> String
    func slashExpandCustomCommand(name: String, args: String) -> String?
}

/// Parse + route slash commands. ChatViewModel delegates `handleSlashCommand` here.
public enum SlashCommandDispatcher: Sendable {

    /// Canonical name (e.g. `/model`) for aliases (e.g. `/m`).
    public static let aliasMap: [String: String] = [
        "/restore": "/restore-checkpoint",
        "/title": "/rename",
        "/welcome": "/home",
        "/exit": "/quit",
        "/m": "/model",
        "/show-plan": "/view-plan",
        "/plan-view": "/view-plan",
        "/approve": "/approve-plan",
        "/reject-plan": "/stay-plan",
        "/git-commit": "/commit",
        "/pull-request": "/pr",
        "/pull_request": "/pr",
        "/skills": "/skill",
        "/config": "/settings",
        "/preferences": "/settings",
        "/prefs": "/settings",
        "/?": "/help",
    ]

    /// Built-in canonical names the dispatcher routes (not custom markdown commands).
    public static let knownCommands: Set<String> = [
        "/new", "/clear", "/compact", "/context", "/session-info", "/fork",
        "/rewind", "/undo", "/restore-checkpoint", "/copy", "/export",
        "/rename", "/home", "/quit", "/model", "/effort", "/plan",
        "/view-plan", "/approve-plan", "/stay-plan", "/always-approve",
        "/auto", "/goal", "/remember", "/loop", "/commit", "/pr",
        "/skill", "/settings", "/mcps", "/history", "/help",
    ]

    /// Parse a text string. If it starts with "/", extract the command
    /// name (first token) and remaining args. Aliases are resolved to
    /// the canonical command name.
    public static func parse(_ text: String) -> (command: String, args: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let rawCommand = String(first).lowercased()
        let args = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        let command = aliasMap[rawCommand] ?? String(first)
        return (command, args)
    }

    /// Route `text` to a built-in handler, custom-command expansion, or `.notACommand`.
    @MainActor
    public static func dispatch(_ text: String, host: any SlashCommandHost) -> SlashCommandResult {
        guard let parsed = parse(text) else {
            return .notACommand
        }
        let canonical = parsed.command.lowercased()
        if !knownCommands.contains(canonical) {
            if let expanded = host.slashExpandCustomCommand(
                name: parsed.command,
                args: parsed.args
            ) {
                return .expandToMessage(expanded)
            }
            return .notACommand
        }

        switch canonical {
        case "/new":
            host.slashNewConversation()
            return .handled(message: "Started a new conversation.")

        case "/clear":
            host.slashClearConversation()
            return .handled(message: "Cleared all messages.")

        case "/home":
            host.slashHome()
            return .handled(message: "Returned home.")

        case "/compact":
            return host.slashCompact(preserve: parsed.args)

        case "/context":
            return .handled(message: host.slashContextUsage())

        case "/session-info":
            return .handled(message: host.slashSessionInfo())

        case "/fork":
            return .handled(message: host.slashFork())

        case "/rewind":
            return host.slashRewind()

        case "/undo":
            return host.slashUndo()

        case "/restore-checkpoint":
            return host.slashRestoreCheckpoint()

        case "/copy":
            return host.slashCopy(nth: parsed.args)

        case "/export":
            host.slashExport()
            return .handled(message: "Opening export…")

        case "/rename":
            let title = parsed.args.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return .handled(message: "Usage: /rename <new title>")
            }
            return .handled(message: host.slashRename(to: title))

        case "/quit":
            host.slashQuit()
            return .handled(message: "Quitting…")

        case "/model":
            return host.slashModel(args: parsed.args)

        case "/effort":
            return host.slashEffort(args: parsed.args)

        case "/plan":
            return host.slashPlan(args: parsed.args)

        case "/view-plan":
            return host.slashViewPlan()

        case "/approve-plan":
            host.slashApprovePlan()
            return .handled(message: "Approving plan — switching to Ask mode and continuing…")

        case "/stay-plan":
            host.slashStayPlan()
            return .handled(message: "Staying in Plan mode.")

        case "/always-approve":
            return host.slashToggleAlwaysApprove()

        case "/auto":
            return host.slashToggleAuto()

        case "/goal":
            return host.slashGoal(args: parsed.args)

        case "/remember":
            return host.slashRemember(args: parsed.args)

        case "/skill":
            return host.slashSkill(args: parsed.args)

        case "/loop":
            return host.slashLoop(args: parsed.args)

        case "/settings":
            host.slashOpenSettings(pane: nil)
            return .handled(message: "Opening Settings…")

        case "/mcps":
            host.slashOpenSettings(pane: "mcp")
            return .handled(message: "Opening MCP settings…")

        case "/history":
            return .handled(message: host.slashHistoryPreview())

        case "/help":
            let help = host.slashHelpText(filter: parsed.args)
            host.slashSetStatusLine("Slash command help")
            return .handled(message: help)

        case "/commit":
            return commit(args: parsed.args, host: host)

        case "/pr":
            return pullRequest(args: parsed.args, host: host)

        default:
            return .notACommand
        }
    }

    /// `/commit <message>` — stage all + commit in project/worktree.
    @MainActor
    public static func commit(
        args: String,
        host: any SlashCommandHost
    ) -> SlashCommandResult {
        let message = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return .handled(message: "Usage: /commit <message>")
        }
        guard let cwd = host.slashWorkingDirectory else {
            return .handled(message: "No project open — open a folder before /commit.")
        }
        let result = GitWorkflow.commit(
            message: message,
            workingDirectory: cwd,
            stageAll: true)
        host.slashSetStatusLine(result.success ? "Committed" : "Commit failed")
        return .handled(message: result.display)
    }

    /// `/pr <title> [| body…]` — create PR via `gh` when available.
    @MainActor
    public static func pullRequest(
        args: String,
        host: any SlashCommandHost
    ) -> SlashCommandResult {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return .handled(message: "Usage: /pr <title> [| optional body]")
        }
        guard let cwd = host.slashWorkingDirectory else {
            return .handled(message: "No project open — open a folder before /pr.")
        }
        let title: String
        let body: String?
        if let pipe = raw.range(of: " | ") {
            title = String(raw[..<pipe.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            body = String(raw[pipe.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = raw
            body = nil
        }
        let result = GitWorkflow.createPullRequest(
            title: title,
            body: body,
            workingDirectory: cwd)
        host.slashSetStatusLine(result.success ? "PR created" : "PR failed")
        return .handled(message: result.display)
    }
}
