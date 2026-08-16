//
//  SubagentCatalog.swift
//
//  Grok Build–compatible subagent types, capability modes, and tool
//  allowlists for AgentOS. Spec mirrored from open-source
//  xai-org/grok-build (`xai-tool-types` task.rs): general-purpose,
//  explore, plan — with AgentOS tool names.
//

import Foundation

// MARK: - Capability mode

/// Controls which tool classes a child agent may use.
public enum SubagentCapabilityMode: String, Sendable, Codable, CaseIterable {
    case readOnly = "read-only"
    case readWrite = "read-write"
    case execute = "execute"
    case all = "all"

    public static func parse(_ raw: String?) -> SubagentCapabilityMode? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "read-only", "readonly", "read_only": return .readOnly
        case "read-write", "readwrite", "read_write": return .readWrite
        case "execute": return .execute
        case "all": return .all
        default: return nil
        }
    }

    /// Tool names allowed under this mode (before type-specific intersection).
    public var toolNames: Set<String> {
        switch self {
        case .readOnly:
            return SubagentCatalog.readOnlyTools
        case .readWrite:
            return SubagentCatalog.readOnlyTools.union(SubagentCatalog.writeTools)
        case .execute:
            return SubagentCatalog.readOnlyTools
                .union(SubagentCatalog.writeTools)
                .union(SubagentCatalog.executeTools)
        case .all:
            return SubagentCatalog.allToolsExceptTask
        }
    }
}

// MARK: - Isolation

public enum SubagentIsolationMode: String, Sendable, Codable, CaseIterable {
    case none = "none"
    case worktree = "worktree"

    public static func parse(_ raw: String?) -> SubagentIsolationMode {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return .none
        }
        switch raw {
        case "worktree", "work_tree", "work-tree": return .worktree
        default: return .none
        }
    }
}

// MARK: - Built-in types

/// Built-in subagent types advertised to the model (Grok Build parity).
public enum SubagentType: String, Sendable, CaseIterable {
    case generalPurpose = "general-purpose"
    case explore = "explore"
    case plan = "plan"

    public static func parse(_ raw: String?) -> SubagentType {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return .generalPurpose
        }
        switch raw {
        case "general-purpose", "general_purpose", "generalpurpose", "general":
            return .generalPurpose
        case "explore", "explorer", "search":
            return .explore
        case "plan", "planner", "architect":
            return .plan
        default:
            return .generalPurpose
        }
    }

    public var displayName: String { rawValue }

    public var shortDescription: String {
        switch self {
        case .generalPurpose:
            return "General purpose agent for multi-step tasks."
        case .explore:
            return "Fast, read-only agent specialized for codebase exploration."
        case .plan:
            return "Software architect for planning implementation strategies."
        }
    }

    /// Default capability when the model omits `capability_mode`.
    public var defaultCapability: SubagentCapabilityMode {
        switch self {
        case .generalPurpose: return .all
        case .explore, .plan: return .readOnly
        }
    }

    /// Type-default tool surface (intersected with capability mode).
    public var preferredTools: Set<String> {
        switch self {
        case .generalPurpose:
            return SubagentCatalog.allToolsExceptTask
        case .explore:
            return SubagentCatalog.exploreTools
        case .plan:
            return SubagentCatalog.planTools
        }
    }

    public var systemPrompt: String {
        switch self {
        case .generalPurpose:
            return SubagentCatalog.generalPurposePrompt
        case .explore:
            return SubagentCatalog.explorePrompt
        case .plan:
            return SubagentCatalog.planPrompt
        }
    }

    /// Effective allowlist: type preference ∩ capability ∩ never include `task`.
    public func allowedTools(capability: SubagentCapabilityMode?) -> Set<String> {
        let mode = capability ?? defaultCapability
        var set = preferredTools.intersection(mode.toolNames)
        set.remove("task")
        return set
    }
}

// MARK: - Catalog

public enum SubagentCatalog {

    public static let readOnlyTools: Set<String> = [
        "read_file", "list_directory", "glob_files", "grep_code",
        "fetch_url", "web_search", "git_status", "git_diff", "apple_docs",
    ]

    public static let writeTools: Set<String> = [
        "write_file", "edit_file", "apply_patch", "create_directory",
        "delete_file", "move_file",
    ]

    public static let executeTools: Set<String> = [
        "run_shell",
        "build_xcode", "xcode_build", "run_xcode_tests",
        "swift_check", "build_swift_package",
    ]

