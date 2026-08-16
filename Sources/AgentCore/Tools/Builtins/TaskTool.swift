//
//  TaskTool.swift
//
//  Grok Build–compatible `task` tool: spawn a subagent (explore / plan /
//  general-purpose) via SubAgentRunner. Foreground-wait by default.
//  Set `run_in_background` / `background` true to register with
//  BackgroundJobManager and return task_id immediately — parent continues
//  and uses get_task_output / wait_tasks / kill_task.
//  Multiple independent `task` calls in one assistant message run concurrently.
//  `resume_agent_id` resumes a completed mailbox agent instead of spawning.
//

import Foundation

public struct TaskTool: Tool {
    public static let name = "task"
    public static let category: ToolCategory = .agent
    /// Not readOnly: can spawn general-purpose subagents that write/shell.
    /// Plan mode still allows explore/plan types via ToolAuthorization.
    public static let permission: ToolPermission = .executes
    public static let availability: ToolAvailability = .core

    public static let schema = ToolSchema(
        name: name,
        description: SubagentCatalog.taskToolDescription,
        parameters: ToolSchema.Parameters(
            properties: [
                "prompt": .init(
                    type: "string",
                    description: "Self-contained task prompt. A new task starts fresh and does not see the parent transcript — include all context the subagent needs."
                ),
                "description": .init(
                    type: "string",
                    description: "Short description of the task (3-5 words)."
                ),
                "subagent_type": .init(
                    type: "string",
                    description: "Built-in type (general-purpose, explore, plan) OR a custom agent name from .vibecoder/agents/*.md / .grok/agents/*.md."
                ),
                "capability_mode": .init(
                    type: "string",
                    description: "Optional: read-only, read-write, execute, or all.",
                    enum: ["read-only", "read-write", "execute", "all"]
                ),
                "isolation": .init(
                    type: "string",
                    description: "Optional: none (default) or worktree (isolated git checkout).",
                    enum: ["none", "worktree"]
                ),
                "run_in_background": .init(
                    type: "boolean",
                    description: "If true, return task_id immediately and run the subagent in the background. Use get_task_output / wait_tasks / kill_task. Alias: background."
                ),
                "background": .init(
                    type: "boolean",
                    description: "Alias for run_in_background."
                ),
                "resume_agent_id": .init(
                    type: "string",
                    description: "If set, skip a new spawn and resume this agent_<uuid> when the mailbox requested resume. Uses drained coordinator messages as the prompt."
                ),
            ],
            required: ["prompt", "description", "subagent_type"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        // Depth gate — Grok Build MAX_SUBAGENT_DEPTH = 1
        if context.subagentDepth >= 1 {
            return ToolResult(
                content: "Subagent depth limit exceeded (max 1). Nested subagents cannot spawn further subagents.",
                isError: true
            )
        }

        if let resumeRaw = arguments.stringOptional("resume_agent_id") {
            let resumeId = resumeRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !resumeId.isEmpty {
                return await Self.resumeExisting(agentId: resumeId)
            }
        }

        let prompt = arguments.stringOptional("prompt")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else {
            throw ToolError.invalidArguments("task requires a non-empty 'prompt'")
        }

        let description = arguments.stringOptional("description")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "subagent task"
        let typeRaw = arguments.stringOptional("subagent_type")
        let customAgent = AgentDefinitionDiscovery.byName(
            typeRaw ?? "", projectRoot: context.projectRoot)
        let type = SubagentType.parse(typeRaw)
        let capability = SubagentCapabilityMode.parse(arguments.stringOptional("capability_mode"))
        let isolation = SubagentIsolationMode.parse(arguments.stringOptional("isolation"))

        guard let backend = context.inferenceBackend else {
            return ToolResult(
                content: "Error: task tool has no inference backend in ToolContext. Subagent cannot run.",
                isError: true
            )
        }
        guard let model = context.model, !model.id.isEmpty else {
            return ToolResult(
                content: "Error: no model selected — subagent cannot run.",
                isError: true
            )
        }

        var allowed: Set<String>
        let systemPrompt: String
        let resolvedTypeLabel: String
        if let custom = customAgent {
            // Custom agent definition from markdown frontmatter.
            // Empty tools: fail closed to read-only (do NOT fall through to
            // general-purpose write/shell when SubagentType.parse maps the
            // custom name to .generalPurpose).
            if custom.tools.isEmpty {
                let mode = capability ?? .readOnly
                allowed = mode.toolNames.intersection(SubagentCatalog.readOnlyTools)
                if allowed.isEmpty { allowed = SubagentCatalog.readOnlyTools }
            } else {
                // Honor capability_mode even when tools: is non-empty (intersect).
                let listed = Set(custom.tools)
                if let mode = capability {
                    allowed = listed.intersection(mode.toolNames)
                    if allowed.isEmpty {
                        // Fail closed: listed tools all outside mode → RO core.
                        allowed = SubagentCatalog.readOnlyTools
                    }
                } else {
                    allowed = listed
                }
            }
            allowed.remove("task")
            systemPrompt = custom.systemPrompt
            resolvedTypeLabel = "custom:\(custom.name)"
        } else {
            allowed = type.allowedTools(capability: capability)
            resolvedTypeLabel = type.rawValue
            systemPrompt = type.systemPrompt
        }

        // Optional worktree isolation for general-purpose write work.
        // C2: track full CreatedWorktree so we can discard on cancel/failure
        // (success keeps the tree so parent can review via worktree_path meta).
        var worktreeRoot = context.worktreeRoot
        var createdIsolation: CreatedWorktree?
        if isolation == .worktree {
            if let project = context.projectRoot {
                let shortId = String(UUID().uuidString.prefix(8)).lowercased()
                do {
                    let created = try WorktreeService.createOrReuseWorktree(
                        projectFolder: project.path,
                        conversationShortId: "sub-\(shortId)"
                    )
                    worktreeRoot = URL(fileURLWithPath: created.path)
                    createdIsolation = created
                } catch {
                    return ToolResult(
                        content: "Failed to create isolated worktree: \(error.localizedDescription)",
                        isError: true
                    )
                }
            } else {
                return ToolResult(
                    content: "isolation=worktree requires an open project with a git repository.",
                    isError: true
                )
            }
        }

        let profile = customAgent?.profileSettings ?? .empty
        let typeDefaultMax = (customAgent == nil && (type == .explore || type == .plan)) ? 12 : 15
        let applied = SubAgentRunner.applyProfileSettings(
            profile,
            defaultMaxIterations: typeDefaultMax,
            parentBackground: Self.parentBackgroundFlag(from: arguments),
            parentExecutionMode: context.executionMode,
            parentModel: model
        )
        let runInBackground = applied.runInBackground
        let maxIterations = applied.maxIterations
        let childModel = applied.model
        let childThinking = applied.thinking
        let childExecutionMode = applied.executionMode

        let subagentUUID = UUID()
        let mailboxAgentId = AgentMailbox.makeAgentId(subagentUUID)
        let subagentId = mailboxAgentId
        let jobDescription = "\(resolvedTypeLabel): \(description)"
        do {
            _ = try await BackgroundJobManager.shared.registerSubagent(
                id: subagentUUID,
                description: jobDescription,
                conversationID: context.conversationID)
        } catch {
            return ToolResult(
                content: "Failed to register subagent job: \(error.localizedDescription)",
                isError: true)
        }
        await AgentMailbox.shared.markRunning(mailboxAgentId)

        // Capture Sendable inputs for the runner (ToolContext is not always
        // captured whole into the background Task).
        let projectRoot = context.projectRoot
        let safeMode = context.safeMode
        let executionMode = childExecutionMode
        let patchReviewer = context.patchReviewer
        let shellApprovalCoordinator = context.shellApprovalCoordinator
        let authorization = context.authorization
        let conversationID = context.conversationID
        let isolationCreated = createdIsolation
        let isolationWorktreeRoot = worktreeRoot
        let allowedTools = allowed.subtracting(context.disabledToolNames)
        let systemPromptCapture = systemPrompt
        let typeLabel = resolvedTypeLabel
        let descCapture = description
        let mailboxIdCapture = mailboxAgentId
        let profileCapture = profile
        let thinkingCapture = childThinking
        let modelCapture = childModel

        if runInBackground {
            // Detach runner: parent returns task_id immediately.
            await BackgroundJobManager.shared.attachSubagentWork(id: subagentUUID) {
                _ = await Self.runAndComplete(
                    subagentUUID: subagentUUID,
                    prompt: prompt,
                    systemPrompt: systemPromptCapture,
                    allowedTools: allowedTools,
                    backend: backend,
                    model: modelCapture,
                    projectRoot: projectRoot,
                    worktreeRoot: isolationWorktreeRoot,
                    safeMode: safeMode,
                    executionMode: executionMode,
                    patchReviewer: patchReviewer,
                    shellApprovalCoordinator: shellApprovalCoordinator,
                    authorization: authorization,
                    maxIterations: maxIterations,
                    parentConversationID: conversationID,
                    createdIsolation: isolationCreated,
                    thinking: thinkingCapture,
                    profileSettings: profileCapture,
                    mailboxAgentId: mailboxIdCapture
                )
            }
            await BackgroundJobManager.shared.updateSubagentOutput(
                id: subagentUUID,
                output: "[background] started type=\(typeLabel) — use get_task_output / wait_tasks / kill_task")
            var body = """
            Background subagent started.
            task_id: \(subagentUUID.uuidString)
            id: \(subagentId)
            agent_id: \(mailboxAgentId)
            type: \(typeLabel)
            description: \(descCapture)
            Use get_task_output / wait_tasks / kill_task.

            <subagent_meta>
            id: \(subagentId)
            task_id: \(subagentUUID.uuidString)
            agent_id: \(mailboxAgentId)
            type: \(typeLabel)
            description: \(descCapture)
            background: true
            status: running
            """
            if let created = isolationCreated {
                body += "\nworktree_path: \(created.path)"
                body += "\nworktree_branch: \(created.branch)"
            }
            body += "\n</subagent_meta>"
            return ToolResult(content: body, isError: false)
        }

        // Foreground: await runner (legacy default).
        let start = Date()
        let outcome = await Self.runAndComplete(
            subagentUUID: subagentUUID,
            prompt: prompt,
            systemPrompt: systemPromptCapture,
            allowedTools: allowedTools,
            backend: backend,
            model: modelCapture,
            projectRoot: projectRoot,
            worktreeRoot: isolationWorktreeRoot,
            safeMode: safeMode,
            executionMode: executionMode,
            patchReviewer: patchReviewer,
            shellApprovalCoordinator: shellApprovalCoordinator,
            authorization: authorization,
            maxIterations: maxIterations,
            parentConversationID: conversationID,
            createdIsolation: isolationCreated,
            thinking: thinkingCapture,
            profileSettings: profileCapture,
            mailboxAgentId: mailboxIdCapture
        )

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        var body = """
        \(outcome.summary)

        <subagent_meta>
        id: \(subagentId)
        task_id: \(subagentUUID.uuidString)
        agent_id: \(mailboxAgentId)
        type: \(typeLabel)
        description: \(descCapture)
        iterations: \(outcome.iterations)
        duration_ms: \(durationMs)
        hit_cap: \(outcome.hitCap)
        cancelled: \(outcome.wasCancelled)
        stalled: \(outcome.stalled)
        background: false
        summary_only: true
        """
        if let scrub = outcome.scrubReport, scrub.didStrip {
            body += "\ntool_strip: \(scrub.diagnosticMessage)"
            body += "\ntool_strip_status: \(scrub.parentStatusMessage(context: typeLabel))"
        }
        if let created = isolationCreated {
            body += "\nworktree_path: \(created.path)"
            body += "\nworktree_branch: \(created.branch)"
            body += "\nworktree_discarded: \(outcome.worktreeDiscarded)"
        }
        body += "\n</subagent_meta>"

        return ToolResult(content: body, isError: outcome.failed)
    }

    // MARK: - Shared runner completion

    private struct RunOutcome: Sendable {
        let summary: String
        let iterations: Int
        let hitCap: Bool
        let wasCancelled: Bool
        let stalled: Bool
        let failed: Bool
        let worktreeDiscarded: Bool
        let scrubReport: AgentToolAllowlist.ScrubReport?
    }

    /// Run SubAgentRunner and complete the BackgroundJobManager entry.
    /// Used by both FG await and BG waiter Task.
    private static func runAndComplete(
        subagentUUID: UUID,
        prompt: String,
        systemPrompt: String,
        allowedTools: Set<String>,
        backend: InferenceBackend,
        model: ModelDescriptor,
        projectRoot: URL?,
        worktreeRoot: URL?,
        safeMode: SafeModeConfig?,
        executionMode: ExecutionMode?,
        patchReviewer: PatchReviewer?,
        shellApprovalCoordinator: ShellApprovalCoordinator?,
        authorization: AuthorizationConfig,
        maxIterations: Int,
        parentConversationID: UUID?,
        createdIsolation: CreatedWorktree?,
        thinking: ThinkingRequestConfig? = nil,
        profileSettings: AgentProfileSettings = .empty,
        mailboxAgentId: String? = nil
    ) async -> RunOutcome {
        let result = await SubAgentRunner.run(
            prompt: prompt,
            systemPromptOverride: systemPrompt,
            allowedTools: allowedTools,
            backend: backend,
            model: model,
            registry: ToolRegistry.shared,
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            // Inherit parent safety posture — never silently drop Safe Mode.
            safeMode: safeMode,
            executionMode: executionMode,
            patchReviewer: patchReviewer,
            shellApprovalCoordinator: shellApprovalCoordinator,
            authorization: authorization,
            maxIterations: maxIterations,
            parentConversationID: parentConversationID,
            trace: Optional<AgentTraceService>.none,
            jobID: subagentUUID,
            thinking: thinking,
            profileSettings: profileSettings,
            mailboxAgentId: mailboxAgentId
        )

        // Parent / job snapshot: summary only (truncate full transcript noise).
        let summary = String(result.finalText.prefix(2_000))
        // Cancel / stall / hard fail must not be recorded as "completed".
        let failed = result.wasCancelled
            || result.hitCap
            || result.stallReason != nil
            || summary.hasPrefix("Error:")
            || summary.hasPrefix("Sub-agent failed")
        if result.wasCancelled {
            // Prefer killed status when the runner exited on cancel and the
            // job is still marked running (Task cancel without kill_task).
            if await BackgroundJobManager.shared.snapshot(subagentUUID)?.status == .running {
                _ = await BackgroundJobManager.shared.kill(subagentUUID)
            }
            // Refresh output with runner summary when still .killed from kill().
            // PC4: completeSubagent / kill publish BackgroundJobCompletion auto-wake.
            await BackgroundJobManager.shared.completeSubagent(
                id: subagentUUID, output: summary, failed: true)
        } else {
            await BackgroundJobManager.shared.completeSubagent(
                id: subagentUUID, output: summary, failed: failed)
        }

        var worktreeDiscarded = false
        if let created = createdIsolation {
            // C2 / C1-O1: discard isolation worktrees that did not succeed.
            // Successful runs keep the worktree for parent review/merge.
            if failed, let project = projectRoot {
                try? WorktreeService.discard(
                    worktreePath: created.path,
                    branch: created.branch,
                    projectFolder: project.path
                )
                worktreeDiscarded = true
            }
        }

        return RunOutcome(
            summary: summary,
            iterations: result.iterations,
            hitCap: result.hitCap,
            wasCancelled: result.wasCancelled,
            stalled: result.stallReason != nil,
            failed: failed,
            worktreeDiscarded: worktreeDiscarded,
            scrubReport: result.scrubReport
        )
    }

    /// Parent `run_in_background` / `background` when the model set the flag.
    /// `nil` means the parent omitted it (profile `background:` may apply).
    static func parentBackgroundFlag(from arguments: ToolArguments) -> Bool? {
        let set = arguments.raw["run_in_background"] != nil
            || arguments.raw["background"] != nil
        guard set else { return nil }
        return arguments.bool("run_in_background", default: false)
            || arguments.bool("background", default: false)
    }

    private static func resumeExisting(agentId: String) async -> ToolResult {
        let outcome = await SubAgentRunner.resumeIfRequested(agentId: agentId)
        if !outcome.resumed {
            return ToolResult(content: outcome.message, isError: true)
        }
        let jobID = outcome.jobID
        var body = """
        Background resume started.
        id: \(outcome.agentId)
        agent_id: \(outcome.agentId)
        """
        if let jobID {
            body += "\ntask_id: \(jobID.uuidString)"
        }
        body += """

        Use get_task_output / wait_tasks / kill_task.

        <subagent_meta>
        id: \(outcome.agentId)
        agent_id: \(outcome.agentId)
        background: true
        status: running
        resumed: true
        """
        if let jobID {
            body += "\ntask_id: \(jobID.uuidString)"
        }
        body += "\n</subagent_meta>"
        return ToolResult(content: body, isError: false)
    }
}
