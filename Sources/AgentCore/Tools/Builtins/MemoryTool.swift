//
//  MemoryTool.swift
//
//  Project-memory writer. Maintains two markdown files at the project root:
//
//    • DECISIONS.md        — append-only log of non-obvious design choices.
//    • SESSION_HANDOFF.md  — single-file rollup written at the end of a
//                            long session, overwritten each time.
//
//  Both files used to be auto-injected into the system prompt on the next
//  session so the agent doesn't re-litigate settled decisions.
//
//  Exposed as one tool with an `action` discriminator:
//    - action="log_decision"  → append to DECISIONS.md
//    - action="write_handoff" → overwrite SESSION_HANDOFF.md
//    - action="read"          → read whichever file the caller names
//

import Foundation

public struct MemoryTool: Tool {
    public static let name = "memory"
    public static let category: ToolCategory = .memory
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Persist project memory across sessions. Actions:
          • log_decision  — append a Decision/Rationale/Avoid entry to DECISIONS.md.
          • write_handoff — overwrite SESSION_HANDOFF.md with a summary, current \
        state, and next steps.
          • read          — read DECISIONS.md or SESSION_HANDOFF.md (specify via `file`).
          • remember      — write durable text into workspace memory index (Grok-class).
        Files live at the project root unless `path` is provided.
        """,
        parameters: .init(
            properties: [
                "action": .init(
                    type: "string",
                    description: "One of: log_decision, write_handoff, read, remember.",
                    enum: ["log_decision", "write_handoff", "read", "remember"]
                ),
                "decision":     .init(type: "string", description: "log_decision: the design choice."),
                "rationale":    .init(type: "string", description: "log_decision: why this choice."),
                "avoid":        .init(type: "string", description: "log_decision: optional 'don't do X' note."),
                "summary":      .init(type: "string", description: "write_handoff: what was accomplished."),
                "currentState": .init(type: "string", description: "write_handoff: current build/test state."),
                "nextSteps":    .init(type: "string", description: "write_handoff: priority-ordered TODOs."),
                "text":         .init(type: "string", description: "remember: durable fact/note to store in workspace memory."),
                "file": .init(
                    type: "string",
                    description: "read: which memory file to read (decisions, handoff, or memory).",
                    enum: ["decisions", "handoff", "memory"]
                ),
                "path": .init(type: "string", description: "Optional override for the target file path.")
            ],
            required: ["action"]
        )
    )

    /// Header written exactly once, the first time DECISIONS.md is created.
    public static let decisionsHeader = """
    # Design Decisions

    This file is maintained automatically. Each entry records a non-obvious design choice with its rationale so future sessions don't re-litigate settled decisions.

