//
//  ToolRegistry.swift
//
//  The one place that maps tool name → implementation. Replaces the
//  original AgentOS's 6-file checklist with a single registration call
//  per tool.
//

import Foundation

public actor ToolRegistry {
    public static let shared = ToolRegistry()

    /// Map from tool name to a factory that builds a fresh instance per
    /// invocation. Factories instead of singletons so concurrent calls
    /// don't share mutable state.
    private var factories: [String: @Sendable () -> any Tool] = [:]
    private var metadata: [String: ToolMetadata] = [:]
    /// Runtime-registered tools (e.g. Xcode MCP proxies from `mcpbridge`).
    private var dynamicExecutors: [String: @Sendable (ToolArguments, ToolContext) async throws -> ToolResult] = [:]

    public struct ToolMetadata: Sendable {
        public let name: String
        public let category: ToolCategory
        public let permission: ToolPermission
        public let availability: ToolAvailability
        public let schema: ToolSchema

        /// Public so App-hosted bridges (PDF tools, etc.) can register dynamic tools.
        public init(
            name: String,
            category: ToolCategory,
            permission: ToolPermission,
            availability: ToolAvailability,
            schema: ToolSchema
        ) {
            self.name = name
            self.category = category
            self.permission = permission
            self.availability = availability
            self.schema = schema
        }
    }

    public func register<T: Tool>(_ type: T.Type) {
        let name = T.name
        if factories[name] != nil || dynamicExecutors[name] != nil {
            Diagnostics.warn("Tool '\(name)' registered twice — second registration ignored")
            return
        }
        factories[name] = { T() }
        metadata[name] = .init(
            name: name,
            category: T.category,
            permission: T.permission,
            availability: T.availability,
            schema: T.schema
        )
    }

    /// Register a tool discovered at runtime (Xcode MCP `tools/list`).
    public func registerDynamicTool(
        metadata: ToolMetadata,
        executor: @escaping @Sendable (ToolArguments, ToolContext) async throws -> ToolResult
    ) {
        let name = metadata.name
        if factories[name] != nil || dynamicExecutors[name] != nil {
            Diagnostics.warn("Dynamic tool '\(name)' already registered — replacing")
            factories.removeValue(forKey: name)
            dynamicExecutors.removeValue(forKey: name)
            self.metadata.removeValue(forKey: name)
        }
        dynamicExecutors[name] = executor
        self.metadata[name] = metadata
    }

    public func unregisterDynamicTools(names: Set<String>) {
        for name in names {
            dynamicExecutors.removeValue(forKey: name)
            metadata.removeValue(forKey: name)
        }
    }

    public func registerBuiltins() {
        register(ReadFileTool.self)
        register(WriteFileTool.self)
        register(EditFileTool.self)         // v1.1: SEARCH/REPLACE primary edit primitive
        register(ApplyPatchTool.self)      // fallback for multi-file atomic edits
        register(ListDirectoryTool.self)
        register(GrepCodeTool.self)
        register(GlobFilesTool.self)
        register(RunShellTool.self)
        register(GitStatusTool.self)
        register(GitDiffTool.self)
        register(GitCommitTool.self)
        register(CreatePullRequestTool.self)
        register(ToolSearchTool.self)
        // Network / docs tools — exist on disk in Tools/Builtins/ but
        // were never registered, so the model honestly reported "I
        // don't have web search" even though the Settings panel claimed
        // otherwise. WebSearchTool falls back to DuckDuckGo (no API key
        // needed). FetchURLTool reads any HTTP/S URL. AppleDocsTool
        // searches developer.apple.com. FetchRSSTool reads RSS feeds.
        register(WebSearchTool.self)
        register(FetchURLTool.self)
        register(AppleDocsTool.self)
        register(FetchRSSTool.self)
        // File-ops primitives. Models trained on agentic loops
        // (Qwen3-Coder, MiniMax-M2, gpt-oss) hallucinate these tool
        // names by default and bounce off "unknown tool" errors
        // without them. Adding lets the loop self-recover cleanly
        // instead of pivoting to `run_shell rm/mv/mkdir` (which
        // bypasses the path allow-list when Safe Mode is on and
        // reads as shell noise in the transcript).
        register(DeleteFileTool.self)
        register(MoveFileTool.self)
        register(CreateDirectoryTool.self)
        // Xcode tooling — the two gaps a Swift coding agent actually hits:
        // build/test on demand, and registering a new file with the
        // .xcodeproj so `xcodebuild` will compile it (gnarly to do via
        // run_shell). The other defined-but-unregistered tools
        // (text_edit, notebook, porting) are intentionally NOT registered
        // in v1 to keep the schema lean for small local models.
        register(XcodeBuildTool.self)
        register(XcodeProjectEditorTool.self)
        register(CreatePlanTool.self)
        register(UpdateTodoTool.self)
        register(RevisePlanTool.self)
        register(AskUserTool.self)
        // Grok Build–style subagent spawn (explore / plan / general-purpose).
        register(TaskTool.self)
        register(GetTaskOutputTool.self)
        register(WaitTasksTool.self)
        register(KillTaskTool.self)
        // Depth D4: agent-callable in-app job list (not full Grok monitor).
        register(ListBackgroundJobsTool.self)
        register(MonitorJobsTool.self)
        // Grok-class memory + code nav (phases 1 / 8)
        register(MemoryTool.self)
        register(MemorySearchTool.self)
        register(MemoryGetTool.self)
        register(FindSymbolTool.self)
        // Skills v0 (Wave B S2): SKILL.md progressive load.
        register(LoadSkillTool.self)
        // PA4: restore filesystem turn checkpoint (code-aware rewind).
        register(RestoreCheckpointTool.self)
        // ZCode-parity: session context, schedules, mailbox, plan-mode enter/exit.
        register(ReadSessionContextTool.self)
        register(CronCreateTool.self)
        register(CronListTool.self)
        register(CronUpdateTool.self)
        register(CronDeleteTool.self)
        register(SendMessageTool.self)
        register(EnterPlanModeTool.self)
        register(ExitPlanModeTool.self)
        // Add new tools here. Compiler will flag a forgotten `import` —
        // there is no second touchpoint to forget.
    }

    /// PreToolUse with ZCode `updatedInput` / `permissionDecision`. Deny and
    /// `ask` fail closed (no UI broker on this path). Successful rewrite
    /// replaces the model's arguments.
    private func applyPreToolDetailed(
        name: String,
        arguments: ToolArguments,
        context: ToolContext
    ) -> (ok: ToolArguments?, deny: ToolResult?) {
        let pre = HookDispatcher.preToolDetailed(
            toolName: name,
            argumentsSummary: String(describing: arguments),
            projectRoot: context.projectRoot,
            worktreeRoot: context.worktreeRoot)
        let decision = pre.permissionDecision?.lowercased()
        if !pre.allow || decision == "deny" {
            return (nil, ToolResult(content: pre.message ?? "Denied by hook", isError: true))
        }
        if decision == "ask" {
            return (nil, ToolResult(
                content: pre.message ?? "Hook requested user approval before this tool can run.",
                isError: true))
        }
        if let json = pre.updatedInputJSON, !json.isEmpty,
           let rewritten = try? ToolArguments(json: json) {
            return (rewritten, nil)
        }
        return (arguments, nil)
    }

    /// Resolve and execute a tool by name. Centralized permission check
    /// happens here so individual tools don't reimplement it.
    public func execute(name: String, arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard let meta = metadata[name] else {
            let available = metadata.keys.sorted().joined(separator: ", ")
            throw ToolError.unavailable("Unknown tool: \(name). Available: \(available)")
        }
        try await checkPermission(meta: meta, arguments: arguments, context: context)
        let preApplied = applyPreToolDetailed(name: name, arguments: arguments, context: context)
        if let denied = preApplied.deny { return denied }
        let effectiveArgs = preApplied.ok ?? arguments
        // PA4: snapshot pre-mutation file state for code-aware /rewind.
        // Runs after permission/hooks so denied tools leave no checkpoint noise.
        if meta.permission == .mutates
            || CheckpointStore.snapshotToolNames.contains(name) {
            await CheckpointStore.shared.snapshotBeforeMutation(
                toolName: name,
                arguments: effectiveArgs,
                context: context)
        }
        let result: ToolResult
        if let executor = dynamicExecutors[name] {
            result = try await executor(effectiveArgs, context)
        } else {
            guard let factory = factories[name] else {
                throw ToolError.unavailable("Unknown tool: \(name)")
            }
            let tool = factory()
            result = try await tool.execute(arguments: effectiveArgs, context: context)
        }
        let post = HookDispatcher.postTool(
            toolName: name,
            resultSummary: String(result.content.prefix(200)),
            projectRoot: context.projectRoot,
            worktreeRoot: context.worktreeRoot)
        // Origin classification only. Mutating tools already insert a full
        // TrackedHunk via HunkTracker.record — do not append thin siblings.
        if !result.mutatedPaths.isEmpty {
            for path in result.mutatedPaths {
                await HunkTracker.shared.recordAgentPath(path)
            }
        }
        // Post hooks run after the tool body; explicit deny flags the result
        // so the model sees the policy failure (side effects may already exist).
        if !post.allow {
            let msg = post.message ?? "Denied by post-tool hook"
            return ToolResult(
                content: result.content.isEmpty ? msg : "\(result.content)\n\n[PostTool hook deny] \(msg)",
                isError: true,
                mutatedPaths: result.mutatedPaths
            )
        }
        return result
    }

    /// Schemas for the active tool subset. Used to build the
    /// `tools` array on each agent loop iteration.
    public func schemas(activeNames: Set<String>? = nil, includeDeferred: Bool = false) -> [ToolSchema] {
        metadata.values.compactMap { meta in
            if let active = activeNames, !active.contains(meta.name) { return nil }
            switch meta.availability {
            case .core: return meta.schema
            case .deferred: return includeDeferred ? meta.schema : nil
            case .platformGated: return meta.schema    // assumed available; the tool will return .unavailable if not
            }
        }
    }

    public func all() -> [ToolMetadata] {
        Array(metadata.values).sorted { $0.name < $1.name }
    }

    public func metadata(for name: String) -> ToolMetadata? {
        metadata[name]
    }

    /// All registered tool names (builtins + dynamic). Used to keep
    /// prompts, pruning sets, and compressors aligned with registration.
    public func registeredNames() -> Set<String> {
        Set(metadata.keys)
    }

    /// Tool names carrying a specific permission — the canonical source for
    /// loop classification (parallel dispatch, edit detection, pruning).
    public func toolNames(withPermission permission: ToolPermission) -> Set<String> {
        Set(metadata.values.filter { $0.permission == permission }.map(\.name))
    }

    /// True when `name` is registered with `.readOnly` permission.
    public func isReadOnlyTool(_ name: String) -> Bool {
        metadata[name]?.permission == .readOnly
    }

    /// Tools that are permission-RO but must not run in parallel batches
    /// (mutate plan/memory side state or unlock schemas).
    public static let serialOnlyReadOnlyTools: Set<String> = [
        "create_plan", "update_todo", "revise_plan",
        "tool_search",
        "memory_search", "memory_get",
        "ask_user",
    ]

    /// Execute-permission tools safe to overlap (isolated spawn). Source of
    /// truth for `task`; dispatch still lives in AgentLoop.
    public static let parallelSafeExecuteTools: Set<String> = ["task"]

    /// Mutators whose bodies call `MutationReview` — Ask mode may pass them
    /// through for the sheet. All other mutators need ShellApproval in Ask.
    public static let mutationReviewAwareTools: Set<String> = [
        "write_file", "edit_file", "apply_patch",
        "delete_file", "move_file",
    ]

    /// True when `name` is safe to run concurrently with other RO tools.
    public func isParallelSafeReadOnlyTool(_ name: String) -> Bool {
        guard isReadOnlyTool(name) else { return false }
        return !Self.serialOnlyReadOnlyTools.contains(name)
    }

    /// Execute a batch of read-only tools concurrently. Validates
    /// permissions on the actor, then runs tool bodies in parallel so
    /// independent I/O (grep, glob, read) does not serialize.
    public func executeReadOnlyBatch(
        invocations: [(name: String, arguments: ToolArguments)],
        context: ToolContext
    ) async -> [ToolResult] {
        struct WorkItem: Sendable {
            let index: Int
            let run: @Sendable () async -> ToolResult
        }

        var work: [WorkItem] = []
        work.reserveCapacity(invocations.count)

        for (index, inv) in invocations.enumerated() {
            guard let meta = metadata[inv.name] else {
                work.append(WorkItem(index: index, run: {
                    ToolResult(content: "Tool error: Unknown tool: \(inv.name)", isError: true)
                }))
                continue
            }
            guard meta.permission == .readOnly else {
                work.append(WorkItem(index: index, run: {
                    ToolResult(content: "Tool error: `\(inv.name)` is not read-only", isError: true)
                }))
                continue
            }
            do {
                try await checkPermission(meta: meta, arguments: inv.arguments, context: context)
            } catch {
                let message = error.localizedDescription
                work.append(WorkItem(index: index, run: {
                    ToolResult(content: "Tool error: \(message)", isError: true)
                }))
                continue
            }

            // Pre-tool hooks (same gate as serial execute — deny-tools etc.)
            let preApplied = applyPreToolDetailed(
                name: inv.name, arguments: inv.arguments, context: context)
            if let denied = preApplied.deny {
                work.append(WorkItem(index: index, run: { denied }))
                continue
            }
            let hookedArgs = preApplied.ok ?? inv.arguments

            if let executor = dynamicExecutors[inv.name] {
                let args = hookedArgs
                let toolName = inv.name
                work.append(WorkItem(index: index, run: {
                    do {
                        let result = try await executor(args, context)
                        let post = HookDispatcher.postTool(
                            toolName: toolName,
                            resultSummary: String(result.content.prefix(200)),
                            projectRoot: context.projectRoot,
                            worktreeRoot: context.worktreeRoot)
                        if !post.allow {
                            let msg = post.message ?? "Denied by post-tool hook"
                            return ToolResult(
                                content: result.content.isEmpty
                                    ? msg
                                    : "\(result.content)\n\n[PostTool hook deny] \(msg)",
                                isError: true,
                                mutatedPaths: result.mutatedPaths
                            )
                        }
                        return result
                    } catch {
                        return ToolResult(content: "Tool error: \(error.localizedDescription)", isError: true)
                    }
                }))
            } else if let factory = factories[inv.name] {
                let args = hookedArgs
                let toolName = inv.name
                work.append(WorkItem(index: index, run: {
                    do {
                        let tool = factory()
                        let result = try await tool.execute(arguments: args, context: context)
                        let post = HookDispatcher.postTool(
                            toolName: toolName,
                            resultSummary: String(result.content.prefix(200)),
                            projectRoot: context.projectRoot,
                            worktreeRoot: context.worktreeRoot)
                        if !post.allow {
                            let msg = post.message ?? "Denied by post-tool hook"
                            return ToolResult(
                                content: result.content.isEmpty
                                    ? msg
                                    : "\(result.content)\n\n[PostTool hook deny] \(msg)",
                                isError: true,
                                mutatedPaths: result.mutatedPaths
                            )
                        }
                        return result
                    } catch {
                        return ToolResult(content: "Tool error: \(error.localizedDescription)", isError: true)
                    }
                }))
            } else {
                work.append(WorkItem(index: index, run: {
                    ToolResult(content: "Tool error: Unknown tool: \(inv.name)", isError: true)
                }))
            }
        }

        return await withTaskGroup(of: (Int, ToolResult).self) { group in
            for item in work {
                group.addTask {
                    // C2-O1: cooperative cancel for RO batch children.
                    if Task.isCancelled {
                        return (item.index, ToolResult(
                            content: "Cancelled by user before execution.",
                            isError: true))
                    }
                    let result = await item.run()
                    return (item.index, result)
                }
            }
            var results = Array(repeating: ToolResult(content: "Tool error: missing result", isError: true),
                                count: invocations.count)
            var completed = Set<Int>()
            for await (index, result) in group {
                results[index] = result
                completed.insert(index)
                // If the parent turn was cancelled, stop waiting for the rest
                // of the batch — cancel outstanding child tasks and fill.
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
            }
            if Task.isCancelled {
                for i in 0..<results.count where !completed.contains(i) {
                    results[i] = ToolResult(
                        content: "Cancelled by user before execution.",
                        isError: true)
                }
            }
            return results
        }
    }

    /// Core permission check via the ordered authorization pipeline.
    /// See `ToolAuthorization.evaluate` for the deny → ask → remembered →
    /// RO auto → mode → SafeMode order. Full mode does not skip deny rules.
    private func checkPermission(meta: ToolMetadata, arguments: ToolArguments, context: ToolContext) async throws {
        var remembered = context.authorization.remembered
        if !context.authorization.useInlineRememberedOnly {
            let projectKey = RememberedGrants.projectKey(from: context)
            // Hydrate *all* project grants (tool + path/dir fingerprints).
            // Previously only a single tool/shell key was loaded, so
            // "Always allow this folder" never matched later tools.
            let processSnap = await RememberedGrants.shared.snapshot(projectKey: projectKey)
            for (k, d) in processSnap { remembered[k] = d }
            let durableSnap = await DurableGrantStore.shared.snapshot(projectKey: projectKey)
            for (k, d) in durableSnap {
                remembered[k] = d
                await RememberedGrants.shared.rememberInMemoryOnly(d, for: k)
            }
        }

        let outcome = ToolAuthorization.evaluate(
            toolName: meta.name,
            permission: meta.permission,
            arguments: arguments,
            context: context,
            config: context.authorization,
            remembered: remembered
        )
        switch outcome {
        case .allow:
            return
        case .deny(let reason):
            throw ToolError.permissionDenied(reason)
        case .ask(let reason):
            // Ask mode with a patch reviewer: only tools that call
            // MutationReview in their body may pass through. Others fail
            // closed or use ShellApproval (never silent write).
            if context.patchReviewer != nil,
               meta.permission == .mutates || meta.name == "apply_patch"
                || meta.name == "edit_file" || meta.name == "write_file" {
                if Self.mutationReviewAwareTools.contains(meta.name) {
                    return
                }
                // Non-review-aware mutator: require Once/Always via shell gate
                // (same UI as shell approval) rather than silent allow.
                let command = arguments.stringOptional("path")
                    ?? arguments.stringOptional("project_path")
                    ?? meta.name
                let gate = await ShellApprovalGate.resolve(
                    toolName: meta.name,
                    reason: reason,
                    kind: .executes,
                    command: command,
                    argumentsSummary: "Ask mode — confirm \(meta.name)",
                    context: context)
                if !gate.allowed {
                    throw ToolError.permissionDenied(gate.denialMessage)
                }
                return
            }
            // Executes / shell / other `.ask`: interactive Once/Always/Never
            // via ShellApprovalCoordinator (Wave B S4). Fail closed when nil.
            let command = arguments.stringOptional("command")
            let kind = ShellApprovalGate.kind(for: meta.name)
            let summary: String?
            if command == nil {
                let raw = arguments.raw
                let keys = raw.keys.sorted().prefix(4)
                let parts = keys.compactMap { k -> String? in
                    guard let v = raw[k] else { return nil }
                    return "\(k)=\(String(describing: v).prefix(40))"
                }
                summary = parts.isEmpty ? nil : parts.joined(separator: " · ")
            } else {
                summary = nil
            }
            let gate = await ShellApprovalGate.resolve(
                toolName: meta.name,
                reason: reason,
                kind: kind,
                command: command,
                argumentsSummary: summary,
                context: context)
            if !gate.allowed {
                throw ToolError.permissionDenied(gate.denialMessage)
            }
        }
    }
}
