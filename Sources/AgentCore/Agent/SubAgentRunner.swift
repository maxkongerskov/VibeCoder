//
//  SubAgentRunner.swift
//
//  Sub-agent dispatch. The `task` tool calls into here: spin up a
//  fresh, ephemeral agent loop using the parent's backend + model,
//  restrict its tool surface to a safe read-only subset by default,
//  and return whatever final natural-language answer it produces.
//
//  Critical constraints:
//    - Sub-agents cannot spawn sub-sub-agents (no recursion). Enforced
//      by stripping `task` from the allow-list.
//    - Iteration cap is tighter than the main loop's. Default 15.
//    - Tool surface defaults to read-only (no write/delete/shell).
//    - OpenAI tool_call↔result pairing: on cancel / stall / pre-dispatch
//      halt, remaining tool_calls are closed with synthetic error
//      results (AgentLoop.closeToolCalls parity). Mid-stream cancel
//      keeps prose and DROPS partial tool_calls.
//
//  Adaptation vs. DEV PLAN:
//    * DEV PLAN drove its own raw `LMStudioService` chat-completion
//      loop. We drive `InferenceBackend.stream(request:)` directly
//      here. We DON'T delegate to `AgentLoop`, because the natural
//      restriction story (which tools the sub-agent may call) lives
//      AT THE CALL-DISPATCH SEAM, not in a separate registry — and
//      cloning a `ToolRegistry` actor with only a subset of its
//      factories isn't supported by the public registry API. Instead,
//      the loop here owns its own iteration, checks every tool call
//      against `allowed`, and reuses the parent's `ToolRegistry` for
//      actual dispatch.
//    * Restricted-schema list for the model: we ask the parent for
//      `schemas(activeNames: allowed, includeDeferred: true)` and
//      pass only those.
//    * Tracing: when the caller supplies an `AgentTraceService` +
//      `parentConversationID`, each iteration is appended to that
//      conversation's JSONL file tagged `preset = "[subagent]"` so
//      the parent's trace contains sub-agent steps grep-able by tag.
//    * No `@MainActor`. Foundation only.
//    * Wire compaction (S6b / W08): each model call runs
//      ToolResultCompressor + ChatLoop.compactHistory on a copy only;
//      the stored transcript stays full-fidelity for diagnostics.
//

import Foundation

public enum SubAgentRunner {

    /// Live stream events for UI parity with the main agent loop
    /// (thinking phrases, reasoning blocks, streaming answer).
    /// Optional — callers that only need `finalText` can ignore this.
    public enum StreamEvent: Sendable {
        case reasoningDelta(String)
        case contentDelta(String)
        /// Fired once when a model iteration begins (iteration is 1-based).
        case iterationStarted(Int)
    }

    /// Tool names the sub-agent gets by default. Strictly read-only and
    /// registered-only — callers can override via `allowedTools` if needed.
    public static let safeDefault: Set<String> = SubagentCatalog.readOnlyTools

    /// Default system prompt for sub-agents. Forces concise, factual
    /// output the parent can act on directly.
    public static let defaultSystemPrompt = """
    You are a sub-agent dispatched by a parent agent to investigate a focused question. Behaviour rules:

    - You have a READ-ONLY tool surface by default. Do not attempt to write, delete, or run shell commands.
    - Be CONCISE. Your final answer goes back to the parent agent as a single tool result, so produce something the parent can act on directly — usually under 200 words unless the parent's prompt explicitly asks for more.
    - Don't restate the question. Don't greet. Don't sign off. Just report findings.
    - If the question is unanswerable with the tools you have, say so plainly and explain what's missing.
    - When citing files, use `path:line` format so the parent can navigate.
    - Do NOT call the `task` tool. Sub-agents cannot spawn sub-sub-agents.
    """

    /// Result bundle: the final text answer plus the full sub-agent
    /// transcript (system + user + assistant + tool messages). Callers
    /// usually surface `finalText` to the parent as a tool result and
    /// keep the transcript for diagnostics.
    public struct RunResult: Sendable {
        public let finalText: String
        public let transcript: Conversation
        public let iterations: Int
        public let hitCap: Bool
        /// True when cooperative cancel (Task cancel or job kill) stopped the run.
        public let wasCancelled: Bool
        /// Non-nil when stall policy halted before dispatch (not a cancel).
        public let stallReason: String?
        /// P8: allowlist scrub from this spawn (nil for early error returns).
        public let scrubReport: AgentToolAllowlist.ScrubReport?
        /// Sum of every `ChatChunk.usage` seen this run. Cache fields stay 0
        /// until a backend owner extends `ChatChunk`.
        public let usage: SubagentUsage
        /// Dispatched tool invocations this run (not synthetic closeToolCalls).
        public let toolCount: Int
        /// Last `ChatChunk.done` finishReason. Not a loop terminator.
        public let finishReason: String?
        /// Wall-clock ms from run start to finish.
        public let durationMs: Int

        public init(finalText: String, transcript: Conversation,
                    iterations: Int, hitCap: Bool,
                    wasCancelled: Bool = false,
                    stallReason: String? = nil,
                    scrubReport: AgentToolAllowlist.ScrubReport? = nil,
                    usage: SubagentUsage = .zero,
                    toolCount: Int = 0,
                    finishReason: String? = nil,
                    durationMs: Int = 0) {
            self.finalText = finalText
            self.transcript = transcript
            self.iterations = iterations
            self.hitCap = hitCap
            self.wasCancelled = wasCancelled
            self.stallReason = stallReason
            self.scrubReport = scrubReport
            self.usage = usage
            self.toolCount = toolCount
            self.finishReason = finishReason
            self.durationMs = durationMs
        }
    }

    // Wire compaction helpers: SubAgentWireCompaction.swift (S6b / W08)
    // — SubAgentRunner.wireMessages forwards there.

