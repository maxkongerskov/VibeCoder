//
//  ToolCallGrouping.swift
//
//  ZCode-parity (docs/ui-parity-research/zcode-chat.md §3): classify tools
//  into renderer families and collapse consecutive read-only calls into one
//  Explore card (N searches, N lists, N files). Pure functions so App/Sable
//  can render later — this file does not touch AgentLoop.swift.
//

import Foundation

/// Renderer families from ZCode `Qme` / `og`: file-read, file-write, shell,
/// search, explore, todo, skill, agent. Unknown names map to `other`.
public enum ToolFamily: String, Sendable, Equatable {
    case fileRead = "file-read"
    case fileWrite = "file-write"
    case shell
    case search
    case explore
    case todo
    case skill
    case agent
    case other
}

/// One tool event as the transcript would present it (name + in-flight bits).
public struct ToolCallEvent: Sendable, Equatable {
    public var name: String
    public var isRunning: Bool
    /// Parsed shell command when family is shell. Empty + running → skip.
    public var parsedCommand: String?

    public init(name: String, isRunning: Bool = false, parsedCommand: String? = nil) {
        self.name = name
        self.isRunning = isRunning
        self.parsedCommand = parsedCommand
    }
}

/// Explore card buckets (ZCode `chat.toolCall.explore.*`).
public struct ExploreBucketCounts: Sendable, Equatable {
    public var searches: Int
    public var lists: Int
    public var files: Int

    public init(searches: Int = 0, lists: Int = 0, files: Int = 0) {
        self.searches = searches
        self.lists = lists
        self.files = files
    }

    public var total: Int { searches + lists + files }
}

public enum GroupedToolCalls: Sendable, Equatable {
    /// Consecutive read-only tools → one Explore card.
    case explore(counts: ExploreBucketCounts, memberIndices: [Int])
    /// Write / shell / todo / skill / agent / other, shown as its own card.
    case standalone(index: Int, family: ToolFamily)
}

public enum ToolCallGrouping: Sendable {

    public static func family(forToolName name: String) -> ToolFamily {
        switch name {
        case "read_file", "read_file_range":
            return .fileRead
        case "write_file", "edit_file", "apply_patch", "delete_file",
             "move_file", "create_directory", "text_edit", "xcode_project_editor":
            return .fileWrite
        case "run_shell":
            return .shell
        case "grep_code", "grep", "glob_files", "glob",
             "web_search", "tool_search", "find_symbol", "memory_search", "apple_docs":
            return .search
        case "list_directory", "list_dir":
            return .explore
        case "update_todo":
            return .todo
        case "load_skill":
            return .skill
        case "task":
            return .agent
        default:
            return .other
        }
    }

    /// Read-only families that collapse into Explore (search / list / file).
    public static func isExploreMember(_ family: ToolFamily) -> Bool {
        switch family {
        case .fileRead, .search, .explore:
            return true
        default:
            return false
        }
    }

    /// ZCode: skip shells with empty parsed command while streaming/running.
    public static func shouldSkipInGrouping(_ event: ToolCallEvent) -> Bool {
        guard family(forToolName: event.name) == .shell, event.isRunning else {
            return false
        }
        let cmd = (event.parsedCommand ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cmd.isEmpty
    }

    /// Pure grouping over a list of tool call events.
    public static func group(_ events: [ToolCallEvent]) -> [GroupedToolCalls] {
        var out: [GroupedToolCalls] = []
        var i = 0
        while i < events.count {
            if shouldSkipInGrouping(events[i]) {
                i += 1
                continue
            }
            let fam = family(forToolName: events[i].name)
            if isExploreMember(fam) {
                var indices: [Int] = []
                var searches = 0
                var lists = 0
                var files = 0
                while i < events.count {
                    if shouldSkipInGrouping(events[i]) {
                        i += 1
                        continue
                    }
                    let f = family(forToolName: events[i].name)
                    guard isExploreMember(f) else { break }
                    indices.append(i)
                    switch f {
                    case .search: searches += 1
                    case .explore: lists += 1
                    case .fileRead: files += 1
                    default: break
                    }
                    i += 1
                }
                out.append(.explore(
                    counts: ExploreBucketCounts(searches: searches, lists: lists, files: files),
                    memberIndices: indices))
            } else {
                out.append(.standalone(index: i, family: fam))
                i += 1
            }
        }
        return out
    }

    /// Last group is a finished Explore burst (no in-flight members).
    public static func exploreBurstFinished(_ events: [ToolCallEvent]) -> Bool {
        let groups = group(events)
        guard let last = groups.last else { return false }
        guard case .explore(let counts, let members) = last else { return false }
        guard counts.total > 0 else { return false }
        return !members.contains(where: { events[$0].isRunning })
    }

    /// Stop-when-done: terminal PR merge banner, or explore burst ended
    /// so the model should speak instead of more identical probes.
    public static func shouldStopToolBurst(
        lastResultContent: String?,
        toolEvents: [ToolCallEvent]
    ) -> Bool {
        if GitHubPRStatusPolicy.shouldStopAfterMerged(lastResultContent) {
            return true
        }
        return exploreBurstFinished(toolEvents)
    }
}
