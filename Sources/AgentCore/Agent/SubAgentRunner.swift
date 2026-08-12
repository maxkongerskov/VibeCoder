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

        public init(finalText: String, transcript: Conversation,
                    iterations: Int, hitCap: Bool,
                    wasCancelled: Bool = false,
                    stallReason: String? = nil,
                    scrubReport: AgentToolAllowlist.ScrubReport? = nil) {
            self.finalText = finalText
            self.transcript = transcript
            self.iterations = iterations
            self.hitCap = hitCap
            self.wasCancelled = wasCancelled
            self.stallReason = stallReason
            self.scrubReport = scrubReport
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
        onStream: (@Sendable (StreamEvent) async -> Void)? = nil
    ) async -> RunResult {

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return errorResult(message: "Error: `prompt` is required.")
        }
        guard !model.id.isEmpty else {
            return errorResult(message: "Error: no model is currently selected — sub-agent cannot run.")
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
        let scrubReport = AgentToolAllowlist.applyReport(
            requested: requested,
            known: known,
            fallback: safeDefault
        )
        // P8: log + parent-visible strip surface (status queue / AgentEvent).
        await AgentToolAllowlist.surfaceStrip(scrubReport, context: "SubAgentRunner")
        let allowed = scrubReport.allowed

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
        var convo = Conversation(title: "[subagent]", modelID: model.id)
        convo.messages.append(.init(role: .system, content: systemPrompt))
        convo.messages.append(.init(role: .user, content: trimmedPrompt))

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
            model: model,
            subagentDepth: 1,  // children cannot nest further
            executionMode: executionMode,
            authorization: authorization
        )

        let effectiveStallWindow = max(2, stallWindow)
        var iterations = 0
        var hitCap = false
        var lastTextReply = ""
        var wasCancelled = false
        var stallReason: String? = nil
        var recentToolSignatures: [String] = []

        while iterations < maxIterations {
            if await isCancelled(jobID: jobID) {
                wasCancelled = true
                break
            }
            iterations += 1
            let iterationStart = Date()
            if let onStream {
                await onStream(.iterationStarted(iterations))
            }

            // Wire-only compaction: full transcript stays in `convo.messages`
            // for diagnostics; only the request is slimmed (S6b / C-SUBCOMPACT).
            let wireMessages = SubAgentWireCompaction.wireMessages(
                from: convo.messages,
                model: model,
                contextBudgetTokens: contextBudgetTokens)

            // Stream one model turn into a single assistant message.
            let request = ChatRequest(
                model: model,
                messages: wireMessages,
                tools: tools,
                sampling: sampling,
                thinking: thinking
            )

            var assistantContent = ""
            // Bucket by index — see AgentLoop / InferenceBackend doc
            // comments for why id-based bucketing breaks fragment merging.
            var toolCallChunksByIndex: [Int: (id: String, name: String, arguments: String)] = [:]
            do {
                for try await chunk in backend.stream(request: request) {
                    if await isCancelled(jobID: jobID) {
                        wasCancelled = true
                        break
                    }
                    switch chunk {
                    case .reasoningDelta(let s):
                        // Forward thinking tokens for chat UI parity
                        // (single-model PendingAssistantBubble reasoning).
                        if !s.isEmpty, let onStream {
                            await onStream(.reasoningDelta(s))
                        }
                    case .contentDelta(let s):
                        assistantContent += s
                        if !s.isEmpty, let onStream {
                            await onStream(.contentDelta(s))
                        }
                    case .toolCallDelta(let index, let id, let name, let argsAppend):
                        var entry = toolCallChunksByIndex[index] ?? (id: "", name: "", arguments: "")
                        if let id, !id.isEmpty { entry.id = id }
                        if let n = name, !n.isEmpty { entry.name = n }
                        if let a = argsAppend { entry.arguments += a }
                        toolCallChunksByIndex[index] = entry
                    case .usage, .done:
                        continue
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
                    modelID: model.id,
                    systemPrompt: systemPrompt,
                    messagesCount: convo.messages.count,
                    allowed: allowed,
                    assistantContent: "",
                    toolCalls: [],
                    error: error.localizedDescription,
                    iterationStart: iterationStart
                )
                return errorResult(message: "Sub-agent failed: \(error.localizedDescription)", scrubReport: scrubReport)
            }

            // Mid-stream cancel: keep prose only; DROP partial tool_calls
            // (AgentLoop parity — truncated JSON would only mislead).
            if wasCancelled {
                if !assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    convo.messages.append(.init(role: .assistant, content: assistantContent))
                }
                lastTextReply = "Sub-agent cancelled."
                break
            }

            let invocations: [ToolCallInvocation] = toolCallChunksByIndex
                .keys.sorted()
                .compactMap { idx in
                    guard let info = toolCallChunksByIndex[idx], !info.name.isEmpty else { return nil }
                    let cid = info.id.isEmpty ? "tool_\(idx)_\(UUID().uuidString.prefix(8))" : info.id
                    return ToolCallInvocation(id: cid, name: info.name, arguments: info.arguments)
                }
            let assistantMsg = ChatMessage(role: .assistant,
                                           content: assistantContent,
                                           toolCalls: invocations)
            convo.messages.append(assistantMsg)

            await recordTrace(
                trace: trace,
                parentConversationID: parentConversationID,
                turn: iterations,
                modelID: model.id,
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
                lastTextReply = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        if await isCancelled(jobID: jobID) {
                            wasCancelled = true
                            let remaining = Array(invocations[dispatchIndex...])
                            if !remaining.isEmpty {
                                closeToolCalls(
                                    remaining,
                                    reason: "Cancelled by user before execution.",
                                    convo: &convo)
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
                        }
                    }
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
                if wasCancelled {
                    let remaining = Array(invocations[dispatchIndex...])
                    if !remaining.isEmpty {
                        closeToolCalls(
                            remaining,
                            reason: "Cancelled by user before execution.",
                            convo: &convo)
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
           iterations >= maxIterations, lastTextReply.isEmpty {
            hitCap = true
        }

        let finalText: String
        if wasCancelled {
            finalText = "Sub-agent cancelled."
        } else if !lastTextReply.isEmpty {
            finalText = lastTextReply
        } else if hitCap {
            finalText = "Sub-agent hit the iteration cap (\(maxIterations)) without converging on a final answer."
        } else {
            finalText = "Sub-agent finished without producing a final response."
        }

        return RunResult(finalText: finalText,
                         transcript: convo,
                         iterations: iterations,
                         hitCap: hitCap,
                         wasCancelled: wasCancelled,
                         stallReason: stallReason,
                         scrubReport: scrubReport)
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
        scrubReport: AgentToolAllowlist.ScrubReport? = nil
    ) -> RunResult {
        let convo = Conversation(title: "[subagent — error]",
                                 messages: [.init(role: .assistant, content: message)])
        return RunResult(finalText: message, transcript: convo,
                         iterations: 0, hitCap: false,
                         wasCancelled: false, stallReason: nil,
                         scrubReport: scrubReport)
    }

}