    /// Run a sub-agent against the given `prompt`.
    ///
    /// - Parameters:
    ///   - prompt: The user-facing prompt the parent wants answered.
    ///   - systemPromptOverride: Replaces `defaultSystemPrompt` when
    ///     supplied. Pass nil for the read-only-focused default.
    ///   - allowedTools: Restriction set. Nil (or empty) → `safeDefault`.
    ///     The set is scrubbed of `task` so recursive spawning can't
    ///     happen.
    ///   - backend: Inference backend shared with the parent.
    ///   - model: Model the sub-agent runs against. Usually the
    ///     parent's active model — the caller decides.
    ///   - registry: The parent's `ToolRegistry`. We use it for
    ///     schemas + dispatch; restriction is applied at the call
    ///     seam rather than by cloning the registry.
    ///   - projectRoot / worktreeRoot: Forwarded to `ToolContext` so
    ///     tools behave the same as in the parent.
    ///   - maxIterations: Hard cap. Default 15.
    ///   - stallWindow: Rolling window for stall detection (AgentLoop
    ///     parity). Default 3. Set `enableStallPolicy` false to skip.
    ///   - enableStallPolicy: When true (default), repeated identical
    ///     tool-call signatures halt with synthetic closeToolCalls.
    ///   - sampling: Defaults to low-temp / 4k tokens — sub-agents are
    ///     investigative, not creative.
    ///   - parentConversationID: When supplied AND `trace` is non-nil,
    ///     sub-agent iterations are appended to the same JSONL file
    ///     as the parent.
    ///   - trace: Optional sink. nil = no tracing.
    ///   - onStream: Optional live token/iteration callbacks for chat UI
    ///     (orchestrator planning parity with single-model thinking).
    public static func run(
        prompt: String,
        systemPromptOverride: String? = nil,
        allowedTools: Set<String>? = nil,
        backend: InferenceBackend,
        model: ModelDescriptor,
        registry: ToolRegistry,
        projectRoot: URL? = nil,
        worktreeRoot: URL? = nil,
        /// Parent Safe Mode allow-lists. Must be forwarded from TaskTool —
        /// default nil only for callers that intentionally have no policy.
        safeMode: SafeModeConfig? = nil,
        /// Parent execution mode (plan/ask/auto/full) for ToolAuthorization.
        executionMode: ExecutionMode? = nil,
        patchReviewer: PatchReviewer? = nil,
        shellApprovalCoordinator: ShellApprovalCoordinator? = nil,
        authorization: AuthorizationConfig = .empty,
        maxIterations: Int = 15,
        stallWindow: Int = 3,
        enableStallPolicy: Bool = true,
        sampling: SamplingParams = SamplingParams(temperature: 0.2,
                                                   topP: 0.95,
                                                   topK: 40,
                                                   repeatPenalty: 1.05,
                                                   maxTokens: 4096),
        parentConversationID: UUID? = nil,
        trace: AgentTraceService? = nil,
        /// When set, cooperative cancel via `BackgroundJobManager.kill(jobID)`.
        jobID: UUID? = nil,
        /// Optional wire token budget. nil → derive from model.contextLength
        /// (or `defaultContextWindowTokens`) × compact threshold (70%).
        contextBudgetTokens: Int? = nil,
        /// Thinking/reasoning effort for models that support it (Gemma 4,
        /// Qwen thinking, etc.). nil = model default. Critical for
        /// orchestrator planning UI parity with single-model agent mode.
        thinking: ThinkingRequestConfig? = nil,
        /// Markdown-profile spawn overrides (maxTurns, permissionMode,
        /// thoughtLevel, model). Background is applied by TaskTool.
        profileSettings: AgentProfileSettings = .empty,
        /// Mailbox id (`agent_<uuid>`). When set: markRunning, drain
        /// coordinator messages each iteration, markCompleted, remember spawn.
        mailboxAgentId: String? = nil,
        onStream: (@Sendable (StreamEvent) async -> Void)? = nil
    ) async -> RunResult {

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return errorResult(message: "Error: `prompt` is required.")
        }
        guard !model.id.isEmpty else {
            return errorResult(message: "Error: no model is currently selected — sub-agent cannot run.")
        }

        let applied = applyProfileSettings(
            profileSettings,
            defaultMaxIterations: maxIterations,
            parentBackground: nil,
            parentExecutionMode: executionMode,
            parentModel: model,
            parentThinking: thinking
        )
        let childModel = applied.model
        let childExecutionMode = applied.executionMode
        let childMaxIterations = applied.maxIterations
        let childThinking = applied.thinking
        let mailboxId = mailboxAgentId.flatMap { raw -> String? in
            let id = AgentMailbox.normalizeAgentId(raw)
            return id.isEmpty ? nil : id
        }

        // Resolve the allow-list, then scrub against the live registry so
        // frontmatter typos / unknown names never reach schemas or dispatch
        // (Phase B PB5). Strip `task` via AgentToolAllowlist.bannedTools.
        // Empty/nil → safeDefault (read-only). Built-in explore/plan/GP
        // presets are resolved by TaskTool before this call; we only
        // enforce registry intersection here.
        // PC8: when names are stripped, emit a Diagnostics.warn so CI/logs
        // surface allowlist typos without failing the spawn.
        let known = await registry.registeredNames()
        let requested: Set<String> = {
            if let allowedTools, !allowedTools.isEmpty { return allowedTools }
            return safeDefault
        }()
        // Parent Settings → Tools disable list is already subtracted by
        // TaskTool; keep the intersection here as defense in depth.
        let scrubReport = AgentToolAllowlist.applyReport(
            requested: requested,
            known: known,
            fallback: safeDefault
        )
        // P8: log + parent-visible strip surface (status queue / AgentEvent).
        await AgentToolAllowlist.surfaceStrip(scrubReport, context: "SubAgentRunner")
        let allowed = scrubReport.allowed

        if let mailboxId {
            await AgentMailbox.shared.markRunning(mailboxId)
            await SpawnRegistry.shared.save(SpawnHandle(
                agentId: mailboxId,
                systemPromptOverride: systemPromptOverride,
                allowedTools: allowed,
                backend: backend,
                model: childModel,
                projectRoot: projectRoot,
                worktreeRoot: worktreeRoot,
                safeMode: safeMode,
                executionMode: childExecutionMode,
                patchReviewer: patchReviewer,
                shellApprovalCoordinator: shellApprovalCoordinator,
                authorization: authorization,
                maxIterations: childMaxIterations,
                stallWindow: stallWindow,
                enableStallPolicy: enableStallPolicy,
                sampling: sampling,
                parentConversationID: parentConversationID,
                thinking: childThinking
            ))
        }

