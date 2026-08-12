//
//  RunShellTool.swift
//
//  Run a shell command. Safe Mode + authorization pipeline gate this.
//  Supports background: true → returns task_id for get/wait/kill.
//

import Foundation

public struct RunShellTool: Tool {
    public static let name = "run_shell"
    public static let category: ToolCategory = .shell
    public static let permission: ToolPermission = .executes
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Run a shell command. Working directory is the project (or worktree) root. \
        Output is truncated past maxBytes. Set background=true to return a task_id \
        immediately and continue the conversation; use get_task_output / wait_tasks / kill_task.
        """,
        parameters: .init(
            properties: [
                "command": .init(type: "string", description: "The shell command (passed to /bin/zsh -c)."),
                "timeoutSeconds": .init(type: "integer", description: "Hard timeout. Default 60 (foreground) or 3600 (background)."),
                "maxBytes": .init(type: "integer", description: "Max bytes of combined stdout+stderr to return. Default 65536."),
                "background": .init(type: "boolean", description: "If true, run in background and return task_id immediately.")
            ],
            required: ["command"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let command = try arguments.string("command")
        let background = arguments.bool("background", default: false)
        let maxBytes = arguments.intOptional("maxBytes") ?? 65_536

        // PB8: optional seatbelt write fence (sandbox-exec). See SafeBash.
        let launch = SafeBash.resolveShellLaunch(
            command: command,
            workingDirectory: context.workingDirectory,
            projectRoot: context.projectRoot,
            worktreeRoot: context.worktreeRoot,
            executionMode: context.executionMode
        )
        if SafeBash.isSeatbeltRefusal(launch) {
            return ToolResult(
                content: "$ \(command)\n[seatbelt]\n\(launch.note ?? "refused")",
                isError: true
            )
        }

        if background {
            // BackgroundJobManager always spawns `/bin/zsh -c <command>`.
            // When seatbelt is on, nest sandbox-exec inside that shell body.
            let bgCommand: String
            if launch.sandboxed {
                // sandbox-exec -p PROFILE /bin/zsh -c USER_CMD
                // Quote profile and user command for outer zsh -c.
                let profileQ = shellSingleQuote(launch.profile)
                let cmdQ = shellSingleQuote(command)
                bgCommand =
                    "/usr/bin/sandbox-exec -p \(profileQ) /bin/zsh -c \(cmdQ)"
            } else {
                bgCommand = command
            }
            let timeout = TimeInterval(arguments.intOptional("timeoutSeconds") ?? 3600)
            let id = try await BackgroundJobManager.shared.startShell(
                command: bgCommand,
                workingDirectory: context.workingDirectory,
                timeout: timeout,
                conversationID: context.conversationID)
            var body =
                "Background job started.\ntask_id: \(id.uuidString)\ncommand: \(command)\nUse get_task_output / wait_tasks / kill_task."
            if launch.sandboxed {
                body += "\n[seatbelt: on]"
            } else if let note = launch.note {
                body += "\n[\(note)]"
            }
            return ToolResult(content: body, isError: false)
        }

        let timeout = TimeInterval(arguments.intOptional("timeoutSeconds") ?? 60)
        // Cooperative cancel: AgentLoop cancels the run Task → Task.isCancelled
        // becomes true; ShellRunner terminates the child instead of waiting
        // for the full timeout (C1 residual O1 / C2).
        let result = ShellRunner.run(
            executable: launch.executable,
            arguments: launch.arguments,
            workingDirectory: context.workingDirectory,
            timeout: timeout,
            shouldCancel: { Task.isCancelled }
        )
        var combined = result.stdout
        if !result.stderr.isEmpty {
            combined += "\n--- stderr ---\n" + result.stderr
        }
        if combined.utf8.count > maxBytes {
            let cutoff = combined.index(combined.startIndex, offsetBy: maxBytes, limitedBy: combined.endIndex) ?? combined.endIndex
            combined = String(combined[..<cutoff]) + "\n… [truncated]"
        }
        var header = "$ \(command)\n"
        if launch.sandboxed {
            header += "[seatbelt: on]\n"
        } else if let note = launch.note {
            header += "[\(note)]\n"
        }
        header += "[exit \(result.exitCode)]\n"
        let cancelled = result.exitCode == 130
            || combined.contains("[cancelled by user")
        return ToolResult(
            content: header + combined,
            isError: result.exitCode != 0 || cancelled)
    }
}

/// Single-quote for nesting inside `/bin/zsh -c` (POSIX-safe).
private func shellSingleQuote(_ s: String) -> String {
    // 'foo'bar'baz' → 'foo'\''bar'\''baz'
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Task control tools

public struct GetTaskOutputTool: Tool {
    public static let name = "get_task_output"
    public static let category: ToolCategory = .agent
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Snapshot status and output for a background shell or subagent task_id.",
        parameters: .init(
            properties: [
                "task_id": .init(type: "string", description: "UUID returned by run_shell(background:true) or task(run_in_background:true)."),
            ],
            required: ["task_id"]
        )
    )
    public init() {}
    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let raw = try arguments.string("task_id")
        guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ToolResult(content: "Invalid task_id", isError: true)
        }
        guard let snap = await BackgroundJobManager.shared.snapshot(id) else {
            return ToolResult(content: "Unknown task_id \(raw)", isError: true)
        }
        if let owner = snap.conversationID, owner != context.conversationID {
            return ToolResult(
                content: "Task \(raw) belongs to another conversation — access denied.",
                isError: true)
        }
        return ToolResult(content: formatSnapshot(snap))
    }
}

public struct WaitTasksTool: Tool {
    public static let name = "wait_tasks"
    public static let category: ToolCategory = .agent
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Wait for one or more background tasks. mode=wait_all (default) or wait_any.",
        parameters: .init(
            properties: [
                "task_ids": .init(type: "array", description: "Task UUIDs.", items: .init(type: "string")),
                "mode": .init(type: "string", description: "wait_all or wait_any", enum: ["wait_all", "wait_any"]),
                "timeout_ms": .init(type: "integer", description: "Max wait milliseconds. Default 30000."),
            ],
            required: ["task_ids"]
        )
    )
    public init() {}
    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let ids = arguments.stringArray("task_ids").compactMap { UUID(uuidString: $0) }
        guard !ids.isEmpty else {
            return ToolResult(content: "task_ids required", isError: true)
        }
        // Pre-filter ownership: refuse foreign conversation jobs.
        var owned: [UUID] = []
        for id in ids {
            guard let snap = await BackgroundJobManager.shared.snapshot(id) else {
                continue
            }
            if let owner = snap.conversationID, owner != context.conversationID {
                return ToolResult(
                    content: "Task \(id.uuidString) belongs to another conversation — access denied.",
                    isError: true)
            }
            owned.append(id)
        }
        guard !owned.isEmpty else {
            return ToolResult(content: "No matching tasks", isError: true)
        }
        let modeRaw = arguments.stringOptional("mode") ?? "wait_all"
        let mode: BackgroundJobManager.WaitMode = modeRaw == "wait_any" ? .waitAny : .waitAll
        let timeout = arguments.intOptional("timeout_ms") ?? 30_000
        let snaps = await BackgroundJobManager.shared.waitMany(
            ids: owned, mode: mode, timeoutMs: timeout)
        if snaps.isEmpty {
            return ToolResult(content: "No matching tasks", isError: true)
        }
        return ToolResult(content: snaps.map(formatSnapshot).joined(separator: "\n---\n"))
    }
}

public struct KillTaskTool: Tool {
    public static let name = "kill_task"
    public static let category: ToolCategory = .agent
    /// Not readOnly: terminates processes; must not auto-approve as RO.
    public static let permission: ToolPermission = .executes
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "Terminate a background shell or subagent task.",
        parameters: .init(
            properties: [
                "task_id": .init(type: "string", description: "Task UUID."),
            ],
            required: ["task_id"]
        )
    )
    public init() {}
    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let raw = try arguments.string("task_id")
        guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ToolResult(content: "Invalid task_id", isError: true)
        }
        if let snap = await BackgroundJobManager.shared.snapshot(id),
           let owner = snap.conversationID, owner != context.conversationID {
            return ToolResult(
                content: "Task \(raw) belongs to another conversation — access denied.",
                isError: true)
        }
        let ok = await BackgroundJobManager.shared.kill(id)
        if ok {
            return ToolResult(content: "Killed task \(raw)")
        }
        if let snap = await BackgroundJobManager.shared.snapshot(id) {
            return ToolResult(content: "Task not running (status=\(snap.status.rawValue))\n\(formatSnapshot(snap))")
        }
        return ToolResult(content: "Unknown task_id \(raw)", isError: true)
    }
}

private func formatSnapshot(_ s: BackgroundJobSnapshot) -> String {
    """
    task_id: \(s.id.uuidString)
    kind: \(s.kind.rawValue)
    status: \(s.status.rawValue)
    command: \(s.command)
    exit_code: \(s.exitCode.map(String.init) ?? "nil")
    output:
    \(s.output.prefix(32_000))
    """
}