    public static let planTools: Set<String> = [
        "read_file", "list_directory", "glob_files", "grep_code",
        "fetch_url", "web_search", "git_status", "git_diff",
        "create_plan", "update_todo", "revise_plan",
    ]

    public static let exploreTools: Set<String> = [
        "read_file", "list_directory", "glob_files", "grep_code",
        "git_status", "git_diff",
    ]

    /// Everything the parent may expose to general-purpose, minus recursive spawn.
    public static let allToolsExceptTask: Set<String> = {
        var s = readOnlyTools
            .union(writeTools)
            .union(executeTools)
            .union(planTools)
        s.remove("task")
        return s
    }()

    // Prompts adapted from Grok Build `xai-tool-types` task.rs
    // (tool placeholders resolved to AgentOS tool names).

    public static let generalPurposePrompt = """
    Complete the assigned task directly. Do what was asked; nothing more, nothing less. \
    Respond with a detailed writeup when done.

    Strengths:
    - Searching across large codebases for code, configurations, and patterns
    - Multi-file analysis and architecture investigation
    - Multi-step research requiring exploration of many files

    Guidelines:
    - Use grep_code / glob_files / list_directory for broad searches; read_file for known paths.
    - Start broad and narrow down. Try multiple search strategies.
    - Be thorough: check multiple locations, consider different naming conventions.
    - NEVER create files unless absolutely necessary. Prefer editing existing files.
    - NEVER create documentation files (*.md) unless explicitly requested.
    - Return absolute file paths and relevant code snippets in your final response.
    - Do NOT call the `task` tool. Sub-agents cannot spawn sub-sub-agents.

    Workspace boundary:
    - Default scope is the project workspace. Stay within it unless told otherwise.
    """

    public static let explorePrompt = """
    You are a fast, read-only codebase exploration agent.

    === READ-ONLY MODE ===
    You have NO file editing tools. Do not create, modify, or delete files. \
    Do not run shell commands that mutate the system.

    Strengths:
    - Rapidly finding files using glob patterns
    - Searching code with regex patterns
    - Reading and analyzing file contents

    Guidelines:
    - Use list_directory / glob_files for file pattern matching, grep_code for content search, read_file for known paths.
    - Maximize parallel tool calls for speed when the parent loop allows.
    - Return absolute file paths in your final response.
    - Be CONCISE. Your final answer goes back to the parent agent.
    - Do NOT call the `task` tool.

    Workspace boundary:
    - Your default search scope is the project workspace. Do not search outside it unless asked.
    """

    public static let planPrompt = """
    You are a read-only software architect. Explore the codebase and design implementation plans.

    === READ-ONLY MODE ===
    You have NO file editing tools. Do not create, modify, or delete files.

    Process:
    1. Understand the requirements and any assigned perspective.
    2. Explore: read provided files, find patterns with glob_files/grep_code/read_file, trace relevant code paths.
    3. Design: consider trade-offs, follow existing patterns, create implementation approach.
    4. Detail: step-by-step strategy, dependencies, sequencing, potential challenges.

    ## Required Output

    End your response with:

    ### Critical Files for Implementation
    List 3-5 files most critical for implementing this plan:
    - path/to/file1 - [Brief reason]
    - path/to/file2 - [Brief reason]
    - path/to/file3 - [Brief reason]

    Do NOT call the `task` tool.

    Workspace boundary:
    - Stay within the project workspace unless asked otherwise.
    """

    /// Model-facing description block for the `task` tool schema.
    public static var taskToolDescription: String {
        """
        Launch a subagent to handle a focused task autonomously. Built-in types:
        - general-purpose: multi-step research / implementation (full tools except nested task)
        - explore: fast read-only codebase exploration
        - plan: read-only architecture / implementation planning

        You MUST set subagent_type. Prefer explore for finding files/code; plan for design; \
        general-purpose for multi-step work that may edit files.

        When launching multiple independent subagents, emit multiple `task` tool calls in a \
        single assistant message so they run concurrently. `run_in_background: true` still works.

        A new task starts fresh — the prompt must be self-contained (include all context the \
        subagent needs; it does not see the parent transcript).

        Default: foreground — waits and returns the subagent's final report. \
        Set run_in_background=true (or background=true) to return task_id immediately; \
        then use get_task_output / wait_tasks / kill_task. Subagents cannot spawn further subagents.

        To resume a completed subagent after send_message, pass resume_agent_id (agent_<uuid>) \
        instead of starting a new spawn.
        """
    }
}