        // Tool schemas the model sees this run — only the allowed
        // subset, including deferred tools (the sub-agent doesn't go
        // through the lazy-unlock flow).
        let tools = await registry.schemas(activeNames: allowed, includeDeferred: true)

        var systemPrompt = systemPromptOverride ?? defaultSystemPrompt
        // Inherit project rules + instructions + hybrid memory (C1 O05-03 / C2).
        // Budgeted so subagent system prompt does not dwarf the task.
        if let root = projectRoot {
            let cwd = worktreeRoot ?? root
            let rules = ProjectRules.load(
                projectRoot: root, cwd: cwd, includeHomeRules: true, maxChars: 3_000)
            if !rules.injectedText.isEmpty {
                systemPrompt += "\n\n" + rules.injectedText
            }
            if let instr = ChatLoop.loadProjectInstructions(projectRoot: root, cap: 2_000) {
                systemPrompt += "\n\n" + instr
            }
            if let block = MemoryBackend(workspacePath: root).recallBlock(query: trimmedPrompt) {
                systemPrompt += "\n\n" + block
            }
        }
        var convo = Conversation(title: "[subagent]", modelID: childModel.id)
        convo.messages.append(.init(role: .system, content: systemPrompt))
        convo.messages.append(.init(role: .user, content: trimmedPrompt))
        let runStarted = Date()
        var usage = SubagentUsage.zero
        var lastFinishReason: String? = nil
        var toolCount = 0
        var iterations = 0
        let persistAgentId = mailboxId ?? jobID.map { AgentMailbox.makeAgentId($0) }
        let persist: SessionPersist?
        if let parentConversationID, let persistAgentId {
            persist = SessionPersist(
                parent: parentConversationID,
                agentId: persistAgentId,
                taskId: jobID,
                modelId: childModel.id,
                started: runStarted
            )
            await SubagentSessionStore.shared.begin(
                parentConversationID: parentConversationID,
                agentId: persistAgentId,
                taskId: jobID,
                modelId: childModel.id
            )
            await persistProgress(
                persist,
                usage: usage,
                toolCount: toolCount,
                iterations: iterations,
                finishReason: lastFinishReason,
                started: runStarted
            )
        } else {
            persist = nil
        }
        await publishThread(
            jobID: jobID, convo, persist: persist,
            usage: usage, toolCount: toolCount, iterations: iterations,
            finishReason: lastFinishReason, started: runStarted)

        // Use parent conversation ID when available so nested background
        // shells / checkpoints / kill ownership stay under the parent chat.
        // Ephemeral subagent Conversation.id is only for transcript isolation.
        let context = ToolContext(
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            safeMode: safeMode,
            patchReviewer: patchReviewer,
            shellApprovalCoordinator: shellApprovalCoordinator,
            conversationID: parentConversationID ?? convo.id,
            inferenceBackend: backend,
            model: childModel,
            subagentDepth: 1,  // children cannot nest further
            executionMode: childExecutionMode,
            authorization: authorization
        )

        let effectiveStallWindow = max(2, stallWindow)
        var hitCap = false
        var lastTextReply = ""
        var wasCancelled = false
        var stallReason: String? = nil
        var recentToolSignatures: [String] = []

        while iterations < childMaxIterations {
            if await isCancelled(jobID: jobID) {
                wasCancelled = true
                break
            }
            iterations += 1
            let iterationStart = Date()
            if let onStream {
                await onStream(.iterationStarted(iterations))
            }

            if let mailboxId {
                let note = await drainAndFormatCoordinatorMessages(agentId: mailboxId)
                if !note.isEmpty {
                    convo.messages.append(.init(role: .user, content: note))
                    await publishThread(
                        jobID: jobID, convo, persist: persist,
                        usage: usage, toolCount: toolCount, iterations: iterations,
                        finishReason: lastFinishReason, started: runStarted)
                }
            }

            // Wire-only compaction: full transcript stays in `convo.messages`
            // for diagnostics; only the request is slimmed (S6b / C-SUBCOMPACT).
            let wireMessages = SubAgentWireCompaction.wireMessages(
                from: convo.messages,
                model: childModel,
                contextBudgetTokens: contextBudgetTokens)

            // Stream one model turn into a single assistant message.
            let request = ChatRequest(
                model: childModel,
                messages: wireMessages,
                tools: tools,
                sampling: sampling,
                thinking: childThinking
            )

            var assistantContent = ""
            var reasoningText = ""
            // Same normalize seam as AgentLoop: name fragments merge/concat,
            // empty args become "{}", inline JSON tool calls dispatch.
            var streamAccumulator = ResponseNormalizer.Accumulator()
            var lastDraftPublish: Date?
            do {
                for try await chunk in backend.stream(request: request) {
                    if await isCancelled(jobID: jobID) {
                        wasCancelled = true
                        break
                    }
                    var shouldPublishDraft = false
                    switch chunk {
                    case .reasoningDelta(let s):
                        // Forward thinking tokens for chat UI parity
                        // (single-model PendingAssistantBubble reasoning).
                        if !s.isEmpty {
                            reasoningText += s
                            shouldPublishDraft = true
                            if let onStream {
                                await onStream(.reasoningDelta(s))
                            }
                        }
                    case .contentDelta(let s):
                        assistantContent += s
                        streamAccumulator.ingestContentDelta(s)
                        if !s.isEmpty {
                            shouldPublishDraft = true
                            if let onStream {
                                await onStream(.contentDelta(s))
                            }
                        }
                    case .toolCallDelta(let index, let id, let name, let argsAppend):
                        streamAccumulator.ingestToolCallDelta(
                            index: index, id: id, name: name, argumentsAppend: argsAppend)
                        shouldPublishDraft = true
                    case .usage(let promptTokens, let completionTokens):
                        usage.add(prompt: promptTokens, completion: completionTokens)
                        await persistProgress(
                            persist,
                            usage: usage,
                            toolCount: toolCount,
                            iterations: iterations,
                            finishReason: lastFinishReason,
                            started: runStarted
                        )
                    case .done(let reason):
                        // Record only — do not halt the loop or skip tool dispatch.
                        lastFinishReason = reason
                    }
                    if shouldPublishDraft {
                        await publishDraftThreadIfDue(
                            jobID: jobID,
                            convo: convo,
                            reasoning: reasoningText,
                            content: assistantContent,
                            accumulator: streamAccumulator,
                            lastPublish: &lastDraftPublish
                        )
                    }
                }
            } catch is CancellationError {
                wasCancelled = true
            } catch let urlError as URLError where urlError.code == .cancelled {
                wasCancelled = true
            } catch {
                await recordTrace(
                    trace: trace,
                    parentConversationID: parentConversationID,
                    turn: iterations,
                    modelID: childModel.id,
                    systemPrompt: systemPrompt,
                    messagesCount: convo.messages.count,
                    allowed: allowed,
                    assistantContent: "",
                    toolCalls: [],
                    error: error.localizedDescription,
                    iterationStart: iterationStart
                )
                return await finishMailbox(
                    agentId: mailboxId,
                    persist: persist,
                    result: errorResult(
                        message: "Sub-agent failed: \(error.localizedDescription)",
                        scrubReport: scrubReport,
                        usage: usage,
                        toolCount: toolCount,
                        finishReason: lastFinishReason,
                        durationMs: Int(Date().timeIntervalSince(runStarted) * 1000)),
                    messages: convo.messages)
            }

            // Mid-stream cancel: keep prose only; DROP partial tool_calls
            // (AgentLoop parity — truncated JSON would only mislead).
            if wasCancelled {
                if !assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    convo.messages.append(.init(
                        role: .assistant,
                        content: assistantContent,
                        reasoningContent: reasoningText.isEmpty ? nil : reasoningText
                    ))
                    await publishThread(
                        jobID: jobID, convo, persist: persist,
                        usage: usage, toolCount: toolCount, iterations: iterations,
                        finishReason: lastFinishReason, started: runStarted)
                }
                lastTextReply = "Sub-agent cancelled."
                break
            }

