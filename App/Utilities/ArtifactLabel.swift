//
//  ArtifactLabel.swift
//
//  Pure helpers: map tool names + JSON args to human labels and artifact kinds.

import Foundation
import AgentCore

enum ArtifactLabel {

    static let excludedFromRail: Set<String> = [
        "create_plan", "update_todo", "revise_plan", "tool_search", "ask_user", "task",
    ]

    static func shouldShowInRail(toolName: String) -> Bool {
        !excludedFromRail.contains(toolName)
    }

    struct Descriptor: Equatable {
        var title: String
        var subtitle: String?
        var kind: ArtifactCard.Kind
    }

    static func make(toolName: String, argsJSON: String, output: String) -> Descriptor {
        let args = ChatLoop.parseToolArgs(argsJSON)
        let path = (args["path"] as? String) ?? (args["file_path"] as? String) ?? ""
        let fileName = path.isEmpty ? nil : URL(fileURLWithPath: path).lastPathComponent

        switch toolName {
        case "read_file", "read_file_range":
            let name = fileName ?? "file"
            return Descriptor(
                title: "Reading \(name)",
                subtitle: path.isEmpty ? nil : path,
                kind: .filePreview(path: path.isEmpty ? name : path)
            )

        case "write_file":
            let name = fileName ?? "file"
            return Descriptor(
                title: "Writing \(name)",
                subtitle: diffLineSubtitle(output),
                kind: .diff(path: path.isEmpty ? name : path)
            )

        case "edit_file", "apply_patch":
            let name = fileName ?? "file"
            return Descriptor(
                title: "Editing \(name)",
                subtitle: diffLineSubtitle(output),
                kind: .diff(path: path.isEmpty ? name : path)
            )

        case "run_shell", "run_shell_command":
            let cmd = (args["command"] as? String) ?? ""
            let short = truncate(cmd, max: 48)
            return Descriptor(
                title: short.isEmpty ? "Running shell command" : "Running \(short)",
                subtitle: exitCodeSubtitle(output),
                kind: .terminal(command: cmd)
            )

        case "build_xcode", "run_xcode_tests", "swift_check", "get_build_log",
             "build_swift_package", "build_cargo", "build_npm", "xcode_build":
            let scheme = (args["scheme"] as? String) ?? ""
            let label = toolName.replacingOccurrences(of: "_", with: " ")
            return Descriptor(
                title: scheme.isEmpty ? label.capitalized : "\(label) — \(scheme)",
                subtitle: exitCodeSubtitle(output),
                kind: .terminal(command: scheme.isEmpty ? toolName : "\(toolName) \(scheme)")
            )

        case "grep_code", "glob_files", "code_search":
            let query = (args["pattern"] as? String)
                ?? (args["query"] as? String)
                ?? (args["glob"] as? String)
                ?? ""
            return Descriptor(
                title: query.isEmpty ? "Searching code" : "Search: \(truncate(query, max: 40))",
                subtitle: matchCountSubtitle(output),
                kind: .searchResults(query: query)
            )

        case "web_search":
            // Status only — ActivityLine verb is already "Search".
            let q = (args["query"] as? String) ?? ""
            return Descriptor(
                title: q.isEmpty ? "web" : truncate(q, max: 40),
                subtitle: nil,
                kind: .webResult(title: q.isEmpty ? "Web search" : q)
            )

        case "fetch_url":
            let url = (args["url"] as? String) ?? ""
            return Descriptor(
                title: url.isEmpty ? "Fetching URL" : "Fetch: \(truncate(url, max: 40))",
                subtitle: nil,
                kind: .webResult(title: url.isEmpty ? "Fetched page" : url)
            )

        case "git_diff":
            return Descriptor(
                title: "Git diff",
                subtitle: diffLineSubtitle(output),
                kind: .diff(path: (args["path"] as? String) ?? "repository")
            )

        case "task":
            // Status only — verb "Agent" is supplied by ActivityLine.
            // Avoid "Agent · Agent · …" double prefix in the transcript.
            let desc = (args["description"] as? String) ?? ""
            let subtype = (args["subagent_type"] as? String) ?? "general-purpose"
            let title = desc.isEmpty
                ? subtype
                : truncate(desc, max: 40)
            return Descriptor(
                title: title,
                subtitle: subtype,
                kind: .toolOutput
            )

        default:
            let human = toolName.replacingOccurrences(of: "_", with: " ")
            return Descriptor(
                title: human.capitalized,
                subtitle: fileName,
                kind: .toolOutput
            )
        }
    }

    /// Short label for the pending-assistant status line while a tool runs.
    static func activityLabel(toolName: String, argsJSON: String) -> String {
        make(toolName: toolName, argsJSON: argsJSON, output: "").title
    }

    // MARK: - Private

    private static func truncate(_ s: String, max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return String(t.prefix(max - 1)) + "…"
    }

    private static func diffLineSubtitle(_ output: String) -> String? {
        guard !output.isEmpty else { return nil }
        let lines = output.split(whereSeparator: \.isNewline).count
        return lines > 0 ? "\(lines) lines" : nil
    }

    private static func matchCountSubtitle(_ output: String) -> String? {
        guard !output.isEmpty else { return nil }
        let lines = output.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.count
        return lines > 0 ? "\(lines) matches" : nil
    }

    private static func exitCodeSubtitle(_ output: String) -> String? {
        if output.lowercased().contains("error") || output.contains("exit code") {
            return "See output"
        }
        return nil
    }
}