//
//  ToolOffer.swift
//
//  Default coding-agent tool surface + Settings templates.
//  Tools stay registered; this only decides which names start enabled.
//

import Foundation

/// Default offer and Settings templates for the agent `tools:` array.
///
/// Missing `AppSettings.toolEnabled` keys use **Recommended** (not "on").
/// MCP / unknown dynamic names are not in `catalogNames` and stay enabled.
public enum ToolOffer: Sendable {

    /// Fast coding core. Settings template "Recommended".
    /// Matches `docs/LEAD_PLAN.md` §4. `tool_search` is how extras come back.
    public static let recommendedNames: Set<String> = [
        "read_file", "write_file", "edit_file", "apply_patch",
        "list_directory", "glob_files", "grep_code", "find_symbol",
        "run_shell",
        "git_status", "git_diff", "git_commit",
        "xcode_build",
        "create_plan", "update_todo", "revise_plan",
        "tool_search", "read_session_context",
    ]

    /// `ToolRegistry.registerBuiltins()` names (no app-hosted PDF).
    public static let builtinNames: Set<String> = [
        "read_file", "write_file", "edit_file", "apply_patch",
        "list_directory", "grep_code", "glob_files", "run_shell",
        "git_status", "git_diff", "git_commit", "create_pull_request", "tool_search",
        "web_search", "fetch_url", "apple_docs", "fetch_rss",
        "delete_file", "move_file", "create_directory",
        "xcode_build", "xcode_project_editor",
        "create_plan", "update_todo", "revise_plan", "ask_user",
        "enter_plan_mode", "exit_plan_mode",
        "cron_create", "cron_list", "cron_update", "cron_delete",
        "task", "get_task_output", "wait_tasks", "kill_task",
        "list_background_jobs", "monitor_jobs", "send_message",
        "memory", "memory_search", "memory_get", "read_session_context", "find_symbol",
        "load_skill",
        "restore_checkpoint",
        "screenshot", "click", "type", "scroll",
        "browser_navigate", "browser_snapshot", "browser_click", "browser_type",
    ]

    /// App-hosted PDF tools (`PDFToolRegistration`).
    public static let pdfNames: Set<String> = [
        "extract_pdf_text", "ocr_image", "create_pdf",
        "manipulate_pdf", "fill_pdf_form", "sign_pdf",
    ]

    /// Builtins + PDF — Settings catalog / default-off extras.
    public static var catalogNames: Set<String> {
        builtinNames.union(pdfNames)
    }

    public static var defaultOffNames: Set<String> {
        catalogNames.subtracting(recommendedNames)
    }

    public enum Template: String, Sendable, CaseIterable, Identifiable {
        case recommended
        case all

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .recommended: return "Recommended"
            case .all: return "All tools"
            }
        }

        public var detail: String {
            switch self {
            case .recommended:
                return "Coding core (\(ToolOffer.recommendedNames.count) tools) for a fast local agent. Everything else stays installed — turn a tool on when you need it."
            case .all:
                return "Every catalog tool on the wire. Heavier first token and noisier tool choice on local models. Computer-use and browser-use still need their master switches."
            }
        }
    }

    public static func isRecommended(_ name: String) -> Bool {
        recommendedNames.contains(name)
    }

    /// Missing key → Recommended default (on only if in `recommendedNames`).
    public static func isEnabled(name: String, explicit: [String: Bool]) -> Bool {
        if let value = explicit[name] { return value }
        return recommendedNames.contains(name)
    }

    /// Catalog extras start off. Explicit true/false wins. Names outside
    /// `catalogNames` (MCP, future dynamic tools) are not disabled here.
    public static func disabledNames(
        explicit: [String: Bool],
        catalogNames: Set<String> = ToolOffer.catalogNames
    ) -> Set<String> {
        var disabled = catalogNames.subtracting(recommendedNames)
        for (name, on) in explicit {
            if on {
                disabled.remove(name)
            } else {
                disabled.insert(name)
            }
        }
        return disabled
    }

    public static func enabledMap(
        template: Template,
        catalogNames: Set<String> = ToolOffer.catalogNames
    ) -> [String: Bool] {
        var map: [String: Bool] = [:]
        map.reserveCapacity(catalogNames.count)
        for name in catalogNames {
            switch template {
            case .recommended:
                map[name] = recommendedNames.contains(name)
            case .all:
                map[name] = true
            }
        }
        return map
    }

    /// `nil` when the map is a custom mix (not exactly Recommended or All).
    public static func matchingTemplate(
        explicit: [String: Bool],
        catalogNames: Set<String> = ToolOffer.catalogNames
    ) -> Template? {
        let onCount = catalogNames.filter { isEnabled(name: $0, explicit: explicit) }.count
        if onCount == catalogNames.count { return .all }
        let recommendedOn = catalogNames.filter { recommendedNames.contains($0) }.count
        if onCount == recommendedOn,
           catalogNames.allSatisfy({ name in
               isEnabled(name: name, explicit: explicit) == recommendedNames.contains(name)
           }) {
            return .recommended
        }
        return nil
    }
}