            let normalized = streamAccumulator.finalize()
            let invocations = normalized.toolCalls.map { call in
                let cid = call.id.isEmpty
                    ? "tool_\(UUID().uuidString.prefix(8))"
                    : call.id
                return ToolCallInvocation(id: cid, name: call.name, arguments: call.arguments)
            }
            let assistantMsg = ChatMessage(
                role: .assistant,
                content: normalized.content,
                reasoningContent: reasoningText.isEmpty ? nil : reasoningText,
                toolCalls: invocations
            )
            convo.messages.append(assistantMsg)
            await publishThread(
                        jobID: jobID, convo, persist: persist,
                        usage: usage, toolCount: toolCount, iterations: iterations,
                        finishReason: lastFinishReason, started: runStarted)

            await recordTrace(
                trace: trace,
                parentConversationID: parentConversationID,
                turn: iterations,
                modelID: childModel.id,
                systemPrompt: systemPrompt,
                messagesCount: convo.messages.count,
                allowed: allowed,
                assistantContent: assistantContent,
                toolCalls: invocations,
                error: nil,
                iterationStart: iterationStart
            )

            // No tool calls → final answer. Stop.
            if invocations.isEmpty {
                lastTextReply = normalized.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if let jobID {
                    await BackgroundJobManager.shared.updateSubagentOutput(
                        id: jobID,
                        output: String(lastTextReply.prefix(4_000)))
                }
                break
            }

            // Stall subset (AgentLoop StallPolicy): identical tool-call
            // signatures across the rolling window → halt without dispatch.
            if enableStallPolicy {
                if let sig = ChatLoop.turnToolSignature(messages: convo.messages) {
                    recentToolSignatures.append(sig)
                    while recentToolSignatures.count > effectiveStallWindow {
                        recentToolSignatures.removeFirst()
                    }
                    if let reason = ChatLoop.detectStuckPattern(
                        recentToolSignatures,
                        repetitionThreshold: effectiveStallWindow
                    ) {
                        let halt = "stalled — \(reason)"
                        closeToolCalls(invocations, reason: halt, convo: &convo)
                        await publishThread(
                        jobID: jobID, convo, persist: persist,
                        usage: usage, toolCount: toolCount, iterations: iterations,
                        finishReason: lastFinishReason, started: runStarted)
                        stallReason = halt
                        lastTextReply = "Sub-agent halted: \(halt)"
                        break
                    }
                }
            }