    """

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let actionRaw = try arguments.string("action").lowercased()
        let action = actionRaw == "log_design_decision" ? "log_decision" : actionRaw
        let base = context.workingDirectory

        switch action {
        case "log_decision":
            return logDecision(arguments: arguments, base: base)
        case "write_handoff":
            return writeHandoff(arguments: arguments, base: base)
        case "read":
            return readMemory(arguments: arguments, base: base)
        case "remember":
            return remember(arguments: arguments, base: base)
        default:
            return ToolResult(
                content: "Unknown action '\(action)'. Use log_decision, write_handoff, read, or remember.",
                isError: true
            )
        }
    }

    // MARK: - log_decision

    private func logDecision(arguments: ToolArguments, base: URL) -> ToolResult {
        let decision  = (arguments.stringOptional("decision")  ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rationale = (arguments.stringOptional("rationale") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let avoid     = (arguments.stringOptional("avoid")     ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !decision.isEmpty, !rationale.isEmpty else {
            return ToolResult(
                content: "Error: `decision` and `rationale` are both required for log_decision.",
                isError: true
            )
        }

        let url = resolveMemoryPath(arguments.stringOptional("path"),
                                    defaultName: "DECISIONS.md",
                                    base: base)
        let timestamp = isoTimestamp()
        var entry = "\n---\n\n## \(timestamp)\n\n**Decision:** \(decision)\n\n**Rationale:** \(rationale)\n"
        if !avoid.isEmpty { entry += "\n**Avoid:** \(avoid)\n" }

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try MemoryTool.decisionsHeader.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return ToolResult(content: "Error creating \(url.path): \(error.localizedDescription)",
                                  isError: true)
            }
        }

        guard let handle = try? FileHandle(forWritingTo: url) else {
            return ToolResult(content: "Error: could not open \(url.path) for writing.",
                              isError: true)
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            if let data = entry.data(using: .utf8) { try handle.write(contentsOf: data) }
        } catch {
            return ToolResult(content: "Error appending to \(url.path): \(error.localizedDescription)",
                              isError: true)
        }
        var note = decision
        if !rationale.isEmpty { note += "\nRationale: \(rationale)" }
        if !avoid.isEmpty { note += "\nAvoid: \(avoid)" }
        return MemoryUpdateReminder.result(
            content: "Decision logged to \(url.path).",
            action: "log_decision",
            body: note,
            mutatedPaths: [relativePath(url, base: base)]
        )
    }

    // MARK: - write_handoff

    private func writeHandoff(arguments: ToolArguments, base: URL) -> ToolResult {
        let summary      = (arguments.stringOptional("summary")      ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let nextSteps    = (arguments.stringOptional("nextSteps")    ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let currentState = (arguments.stringOptional("currentState") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !summary.isEmpty else {
            return ToolResult(content: "Error: `summary` is required for write_handoff.", isError: true)
        }

        let url = resolveMemoryPath(arguments.stringOptional("path"),
                                    defaultName: "SESSION_HANDOFF.md",
                                    base: base)

        let timestamp = isoTimestamp()
        let dateOnly  = String(timestamp.prefix(10))
        let stateSection = currentState.isEmpty ? "Not recorded." : currentState
        let nextSection  = nextSteps.isEmpty    ? "Not recorded." : nextSteps

        let content = """
        # Session Handoff — \(dateOnly)

        > Generated at \(timestamp). Read this before making any changes in a new session.

        ## What Was Done

        \(summary)

        ## Current Build / Test State

        \(stateSection)

        ## Next Steps (in priority order)

        \(nextSection)

        ---
        *Read DECISIONS.md for architectural context on past choices.*
        """

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return MemoryUpdateReminder.result(
                content: "Session handoff written to \(url.path).",
                action: "write_handoff",
                body: summary,
                mutatedPaths: [relativePath(url, base: base)]
            )
        } catch {
            return ToolResult(content: "Error writing handoff: \(error.localizedDescription)",
                              isError: true)
        }
    }

    // MARK: - read

    private func readMemory(arguments: ToolArguments, base: URL) -> ToolResult {
        let url: URL
        if let path = arguments.stringOptional("path"), !path.isEmpty {
            url = resolvePath(path, base: base)
        } else {
            let which = (arguments.stringOptional("file") ?? "decisions").lowercased()
            let name: String
            switch which {
            case "handoff": name = "SESSION_HANDOFF.md"
            case "memory": name = "MEMORY.md"
            default: name = "DECISIONS.md"
            }
            url = base.appendingPathComponent(name)
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return ToolResult(content: "Error: could not read \(url.path).", isError: true)
        }
        return ToolResult(content: text)
    }


    // MARK: - remember

    private func remember(arguments: ToolArguments, base: URL) -> ToolResult {
        let text = (arguments.stringOptional("text")
            ?? arguments.stringOptional("decision")
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return ToolResult(content: "Error: `text` is required for remember.", isError: true)
        }
        do {
            let backend = MemoryBackend(workspacePath: base)
            try backend.remember(text: text, scope: .workspace)
            // Keep DECISIONS.md human-readable export when rationale present
            if let rationale = arguments.stringOptional("rationale"), !rationale.isEmpty {
                _ = logDecision(arguments: arguments, base: base)
            }
            return MemoryUpdateReminder.result(
                content: "Remembered in workspace memory (\(text.prefix(80))…).",
                action: "remember",
                body: text
            )
        } catch {
            return ToolResult(content: "Error remembering: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Helpers

    private func resolveMemoryPath(_ override: String?, defaultName: String, base: URL) -> URL {
        if let p = override, !p.isEmpty {
            return resolvePath(p, base: base)
        }
        return base.appendingPathComponent(defaultName)
    }

    private func relativePath(_ url: URL, base: URL) -> String {
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        if url.path.hasPrefix(basePath) {
            return String(url.path.dropFirst(basePath.count))
        }
        return url.path
    }

    private func isoTimestamp(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.string(from: now)
    }
}