            // Dispatch tools. Parallel-safe RO tools run as a batch (AgentLoop
            // parity); everything else is serial with cancel poll.
            var dispatchIndex = 0
            while dispatchIndex < invocations.count {
                if await isCancelled(jobID: jobID) {
                    wasCancelled = true
                    let remaining = Array(invocations[dispatchIndex...])
                    closeToolCalls(
                        remaining,
                        reason: "Cancelled by user before execution.",
                        convo: &convo)
                    await publishThread(
                        jobID: jobID, convo, persist: persist,
                        usage: usage, toolCount: toolCount, iterations: iterations,
                        finishReason: lastFinishReason, started: runStarted)
                    lastTextReply = "Sub-agent cancelled."
                    break
                }

                // Collect consecutive parallel-safe RO tools in the allowlist.
                let batchStart = dispatchIndex
                while dispatchIndex < invocations.count {
                    let n = invocations[dispatchIndex].name
                    guard allowed.contains(n) else { break }
                    let parallelSafe = await registry.isParallelSafeReadOnlyTool(n)
                    if !parallelSafe { break }
                    dispatchIndex += 1
                }
                let roBatch = Array(invocations[batchStart..<dispatchIndex])

                // Multi RO → parallel batch. Single RO also handled here so we
                // do not skip it (dispatchIndex already advanced past the batch).
                if !roBatch.isEmpty {
                    if let jobID {
                        let label = roBatch.count > 1
                            ? "[running] \(roBatch.map(\.name).joined(separator: ", ")) parallel RO"
                            : "[running] \(roBatch[0].name)"
                        await BackgroundJobManager.shared.updateSubagentOutput(
                            id: jobID, output: label)
                    }
                    if roBatch.count == 1 {
                        // Serial path for one tool (cancel poll for shell-like).
                        let inv = roBatch[0]
                        let result: ToolResult
                        do {
                            let args = try ToolArguments(json: inv.arguments)
                            result = try await executeWithCancelPoll(
                                name: inv.name,
                                arguments: args,
                                context: context,
                                registry: registry,
                                jobID: jobID)
                        } catch {
                            result = ToolResult(
                                content: "Tool error: \(error.localizedDescription)",
                                isError: true)
                        }
                        convo.messages.append(.init(
                            role: .tool, content: result.content, toolCallID: inv.id))
                        toolCount += 1
                        await publishThread(
                        jobID: jobID, convo, persist: persist,
                        usage: usage, toolCount: toolCount, iterations: iterations,
                        finishReason: lastFinishReason, started: runStarted)
                        if await isCancelled(jobID: jobID) {
                            wasCancelled = true
                            let remaining = Array(invocations[dispatchIndex...])
                            if !remaining.isEmpty {
                                closeToolCalls(
                                    remaining,
                                    reason: "Cancelled by user before execution.",
                                    convo: &convo)
                                await publishThread(
                        jobID: jobID, convo, persist: persist,
                        usage: usage, toolCount: toolCount, iterations: iterations,
                        finishReason: lastFinishReason, started: runStarted)
                            }
                            lastTextReply = "Sub-agent cancelled."
                            break
                        }
                    } else {
                        var work: [(name: String, arguments: ToolArguments)] = []
                        var resultsByIndex: [Int: ToolResult] = [:]
                        for (i, inv) in roBatch.enumerated() {
                            do {
                                let args = try ToolArguments(json: inv.arguments)
                                work.append((inv.name, args))
                            } catch {
                                resultsByIndex[i] = ToolResult(
                                    content: "Tool error: \(error.localizedDescription)",
                                    isError: true)
                            }
                        }
                        let batchResults = await registry.executeReadOnlyBatch(
                            invocations: work, context: context)
                        var runIdx = 0
                        for (i, inv) in roBatch.enumerated() {
                            let result: ToolResult
                            if let pre = resultsByIndex[i] {
                                result = pre
                            } else if runIdx < batchResults.count {
                                result = batchResults[runIdx]
                                runIdx += 1
                            } else {
                                result = ToolResult(content: "Tool error: missing result", isError: true)
                            }
                            convo.messages.append(.init(
                                role: .tool, content: result.content, toolCallID: inv.id))
                            toolCount += 1
                        }
                    }
                    await publishThread(
                        jobID: jobID, convo, persist: persist,
                        usage: usage, toolCount: toolCount, iterations: iterations,
                        finishReason: lastFinishReason, started: runStarted)
                    continue
                }

                // Non-RO / not allowed: serial with cancel poll.
                guard dispatchIndex < invocations.count else { break }
                let inv = invocations[dispatchIndex]
                dispatchIndex += 1

                if let jobID {
                    await BackgroundJobManager.shared.updateSubagentOutput(
                        id: jobID,
                        output: "[running] \(inv.name) (\(dispatchIndex)/\(invocations.count)) iter=\(iterations)")
                }

                let result: ToolResult
                if !allowed.contains(inv.name) {
                    result = ToolResult(
                        content: "Tool '\(inv.name)' is not available to this sub-agent. "
                            + "Allowed tools: \(allowed.sorted().joined(separator: ", ")).",
                        isError: true
                    )
                } else {
                    do {
                        let args = try ToolArguments(json: inv.arguments)
                        result = try await executeWithCancelPoll(
                            name: inv.name,
                            arguments: args,
                            context: context,
                            registry: registry,
                            jobID: jobID)
                    } catch {
                        result = ToolResult(
                            content: "Tool error: \(error.localizedDescription)",
                            isError: true
                        )
                    }
                    if await isCancelled(jobID: jobID) {
                        wasCancelled = true
                    }
                }
                convo.messages.append(.init(role: .tool,
                                            content: result.content,
                                            toolCallID: inv.id))
                toolCount += 1
                await publishThread(
                        jobID: jobID, convo, persist: persist,
                        usage: usage, toolCount: toolCount, iterations: iterations,
                        finishReason: lastFinishReason, started: runStarted)
                if wasCancelled {
                    let remaining = Array(invocations[dispatchIndex...])
                    if !remaining.isEmpty {
                        closeToolCalls(
                            remaining,
                            reason: "Cancelled by user before execution.",
                            convo: &convo)
                        await publishThread(
                        jobID: jobID, convo, persist: persist,
                        usage: usage, toolCount: toolCount, iterations: iterations,
                        finishReason: lastFinishReason, started: runStarted)
                    }
                    lastTextReply = "Sub-agent cancelled."
                    break
                }
            }
            if wasCancelled {
                break
            }
            // Mid-run progress: last tool names for live snapshot.
            if let jobID {
                let done = invocations.prefix(dispatchIndex).map(\.name).joined(separator: ", ")
                await BackgroundJobManager.shared.updateSubagentOutput(
                    id: jobID,
                    output: "[iter \(iterations)] tools: \(done)")
            }
        }

        // Iteration cap: exited while-loop without a final text reply.
        // (No open tool_calls here — each iteration either finished
        // dispatch or closed remaining on cancel/stall.)
        if !wasCancelled, stallReason == nil,
           iterations >= childMaxIterations, lastTextReply.isEmpty {
            hitCap = true
        }

        let finalText: String
        if wasCancelled {
            finalText = "Sub-agent cancelled."
        } else if !lastTextReply.isEmpty {
            finalText = lastTextReply
        } else if hitCap {
            finalText = "Sub-agent hit the iteration cap (\(childMaxIterations)) without converging on a final answer."
        } else {
            finalText = "Sub-agent finished without producing a final response."
        }

        await publishThread(
                        jobID: jobID, convo, persist: persist,
                        usage: usage, toolCount: toolCount, iterations: iterations,
                        finishReason: lastFinishReason, started: runStarted)
        let durationMs = Int(Date().timeIntervalSince(runStarted) * 1000)
        return await finishMailbox(
            agentId: mailboxId,
            persist: persist,
            result: RunResult(finalText: finalText,
                              transcript: convo,
                              iterations: iterations,
                              hitCap: hitCap,
                              wasCancelled: wasCancelled,
                              stallReason: stallReason,
                              scrubReport: scrubReport,
                              usage: usage,
                              toolCount: toolCount,
                              finishReason: lastFinishReason,
                              durationMs: durationMs),
            messages: convo.messages)
    }

    /// Push the live child transcript so the inspector can render a thread.
    /// `persist` writes committed messages + mid-run metadata — drafts omit it.
    private static func publishThread(
        jobID: UUID?,
        _ convo: Conversation,
        persist: SessionPersist? = nil,
        usage: SubagentUsage = .zero,
        toolCount: Int = 0,
        iterations: Int = 0,
        finishReason: String? = nil,
        started: Date? = nil
    ) async {
        if let jobID {
            await SubagentThreadStore.shared.publish(jobID: jobID, messages: convo.messages)
            await BackgroundJobManager.shared.updateSubagentTranscript(
                id: jobID, messages: convo.messages)
        }
        if let persist {
            await SubagentSessionStore.shared.appendCommitted(
                parentConversationID: persist.parent,
                agentId: persist.agentId,
                messages: convo.messages
            )
            await persistProgress(
                persist,
                usage: usage,
                toolCount: toolCount,
                iterations: iterations,
                finishReason: finishReason,
                started: started ?? persist.started
            )
        }
    }

    private static func persistProgress(
        _ persist: SessionPersist?,
        usage: SubagentUsage,
        toolCount: Int,
        iterations: Int,
        finishReason: String?,
        started: Date
    ) async {
        guard let persist else { return }
        await SubagentSessionStore.shared.updateProgress(
            parentConversationID: persist.parent,
            agentId: persist.agentId,
            usage: usage,
            toolCount: toolCount,
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            finishReason: finishReason,
            iterations: iterations,
            status: "running",
            taskId: persist.taskId,
            modelId: persist.modelId
        )
    }

    private struct SessionPersist: Sendable {
        let parent: UUID
        let agentId: String
        let taskId: UUID?
        let modelId: String
        let started: Date

        init(parent: UUID, agentId: String, taskId: UUID?, modelId: String, started: Date = Date()) {
            self.parent = parent
            self.agentId = agentId
            self.taskId = taskId
            self.modelId = modelId
            self.started = started
        }
    }

    /// Throttled in-flight snapshot: thought / prose / emerging tools.
    private static func publishDraftThreadIfDue(
        jobID: UUID?,
        convo: Conversation,
        reasoning: String,
        content: String,
        accumulator: ResponseNormalizer.Accumulator,
        lastPublish: inout Date?
    ) async {
        guard jobID != nil else { return }
        let now = Date()
        if let last = lastPublish, now.timeIntervalSince(last) < 0.12 { return }
        lastPublish = now
        var draftCalls: [ToolCallInvocation] = []
        draftCalls.reserveCapacity(accumulator.order.count)
        for index in accumulator.order {
            guard let partial = accumulator.buckets[index] else { continue }
            let name = partial.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            draftCalls.append(ToolCallInvocation(
                id: partial.id.isEmpty ? "draft_\(index)" : partial.id,
                name: name,
                arguments: partial.arguments.isEmpty ? "{}" : partial.arguments
            ))
        }
        var draft = convo
        draft.messages = SubagentThreadBuilder.draftTranscript(
            committed: convo.messages,
            reasoning: reasoning,
            content: content,
            toolCalls: draftCalls
        )
        await publishThread(jobID: jobID, draft)
    }

    // MARK: - Cancel + pairing helpers

    /// Cooperative cancel: Swift `Task` cancel or BackgroundJobManager kill.
    private static func isCancelled(jobID: UUID?) async -> Bool {
        if Task.isCancelled { return true }
        if let jobID, await BackgroundJobManager.shared.isCancelled(jobID) {
            return true
        }
        return false
    }

    /// Run a tool while polling job cancel. On cancel, cancel the tool Task so
    /// `Task.isCancelled` becomes true for `ShellRunner.shouldCancel` (process
    /// group kill). Still await a tool result for pairing when possible.
    private static func executeWithCancelPoll(
        name: String,
        arguments: ToolArguments,
        context: ToolContext,
        registry: ToolRegistry,
        jobID: UUID?
    ) async throws -> ToolResult {
        return try await withThrowingTaskGroup(of: ToolResult.self) { group in
            group.addTask {
                try await registry.execute(name: name, arguments: arguments, context: context)
            }
            group.addTask {
                while true {
                    if await isCancelled(jobID: jobID) {
                        // Propagate cancel into the tool task so Process tools
                        // see Task.isCancelled and ShellRunner kills the group.
                        return ToolResult(
                            content: "Cancelled by user before/during execution.",
                            isError: true)
                    }
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
            }
            // First finished wins: either tool result or cancel marker.
            let first = try await group.next()!
            group.cancelAll()
            // If cancel marker arrived first, still try to collect tool result
            // briefly — often the process is already terminating.
            if first.isError, first.content.contains("Cancelled by user") {
                if let second = try? await group.next() {
                    return second
                }
            }
            return first
        }
    }

    /// Close open tool_calls with synthetic error results so the next
    /// (or parent) request never sees unpaired assistant tool_calls.
    /// Mirrors `AgentLoop.closeToolCalls` without LoopEvent plumbing.
    static func closeToolCalls(
        _ invocations: [ToolCallInvocation],
        reason: String,
        convo: inout Conversation
    ) {
        for inv in invocations {
            let result = ToolResult(content: "Skipped: \(reason)", isError: true)
            convo.messages.append(.init(
                role: .tool,
                content: result.content,
                toolCallID: inv.id
            ))
        }
    }

    /// Tool-call ids declared by an assistant message that still lack a
    /// following `.tool` result with matching `toolCallID`. Used by tests
    /// and by W08 compactors as a pairing invariant check.
    public static func openToolCallIDs(in messages: [ChatMessage]) -> [String] {
        var open: [String] = []
        var pending = Set<String>()
        for m in messages {
            switch m.role {
            case .assistant:
                // New assistant turn — previous open set should already
                // have been closed; still report stragglers.
                open.append(contentsOf: pending.sorted())
                pending = Set(m.toolCalls.map(\.id).filter { !$0.isEmpty })
            case .tool:
                if let id = m.toolCallID {
                    pending.remove(id)
                }
            default:
                break
            }
        }
        open.append(contentsOf: pending.sorted())
        return open
    }

    // MARK: - Trace bookkeeping

    /// Append one entry to the parent conversation's trace JSONL file.
    /// No-op when `trace` is nil or `parentConversationID` is nil.
    /// Tagged `preset = "[subagent]"` so the user can grep them out
    /// from main-loop iterations during post-mortem.
    private static func recordTrace(
        trace: AgentTraceService?,
        parentConversationID: UUID?,
        turn: Int,
        modelID: String,
        systemPrompt: String,
        messagesCount: Int,
        allowed: Set<String>,
        assistantContent: String,
        toolCalls: [ToolCallInvocation],
        error: String?,
        iterationStart: Date
    ) async {
        guard let trace, let parentID = parentConversationID else { return }
        let summaries = toolCalls.map { tc in
            AgentTraceEntry.ToolCallSummary(
                name: tc.name,
                argumentsPreview: String(tc.arguments.prefix(500))
            )
        }
        let entry = AgentTraceEntry(
            ts: ISO8601DateFormatter().string(from: Date()),
            turn: turn,
            modelId: modelID,
            preset: "[subagent]",
            systemPromptChars: systemPrompt.count,
            systemPromptHash: AgentTraceService.shortHash(systemPrompt),
            messagesCount: messagesCount,
            lastUserMessage: "(sub-agent — see parent trace for user prompt)",
            toolsOffered: allowed.sorted(),
            assistantContent: assistantContent,
            toolCalls: summaries,
            error: error,
            durationMs: Int(Date().timeIntervalSince(iterationStart) * 1000)
        )
        await trace.append(conversationId: parentID, entry: entry)
    }

    // MARK: - Helpers

    private static func errorResult(
        message: String,
        scrubReport: AgentToolAllowlist.ScrubReport? = nil,
        usage: SubagentUsage = .zero,
        toolCount: Int = 0,
        finishReason: String? = nil,
        durationMs: Int = 0
    ) -> RunResult {
        let convo = Conversation(title: "[subagent — error]",
                                 messages: [.init(role: .assistant, content: message)])
        return RunResult(finalText: message, transcript: convo,
                         iterations: 0, hitCap: false,
                         wasCancelled: false, stallReason: nil,
                         scrubReport: scrubReport,
                         usage: usage,
                         toolCount: toolCount,
                         finishReason: finishReason,
                         durationMs: durationMs)
    }

    // MARK: - Profile + mailbox

    /// Resolved spawn knobs after applying `AgentProfileSettings`.
    public struct ProfileApplication: Sendable {
        public let maxIterations: Int
        public let executionMode: ExecutionMode?
        public let runInBackground: Bool
        public let model: ModelDescriptor
        public let thinking: ThinkingRequestConfig?
    }

    /// Apply markdown-profile overrides onto parent/default spawn knobs.
    /// `maxTurns` tightens the iteration cap. `permissionMode` becomes the
    /// child's `executionMode`. `background == true` is used only when the
    /// parent did not set `run_in_background` / `background`.
    /// Model id is remapped onto the parent's backend (no new backend).
    public static func applyProfileSettings(
        _ settings: AgentProfileSettings,
        defaultMaxIterations: Int,
        parentBackground: Bool?,
        parentExecutionMode: ExecutionMode?,
        parentModel: ModelDescriptor,
        parentThinking: ThinkingRequestConfig? = nil
    ) -> ProfileApplication {
        var maxIter = max(1, defaultMaxIterations)
        if let cap = settings.maxTurns, cap > 0 {
            maxIter = min(maxIter, cap)
        }
        let mode = settings.permissionMode ?? parentExecutionMode
        let runInBackground = parentBackground ?? (settings.background == true)
        let childModel = resolveProfileModel(settings.model, parent: parentModel)
        let thinking = resolveProfileThinking(
            settings.thoughtLevel, model: childModel, parent: parentThinking)
        return ProfileApplication(
            maxIterations: maxIter,
            executionMode: mode,
            runInBackground: runInBackground,
            model: childModel,
            thinking: thinking
        )
    }

    /// Same backend as parent; skip when the id is empty.
    static func resolveProfileModel(_ raw: String?, parent: ModelDescriptor) -> ModelDescriptor {
        guard let raw = AgentProfileSettings.nonEmpty(raw) else { return parent }
        return ModelDescriptor(
            id: raw,
            displayName: raw,
            backend: parent.backend,
            supportsTools: parent.supportsTools,
            contextLength: parent.contextLength,
            parameterCountB: parent.parameterCountB,
            isLoaded: parent.isLoaded
        )
    }

    static func resolveProfileThinking(
        _ thoughtLevel: String?,
        model: ModelDescriptor,
        parent: ThinkingRequestConfig?
    ) -> ThinkingRequestConfig? {
        guard let raw = AgentProfileSettings.nonEmpty(thoughtLevel),
              let effort = parseThoughtEffort(raw),
              let capability = ThinkingModelScanner.detect(modelId: model.id)
        else { return parent }
        return ThinkingRequestConfig(capability: capability, effort: capability.clamp(effort))
    }

    static func parseThoughtEffort(_ raw: String) -> ThinkingEffort? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch token {
        case "off", "none": return .off
        case "low": return .low
        case "medium", "med": return .medium
        case "high": return .high
        case "max", "xhigh": return .max
        default: return ThinkingEffort(rawValue: token)
        }
    }

    /// Prefix each drained inbox item for the child transcript.
    public static func formatCoordinatorMessages(_ messages: [AgentMailbox.Message]) -> String {
        messages.compactMap { msg -> String? in
            let body = msg.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                return "Message from coordinator: \(body)"
            }
            let summary = msg.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                return "Message from coordinator: \(summary)"
            }
            return nil
        }.joined(separator: "\n\n")
    }

    public static func drainAndFormatCoordinatorMessages(
        agentId: String,
        mailbox: AgentMailbox = .shared
    ) async -> String {
        let msgs = await mailbox.drain(agentId: agentId)
        return formatCoordinatorMessages(msgs)
    }

    public struct ResumeOutcome: Sendable {
        public let resumed: Bool
        public let agentId: String
        public let jobID: UUID?
        public let prompt: String
        public let message: String
    }

    /// Consume a mailbox resume request and, if set, start a background
    /// job with drained coordinator text as the prompt.
    public static func resumeIfRequested(agentId: String) async -> ResumeOutcome {
        let id = AgentMailbox.normalizeAgentId(agentId)
        guard !id.isEmpty else {
            return ResumeOutcome(
                resumed: false, agentId: id, jobID: nil, prompt: "",
                message: "resume_agent_id is empty.")
        }
        let requested = await AgentMailbox.shared.consumeResumeRequest(agentId: id)
        let drained = await AgentMailbox.shared.drain(agentId: id)
        let prompt = formatCoordinatorMessages(drained)
        guard requested else {
            return ResumeOutcome(
                resumed: false, agentId: id, jobID: nil, prompt: prompt,
                message: "No resume requested for \(id).")
        }
        guard let handle = await SpawnRegistry.shared.handle(for: id) else {
            return ResumeOutcome(
                resumed: false, agentId: id, jobID: nil, prompt: prompt,
                message: "Cannot resume \(id): no spawn record in this process.")
        }
        let effectivePrompt = prompt.isEmpty
            ? "Message from coordinator: Please continue."
            : prompt
        await AgentMailbox.shared.markRunning(id)
        let jobID = UUID()
        do {
            _ = try await BackgroundJobManager.shared.registerSubagent(
                id: jobID,
                description: "resume: \(id)",
                conversationID: handle.parentConversationID)
        } catch {
            await AgentMailbox.shared.markCompleted(id)
            return ResumeOutcome(
                resumed: false, agentId: id, jobID: nil, prompt: effectivePrompt,
                message: "Failed to register resume job: \(error.localizedDescription)")
        }
        let captured = handle
        await BackgroundJobManager.shared.attachSubagentWork(id: jobID) {
            let result = await SubAgentRunner.run(
                prompt: effectivePrompt,
                systemPromptOverride: captured.systemPromptOverride,
                allowedTools: captured.allowedTools,
                backend: captured.backend,
                model: captured.model,
                registry: ToolRegistry.shared,
                projectRoot: captured.projectRoot,
                worktreeRoot: captured.worktreeRoot,
                safeMode: captured.safeMode,
                executionMode: captured.executionMode,
                patchReviewer: captured.patchReviewer,
                shellApprovalCoordinator: captured.shellApprovalCoordinator,
                authorization: captured.authorization,
                maxIterations: captured.maxIterations,
                stallWindow: captured.stallWindow,
                enableStallPolicy: captured.enableStallPolicy,
                sampling: captured.sampling,
                parentConversationID: captured.parentConversationID,
                jobID: jobID,
                thinking: captured.thinking,
                mailboxAgentId: captured.agentId
            )
            let summary = String(result.finalText.prefix(2_000))
            let failed = result.wasCancelled
                || result.hitCap
                || result.stallReason != nil
                || summary.hasPrefix("Error:")
                || summary.hasPrefix("Sub-agent failed")
            await BackgroundJobManager.shared.completeSubagent(
                id: jobID, output: summary, failed: failed)
        }
        return ResumeOutcome(
            resumed: true, agentId: id, jobID: jobID, prompt: effectivePrompt,
            message: "Background resume started for \(id).")
    }

    static func resetSpawnRegistryForTests() async {
        await SpawnRegistry.shared.reset()
    }

    private static func finishMailbox(
        agentId: String?,
        persist: SessionPersist? = nil,
        result: RunResult,
        messages: [ChatMessage] = []
    ) async -> RunResult {
        if let persist {
            let status: String
            if result.wasCancelled {
                status = "cancelled"
            } else if result.stallReason != nil {
                status = "stalled"
            } else if result.hitCap {
                status = "failed"
            } else if result.finalText.hasPrefix("Error:")
                        || result.finalText.hasPrefix("Sub-agent failed") {
                status = "failed"
            } else {
                status = "completed"
            }
            await SubagentSessionStore.shared.finish(
                parentConversationID: persist.parent,
                agentId: persist.agentId,
                output: result.finalText,
                usage: result.usage,
                toolCount: result.toolCount,
                durationMs: result.durationMs,
                finishReason: result.finishReason,
                iterations: result.iterations,
                status: status,
                taskId: persist.taskId,
                modelId: persist.modelId,
                messages: messages
            )
        }
        if let agentId {
            await AgentMailbox.shared.markCompleted(agentId)
        }
        return result
    }

    struct SpawnHandle: Sendable {
        let agentId: String
        let systemPromptOverride: String?
        let allowedTools: Set<String>
        let backend: InferenceBackend
        let model: ModelDescriptor
        let projectRoot: URL?
        let worktreeRoot: URL?
        let safeMode: SafeModeConfig?
        let executionMode: ExecutionMode?
        let patchReviewer: PatchReviewer?
        let shellApprovalCoordinator: ShellApprovalCoordinator?
        let authorization: AuthorizationConfig
        let maxIterations: Int
        let stallWindow: Int
        let enableStallPolicy: Bool
        let sampling: SamplingParams
        let parentConversationID: UUID?
        let thinking: ThinkingRequestConfig?
    }

    actor SpawnRegistry {
        static let shared = SpawnRegistry()
        private var handles: [String: SpawnHandle] = [:]
        private var order: [String] = []
        private let maxHandles = 64

        func save(_ handle: SpawnHandle) {
            let id = handle.agentId
            if handles[id] == nil {
                order.append(id)
            }
            handles[id] = handle
            while order.count > maxHandles {
                let old = order.removeFirst()
                if old != id {
                    handles.removeValue(forKey: old)
                }
            }
        }

        func handle(for agentId: String) -> SpawnHandle? {
            handles[AgentMailbox.normalizeAgentId(agentId)]
        }

        func reset() {
            handles.removeAll()
            order.removeAll()
        }
    }

}
