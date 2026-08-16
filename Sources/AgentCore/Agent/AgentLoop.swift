//
//  AgentLoop.swift
//
//  The orchestrator. Drives one user turn through: build prompt → call
//  model → parse tool calls → dispatch → repeat, with stall guards and
//  build verification.
//
//  Two contracts:
//    1. The loop is backend-agnostic. It only knows about
//       `InferenceBackend`.
//    2. The loop returns an updated `Conversation` after each `run` so
//       the host (App `ChatViewModel` / eval-runner) can persist via
//       `ConversationStore`. Mid-turn persistence is host-owned —
//       AgentLoop does not inject `ConversationStoring` itself.
//
//  The LOGIC helpers (compaction, stall detection, anti-confabulation
//  gates, nudge texts) live in `ChatLoop` as pure functions; this actor
//  owns the runtime state and calls into them. See ChatLoop.swift.
//
//  Invariant maintained throughout: every assistant message that
//  carries tool_calls is followed by one tool message per call ID —
//  even on stall, cancellation, or error. Strict OpenAI-compatible
//  servers (llama-server included) reject histories with dangling
//  tool_calls on the next request, so the loop appends synthetic
//  "skipped/cancelled" results whenever it bails out mid-turn.
//

import Foundation

public actor AgentLoop {

    public struct Configuration: Sendable {
        public var maxIterations: Int
        public var stallWindow: Int       // turns to look back for loop detection
        public var verifyEdits: Bool      // run BuildGuard after mutating turns
        public var safeMode: SafeModeConfig?
        /// Optional host-installed gate for `apply_patch`. When non-nil,
        /// the tool surfaces previews before writing — typically wired
        /// only when Safe Mode is engaged.
        public var patchReviewer: PatchReviewer?
        /// Optional host-installed gate for `ask_user`. When non-nil,
        /// the tool suspends the loop and surfaces a question card to
        /// the user. When nil, `ask_user` returns a degraded message.
        public var userQuestionReviewer: UserQuestionReviewer?
        /// Optional host gate for shell / executes / MCP `.ask` outcomes
        /// (Once / Always / Never). When nil, those asks hard-deny.
        /// Shared with ToolRegistry via `ShellApprovalGate` (Wave B S4).
        public var shellApprovalCoordinator: ShellApprovalCoordinator?
        /// Tools the user switched off in Settings → Tools. Excluded
        /// from the schemas the model sees AND rejected at dispatch
        /// (defense in depth — models call from memory, not just from
        /// the offered list).
        public var disabledToolNames: Set<String>
        /// Approximate token budget for one request (system prompt +
        /// history). When the estimate exceeds it, older tool outputs /
        /// assistant prose are elided via `ChatLoop.compactHistory`.
        /// nil disables compaction (P0 behaviour).
        public var contextBudgetTokens: Int?
        /// Host-level system prompt (Settings → System Prompt). Appended
        /// after the baseline editing rules, before any per-conversation
        /// override.
        public var hostSystemPrompt: String?
        /// Inject project MEMORY.md / DECISIONS.md (file tail) in addition
        /// to hybrid retrieval when memoryEnabled.
        public var injectProjectMemory: Bool
        /// Grok-class hybrid memory (index + first-turn recall).
        public var memoryEnabled: Bool
        /// Session log dream consolidation at turn end.
        public var dreamEnabled: Bool
        /// When true (and dreamEnabled), use `LLMMemoryConsolidator` against the
        /// turn's inference backend. **Default false** — opt-in cost/latency.
        /// Fail-open to extractive on model error/empty. Overridden by
        /// `dreamConsolidator` when non-nil.
        public var dreamLLMEnabled: Bool
        /// Optional host/test consolidator (wins over `dreamLLMEnabled`).
        public var dreamConsolidator: (any MemoryConsolidating)?
        /// Full-replace compaction when over budget (Grok code_compaction).
        public var fullReplaceCompactEnabled: Bool

        /// Unattended run. When true the loop injects the conservative
        /// `ChatLoop.headlessPrologue` for the whole turn and appends a
        /// markdown `buildHeadlessSummary` as a final assistant message
        /// when it settles — so a user returning in the morning has a
        /// readable status without scrolling the transcript. App-layer
        /// concerns (sleep assertion, completion notifications) are the
        /// caller's job; this flag governs only the in-loop behaviour so
        /// AgentCore stays platform-agnostic.
        public var headlessMode: Bool

        /// **Chat mode** (persisted as `rawMode` in settings): pure
        /// conversation with the model. When true:
        ///   • System prompt is empty (no host instructions, harness rules,
        ///     project rules, memory, skills, or orchestrator brief).
        ///   • Tools: only `web_search` + `read_file` (document read —
        ///     not a separate RAG stack). No shell/edit/MCP.
        ///   • No verify-edits, stall detection, grounding/edit/reflection
        ///     nudges, BuildGuard, or MCP tools.
        ///
        /// When false (**Agent mode**, default): full harness + all tools.
        ///
        /// Still active in chat mode:
        ///   • iteration cap, compaction, SafeMode allow-list (if set).
        public var rawMode: Bool

        /// Two-model mode: the brief produced by the orchestrator's
        /// planning pass. When non-nil, it's injected into the worker's
        /// system prompt as a high-priority execution plan so the worker
        /// (this loop) executes against a plan a stronger model already
        /// reasoned out. nil = single-model mode (no orchestrator ran).
        /// Agent mode only — chat mode ignores the brief.
        public var orchestratorBrief: String?

        /// Xcode MCP tools are live for this turn (via `mcpbridge`).
        /// Drives system-prompt injection and keeps Xcode tools in the
        /// always-relevant pruning set.
        public var xcodeMCPEnabled: Bool

        /// User-configured MCP servers (Streamable HTTP + stdio) from
        /// AppSettings. The loop creates an MCPServerPool at turn start,
        /// connects to all enabled servers, and exposes their tools as
        /// `server__tool` entries alongside VibeCoder's builtins.
        public var mcpServers: [MCPServerConfig]

        /// Thinking / reasoning effort for this turn. When non-nil, the
        /// loop passes it through to each ChatRequest so backends inject
        /// the right thinking parameters into their HTTP bodies.
        public var thinking: ThinkingRequestConfig?

        /// Goal-driven mode: when non-nil, the loop wraps each turn in
        /// goal orchestration (stall detection, cap enforcement, premature-
        /// stop defeat). The model's `halt` decisions are routed through
        /// the GoalOrchestrator, which can override them to keep driving
        /// toward goal completion. nil = single-turn mode (legacy behavior).
        ///
        /// See `GoalOrchestrator` for the state machine. The orchestrator
        /// auto-pauses on stall (same gap fingerprint N times) or cap hit,
        /// and defeats premature stops detected by `StopDetector`.
        public var goalDescription: String?

        /// Multi-turn goal seed (Wave C): carry stall/attempt counters across
        /// `AgentLoop.run` invocations for the same session goal.
        public var goalSeedAttemptCount: Int = 0
        public var goalSeedLastFingerprint: String? = nil
        public var goalSeedConsecutiveStallCount: Int = 0

        /// Input-card permission mode (plan / ask / auto / full). Enforced
        /// at tool dispatch — plan is hard read-only.
        public var executionMode: ExecutionMode?

        public init(maxIterations: Int = 30, stallWindow: Int = 3,
                    verifyEdits: Bool = true,
                    safeMode: SafeModeConfig? = nil,
                    patchReviewer: PatchReviewer? = nil,
                    userQuestionReviewer: UserQuestionReviewer? = nil,
                    shellApprovalCoordinator: ShellApprovalCoordinator? = nil,
                    disabledToolNames: Set<String> = [],
                    contextBudgetTokens: Int? = nil,
                    hostSystemPrompt: String? = nil,
                    injectProjectMemory: Bool = true,
                    memoryEnabled: Bool = true,
                    dreamEnabled: Bool = true,
                    dreamLLMEnabled: Bool = false,
                    dreamConsolidator: (any MemoryConsolidating)? = nil,
                    fullReplaceCompactEnabled: Bool = true,
                    headlessMode: Bool = false,
                    rawMode: Bool = false,
                    orchestratorBrief: String? = nil,
                    xcodeMCPEnabled: Bool = false,
                    mcpServers: [MCPServerConfig] = [],
                    thinking: ThinkingRequestConfig? = nil,
                    goalDescription: String? = nil,
                    goalSeedAttemptCount: Int = 0,
                    goalSeedLastFingerprint: String? = nil,
                    goalSeedConsecutiveStallCount: Int = 0,
                    executionMode: ExecutionMode? = nil) {
            self.maxIterations = maxIterations
            self.stallWindow = stallWindow
            self.verifyEdits = verifyEdits
            self.safeMode = safeMode
            self.patchReviewer = patchReviewer
            self.userQuestionReviewer = userQuestionReviewer
            self.shellApprovalCoordinator = shellApprovalCoordinator
            self.disabledToolNames = disabledToolNames
            self.contextBudgetTokens = contextBudgetTokens
            self.hostSystemPrompt = hostSystemPrompt
            self.injectProjectMemory = injectProjectMemory
            self.memoryEnabled = memoryEnabled
            self.dreamEnabled = dreamEnabled
            self.dreamLLMEnabled = dreamLLMEnabled
            self.dreamConsolidator = dreamConsolidator
            self.fullReplaceCompactEnabled = fullReplaceCompactEnabled
            self.headlessMode = headlessMode
            self.rawMode = rawMode
            self.orchestratorBrief = orchestratorBrief
            self.xcodeMCPEnabled = xcodeMCPEnabled
            self.mcpServers = mcpServers
            self.thinking = thinking
            self.goalDescription = goalDescription
            self.goalSeedAttemptCount = goalSeedAttemptCount
            self.goalSeedLastFingerprint = goalSeedLastFingerprint
            self.goalSeedConsecutiveStallCount = goalSeedConsecutiveStallCount
            self.executionMode = executionMode
        }
    }

    private let backend: InferenceBackend
    private let model: ModelDescriptor
    private let registry: ToolRegistry
    private let config: Configuration
    private let policyEngine: PolicyEngine

    /// MCP server pool for the current turn. Created at turn start when
    /// `config.mcpServers` is non-empty; nil means no user-configured
    /// MCP servers (only builtins + optional Xcode mcpbridge run).
    private var mcpServerPool: MCPServerPool?

    public init(backend: InferenceBackend, model: ModelDescriptor,
                registry: ToolRegistry = .shared,
                config: Configuration = .init()) {
        self.backend = backend
        self.model = model
        self.registry = registry
        self.config = config
        self.policyEngine = PolicyProfile.engine(
            headless: config.headlessMode,
            raw: config.rawMode)
    }

    /// Drive one user turn end-to-end. Emits incremental events for the
    /// UI to render. Returns when the loop has settled (no more tool
    /// calls, stalled, cancelled, or iteration cap hit).
    ///
    /// Cancellation is GRACEFUL: the method returns the conversation as
    /// accumulated so far (with synthetic tool results closing any open
    /// tool calls) rather than throwing, so the caller can persist the
    /// partial turn.
    public func run(
        userMessage: String,
        conversation: Conversation,
        sampling: SamplingParams? = nil,
        images: [ChatImagePayload] = [],
        /// When the UI already inserted an optimistic user bubble, pass its
        /// id so the loop reuses it (stable SwiftUI identity) and does not
        /// create a second message on `.userMessage` / final merge.
        userMessageId: UUID? = nil,
        events: @escaping @Sendable (LoopEvent) async -> Void
    ) async throws -> Conversation {
        // Pick sampling params: caller override → model-class preset → .coder fallback.
        let sampling = sampling ?? SamplingParams.preset(forParameterCountB: model.parameterCountB ?? 0)

        // PB1: SessionStart on first turn of a conversation (empty history).
        // True once-per-session app wiring remains optional; deny blocks the turn.
        // Optimistic UI inserts are NOT part of `conversation` here — the
        // caller passes the pre-send history so first-turn SessionStart still fires.
        if conversation.messages.isEmpty {
            let ss = HookDispatcher.sessionStart(
                projectRoot: conversation.projectRoot,
                worktreeRoot: conversation.worktreeRootURL
            )
            if !ss.allow {
                let reason = ss.message ?? "Denied by SessionStart hook"
                await events(.finished(reason: reason))
                // PC5: Stop fires even when the turn is blocked at SessionStart.
                Self.fireStopHook(reason: reason, conversation: conversation)
                return conversation
            }
        }

        var convo = conversation
        // Tracks reason for PB1/PC5 Stop hook at natural end of `run`.
        // Early returns call `fireStopHook` directly so cancel/halt never skip Stop.
        var lifecycleStopReason = "finished"
        /// True after any path already emitted `.finished` / `turnEnd` this run.
        var didEmitFinished = false
        var refill = RapidRefillBreaker()
        /// One reactive compact + retry per consecutive overflow; a second
        /// overflow after that compact fails the turn.
        var didReactiveCompactThisStep = false
        var stopContinuationCount = 0
        /// Natural no-tool finish already ran `stopDetailed` — skip trailing `stop`.
        var stopHookAlreadyFired = false
        let userMsg = ChatMessage(
            id: userMessageId ?? UUID(),
            role: .user,
            content: userMessage,
            images: images)
        convo.messages.append(userMsg)
        // Surface the user message to listeners immediately. Without
        // this the chat UI shows nothing for the user's turn until the
        // entire agent loop returns — a 10-60s gap where the user is
        // staring at a streaming assistant bubble with no echo of what
        // they just sent. Using the same `userMsg` value both here and
        // in `convo.messages` means SwiftUI's id-keyed ForEach won't
        // re-mount the bubble when `finalConvo` is applied at the end.
        // (Chat UI may already have shown this id optimistically before
        // orchestrator planning; consumers should de-dupe by id.)
        await events(.userMessage(userMsg))

        // Index of the first message of THIS turn — the edit-verification
        // gate only looks at what changed after this point.
        let turnStartIndex = convo.messages.count - 1

        // `worktreeRootURL` is non-nil only when worktree mode is on AND
        // `projectRoot` is set — it derives `<projectPath>-agentcore-<id>`
        // from the persisted branch suffix. Routing it into ToolContext
        // here is what causes every mutating tool to land its writes
        // inside the isolated worktree instead of the user's main tree.
        // Hydrate durable folder/tool grants so MutationReview + path
        // confinement honor "Always allow this folder" for the whole turn.
        // Also load project/user PermissionRules (.vibecoder/permissions.json).
        var authConfig = AuthorizationConfig.empty
        do {
            let projectKey = RememberedGrants.projectKey(from: ToolContext(
                projectRoot: convo.projectRoot,
                worktreeRoot: convo.worktreeRootURL,
                conversationID: convo.id
            ))
            var grants = await RememberedGrants.shared.snapshot(projectKey: projectKey)
            let durable = await DurableGrantStore.shared.snapshot(projectKey: projectKey)
            for (k, v) in durable { grants[k] = v }
            authConfig = AuthorizationConfig(remembered: grants)
            let fileRules = PermissionRules.load(
                projectRoot: convo.projectRoot,
                includeHome: true,
                includeClaudeSettings: true,
                projectKey: projectKey)
            authConfig = PermissionRules.merge(into: authConfig, snapshot: fileRules)
        }
        var context = ToolContext(
            projectRoot: convo.projectRoot,
            worktreeRoot: convo.worktreeRootURL,
            safeMode: config.safeMode,
            patchReviewer: config.patchReviewer,
            userQuestionReviewer: config.userQuestionReviewer,
            shellApprovalCoordinator: config.shellApprovalCoordinator,
            conversationID: convo.id,
            inferenceBackend: backend,
            model: model,
            subagentDepth: 0,
            executionMode: config.executionMode,
            authorization: authConfig,
            disabledToolNames: config.disabledToolNames
        )

        // PA4: open a filesystem turn checkpoint so mutating tools can
        // snapshot pre-state; /rewind and restore_checkpoint restore it.
        _ = await CheckpointStore.shared.beginTurn(
            conversationID: convo.id,
            projectRoot: convo.projectRoot
        )

        var iteration = 0
        var recentToolSignatures: [String] = []
        var recentToolErrorFlags: [Bool] = []
        var recentToolCalls: [ToolCallSnapshot] = []
        var recentErrorCounts: [Int] = []
        var lastToolOutput: ToolOutputInfo?
        var pendingNudges: [String] = []
        var groundingForceCount = 0
        var editVerifyForceCount = 0
        var reflectionNudgedThisIteration = false
        var decisionAlreadyNudged = false
        var lastReflectionIteration = -1_000
        // Throttle automatic BuildGuard after a *successful* compile.
        // Full xcodebuild after every mutating iteration dominates wall
        // time on local models. Always verify when we have never passed,
        // or after a failure; after a pass, re-check every 3rd mutating
        // batch. `.noBuildSystem` is cheap and does not throttle.
        var lastBuildGuardFailed = false
        var hasBuildGuardPass = false
        var mutatingBatchesSinceBuildGuard = 0

        // ── Per-turn caches (computed once, reused every iteration) ────────────
        // All of these are static for the lifetime of one user turn:
        //   • Project instructions / memory files aren't written by the agent itself.
        //   • The tool registry is immutable during a run.
        // Pulling them outside the loop eliminates hundreds of redundant disk reads,
        // directory enumerations, JSON decodes, and actor hops across iterations.

        // Project instructions: single disk read.
        let cachedInstructions: String? = config.rawMode ? nil
            : ChatLoop.loadProjectInstructions(projectRoot: convo.projectRoot)

        // Hierarchical project rules (Wave B S8): AGENTS.md / CLAUDE.md /
        // .claude/rules / .cursor/rules from root → cwd. Never root-only
        // AGENTS.md — that path shadowed nested package rules.
        let cachedAgentsMd: String? = {
            guard !config.rawMode, let root = convo.projectRoot else { return nil }
            let cwd = convo.worktreeRootURL ?? root
            let snap = ProjectRules.load(
                projectRoot: root, cwd: cwd, includeHomeRules: true)
            return snap.injectedText.isEmpty ? nil : snap.injectedText
        }()

        // Skills index (Wave B S2): discover once; full body via load_skill.
        // Scan worktree + project so index matches LoadSkillTool roots.
        let cachedSkillsIndex: String? = config.rawMode ? nil
            : SkillDiscovery.indexBlock(
                projectRoot: convo.projectRoot,
                worktreeRoot: convo.worktreeRootURL)

        // Project memory: hybrid recall (Grok) + optional file inject.
        // Prefer projectRoot for AppSupport workspace identity so worktrees
        // of the same project share MEMORY (not fork by worktree path hash).
        // File inject also reads MEMORY/DECISIONS/SESSION_HANDOFF from the
        // main project folder, not the worktree copy.
        let memoryRoot = convo.projectRoot ?? convo.worktreeRootURL
        let memoryBackend: MemoryBackend? = {
            guard config.memoryEnabled && !config.rawMode, let root = memoryRoot else { return nil }
            return MemoryBackend(workspacePath: root)
        }()

        // D3: optional dream consolidator (inject > LLM flag > extractive).
        let dreamConsolidator: (any MemoryConsolidating)? = MemoryConsolidatorResolver.resolve(
            injected: config.dreamConsolidator,
            llmEnabled: config.dreamLLMEnabled && config.dreamEnabled && !config.rawMode,
            backend: backend,
            model: model)
        let lastUserQuery: String = convo.messages.last(where: { $0.role == .user })?.content ?? ""
        let cachedMemory: String? = {
            guard !config.rawMode else { return nil }
            var parts: [String] = []
            if let mb = memoryBackend, let block = mb.recallBlock(query: lastUserQuery) {
                parts.append(block)
            }
            if config.injectProjectMemory,
               let fileMem = ChatLoop.loadProjectMemory(projectRoot: memoryRoot) {
                parts.append(fileMem)
            }
            if parts.isEmpty { return nil }
            return parts.joined(separator: "\n\n")
        }()

        // Connect user-configured MCP servers via session holder so consecutive
        // turns reuse stdio/HTTP clients (no reconnect + tools/list every send).
        // Chat mode skips MCP entirely — only web_search + read_file.
        //
        // Config walker precedence (Grok Build two-axis):
        //   1. ~/.vibecoder/mcp.json (global base)
        //   2. AppSettings.mcpServers (UI-managed, fill-if-missing)
        //   3. .mcp.json files (project-local overrides, cwd wins)
        var mcpSchemas: [ToolSchema] = []
        /// When true, pool is owned by MCPSessionHolder — do not disconnect on turn end.
        var mcpPoolIsSessionShared = false
        if !config.rawMode {
            // Never walk `/.mcp.json` — Finder-launched apps often have CWD `/`.
            let mcpCwd = PathConfinement.usableWorkspaceRoot(
                worktree: convo.worktreeRootURL, project: convo.projectRoot)
            let resolvedMcpServers = MCPConfigWalker.resolveMcpServers(
                cwd: mcpCwd,
                appSettingsServers: config.mcpServers)
            if !resolvedMcpServers.isEmpty {
                let acquired = await MCPSessionHolder.shared.acquire(servers: resolvedMcpServers)
                mcpServerPool = acquired.pool
                mcpSchemas = acquired.schemas
                mcpPoolIsSessionShared = acquired.pool != nil
            }
        }
        let mcpToolNames = Set(mcpSchemas.map(\.name))

        // Tool schemas: re-assembled each iteration so `tool_search` unlocks
        // of deferred tools take effect mid-turn (Wave fix).
        let toolClassification = await ToolClassification.load(
            registry: registry,
            xcodeMCPEnabled: config.xcodeMCPEnabled)
        // ──────────────────────────────────────────────────────────────────────

        // Wave C: rehydrate structured plan from disk/transcript so
        // GoalAssessment + update_todo work after process restart.
        let workDir = context.usableWorkspaceRoot
        _ = await PlanStore.shared.hydrateIfNeeded(
            for: convo.id,
            messages: convo.messages,
            workingDirectory: workDir)

        // Goal-driven mode: create an orchestrator when a goal description
        // is set. The orchestrator intercepts halts to defeat premature stops
        // and tracks stall/cap for goal completion. nil = single-turn mode.
        // Wave C: seed multi-turn attempt/stall counters from the host.
        let goalOrchestrator: GoalOrchestrator? = config.goalDescription.map { goalText in
            if config.goalSeedAttemptCount > 0
                || config.goalSeedLastFingerprint != nil
                || config.goalSeedConsecutiveStallCount > 0 {
                return GoalOrchestrator(
                    goalDescription: goalText,
                    seedAttemptCount: config.goalSeedAttemptCount,
                    seedLastFingerprint: config.goalSeedLastFingerprint,
                    seedConsecutiveStallCount: config.goalSeedConsecutiveStallCount)
            }
            return GoalOrchestrator(goalDescription: goalText)
        }

        await ExtensionRegistry.shared.turnStart(conversation: convo)
        // Session-shared MCP pools stay connected across turns. Only clear
        // the local reference (do not disconnectAll).
        defer {
            mcpServerPool = nil
            _ = mcpPoolIsSessionShared
        }

        while iteration < config.maxIterations {
            if Task.isCancelled {
                await InterjectionBuffer.shared.clear(conversationId: convo.id)
                // Grok dream consolidation (best-effort)
                // Wave C: flush session log so dream has fuel; always turnEnd.
                await Self.captureEndOfTurnMemory(memoryBackend, conversation: convo, dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
                await ExtensionRegistry.shared.turnEnd(conversation: convo, reason: "cancelled")
                await events(.finished(reason: "cancelled"))
                Self.fireStopHook(reason: "cancelled", conversation: convo)
                return convo
            }
            iteration += 1
            reflectionNudgedThisIteration = false
            await events(.iterationStarted(iteration: iteration))

            // Mid-turn user interjections (Grok interjection buffer).
            // App enqueues while a turn is running; drain at iteration start
            // and again mid-dispatch (see applyInterjections).
            await Self.applyInterjections(
                conversationId: convo.id,
                convo: &convo,
                pendingNudges: &pendingNudges,
                events: events)
            // Depth D4: background job completion → next-iteration model inject.
            await Self.applyWakeInjects(
                conversationId: convo.id,
                convo: &convo,
                pendingNudges: &pendingNudges,
                events: events)

            // Re-assemble each iteration so `tool_search` unlocks of deferred
            // tools appear in the next model request mid-turn.
            var allTools = await ToolSchemaAssembler.baseSchemas(
                registry: registry,
                conversation: convo,
                config: config,
                mcpSchemas: mcpSchemas)

            // Dynamic tool pruning (iteration 2+): strip rarely-needed
            // tool schemas to save 500–1500 tokens per iteration. The
            // "always relevant" set covers every normal coding task; the
            // rest are only included if the model already used them this turn.
            // User MCP tools stay available for the whole turn (not pruned).
            // Unlocked deferred tools stay available for the rest of the turn.
            if iteration > 1 && !config.rawMode {
                let alwaysRelevant = toolClassification.alwaysRelevant
                let usedThisTurn = Set(
                    convo.messages[turnStartIndex...]
                        .flatMap { $0.toolCalls }
                        .map { $0.name }
                )
                let unlocked = Set(convo.unlockedDeferredTools)
                allTools = allTools.filter { schema in
                    alwaysRelevant.contains(schema.name)
                        || usedThisTurn.contains(schema.name)
                        || mcpToolNames.contains(schema.name)
                        || unlocked.contains(schema.name)
                }
            }
            let tools = allTools

            // Compose the messages: system prompt + (compacted) history.
            // Pass pre-cached values to avoid redundant I/O every iteration.
            let (systemPrompt, systemPromptTokens) = AgentSystemPromptComposer.compose(
                .init(
                    conversation: convo,
                    config: config,
                    model: model,
                    nudges: pendingNudges,
                    messages: convo.messages,
                    cachedInstructions: cachedInstructions,
                    cachedMemory: cachedMemory,
                    cachedAgentsMd: cachedAgentsMd,
                    cachedSkillsIndex: cachedSkillsIndex))
            pendingNudges = []
            var requestMessages: [ChatMessage] = []
            // Chat mode (and any empty compose) must not send role=system with
            // empty/null content — several local servers stall or 400 on that.
            if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                requestMessages.append(.init(role: .system, content: systemPrompt))
            }
            // Wire copy only — persisted `convo` stays full (same as today's
            // FullReplace). Micro-clear old compactable tool bodies, then
            // compress so compactHistory's estimate sees the reduced sizes.
            var wireHistory = MicroCompactor.compact(messages: convo.messages)
            wireHistory = ToolResultCompressor.compress(wireHistory)
            if let budget = config.contextBudgetTokens {
                // Structural compact: FullReplace first; if it drops nothing
                // (no safe cut), fall through to Semantic so exclusivity does
                // not leave us elision-only when FR no-ops (Wave C2).
                var didStructuralCompact = false
                if config.fullReplaceCompactEnabled && !config.rawMode,
                   FullReplaceCompactor.shouldCompact(
                    messages: wireHistory,
                    systemPromptTokens: systemPromptTokens,
                    budgetTokens: budget) {
                    if refill.shouldHardStop() {
                        return await finishRapidRefillBlocked(
                            convo: convo,
                            memoryBackend: memoryBackend,
                            dreamConsolidator: dreamConsolidator,
                            events: events)
                    }
                    // Pre-compact memory flush (Grok memory_flush) — best-effort
                    if let mb = memoryBackend {
                        let durable = wireHistory
                            .filter { $0.role == .assistant }
                            .suffix(3)
                            .map { String($0.content.prefix(200)) }
                            .joined(separator: "\n")
                        try? mb.flushConversation(
                            sessionId: convo.id.uuidString,
                            messages: wireHistory,
                            plantedNote: durable.isEmpty ? nil : durable)
                    }
                    let fr = await FullReplaceCompactor.compact(
                        wireHistory,
                        systemPromptTokens: systemPromptTokens,
                        budgetTokens: budget)
                    if fr.droppedCount > 0 {
                        didStructuralCompact = true
                        await events(.contextCompacted(
                            summaryPreview: String(fr.summary.prefix(240)),
                            droppedMessages: fr.droppedCount))
                        if let mb = memoryBackend, !fr.durableNote.isEmpty {
                            mb.markCompactionRecovery(fr.durableNote)
                        }
                        wireHistory = fr.messages
                        // Recovery inject as system nudge once
                        if let mb = memoryBackend,
                           let recovery = mb.injectRecovery(query: lastUserQuery) {
                            pendingNudges.append(SystemReminder.memoryFirstTurn(recovery))
                        }
                    }
                }
                if !didStructuralCompact {
                    let semantic = await SemanticCompactor.compact(
                        wireHistory,
                        systemPromptTokens: systemPromptTokens,
                        budgetTokens: budget)
                    if semantic.didCompact {
                        await events(.contextCompacted(
                            summaryPreview: String((semantic.summary ?? "").prefix(240)),
                            droppedMessages: semantic.droppedCount))
                        wireHistory = semantic.messages
                    }
                }
                requestMessages.append(contentsOf: ChatLoop.compactHistory(
                    wireHistory,
                    systemPromptTokens: systemPromptTokens,
                    budgetTokens: budget))
            } else {
                requestMessages.append(contentsOf: wireHistory)
            }

            let request = ChatRequest(model: model, messages: requestMessages,
                                      tools: tools, sampling: sampling,
                                      thinking: config.thinking)

            // Stream the model response.
            //
            // Tool calls are bucketed by `index` (NOT id) because OpenAI-
            // compatible backends send `id` only on the first fragment per
            // call. Keying by id would create a separate bucket per
            // fragment and shred the JSON arguments. See InferenceBackend
            // .toolCallDelta doc comment for the full rationale.
            var assistantContent = ""
            var assistantReasoning = ""
            var streamAccumulator = ResponseNormalizer.Accumulator()
            var finishReason = "stop"
            var streamCancelled = false
            // Thinking window: first reasoning token → first content/tool token
            // (or stream end / cancel if thinking-only).
            var reasoningStartedAt: Date? = nil
            var reasoningEndedAt: Date? = nil

            do {
                for try await chunk in backend.stream(request: request) {
                    switch chunk {
                    case .reasoningDelta(let delta):
                        if reasoningStartedAt == nil { reasoningStartedAt = Date() }
                        assistantReasoning += delta
                        await events(.reasoningDelta(delta))
                    case .contentDelta(let delta):
                        // Freeze think duration at first non-reasoning token.
                        if reasoningEndedAt == nil, reasoningStartedAt != nil {
                            reasoningEndedAt = Date()
                        }
                        assistantContent += delta
                        streamAccumulator.ingestContentDelta(delta)
                        await events(.contentDelta(delta))
                    case .toolCallDelta(let index, let id, let name, let argsAppend):
                        if reasoningEndedAt == nil, reasoningStartedAt != nil {
                            reasoningEndedAt = Date()
                        }
                        streamAccumulator.ingestToolCallDelta(
                            index: index, id: id, name: name, argumentsAppend: argsAppend)
                    case .usage(let promptTokens, let completionTokens):
                        // Surface the server's actual token counts so the
                        // context meter can calibrate to real usage instead of
                        // the chars/4 estimate. Ignored by the UI when a server
                        // doesn't report usage (no event is emitted).
                        await events(.usage(
                            promptTokens: promptTokens,
                            completionTokens: completionTokens))
                    case .done(let reason):
                        finishReason = reason
                    }
                }
            } catch is CancellationError {
                streamCancelled = true
            } catch let urlError as URLError where urlError.code == .cancelled {
                streamCancelled = true
            } catch {
                let overflow = ContextOverflowClassifier.isContextExceeded(error: error)
                    || ContextOverflowClassifier.isContextExceeded(error.localizedDescription)
                if overflow && !didReactiveCompactThisStep {
                    didReactiveCompactThisStep = true
                    if refill.shouldHardStop() {
                        return await finishRapidRefillBlocked(
                            convo: convo,
                            memoryBackend: memoryBackend,
                            dreamConsolidator: dreamConsolidator,
                            events: events)
                    }
                    let didShrink = await applyReactiveCompact(
                        convo: &convo,
                        systemPromptTokens: systemPromptTokens,
                        events: events)
                    if didShrink {
                        refill.recordCompact()
                    }
                    if refill.shouldHardStop() {
                        return await finishRapidRefillBlocked(
                            convo: convo,
                            memoryBackend: memoryBackend,
                            dreamConsolidator: dreamConsolidator,
                            events: events)
                    }
                    await events(.info("Context overflow — compacted and retrying"))
                    iteration = max(0, iteration - 1)
                    continue
                }
                await events(.error(description: error.localizedDescription))
                await InterjectionBuffer.shared.clear(conversationId: convo.id)
                await Self.captureEndOfTurnMemory(
                    memoryBackend, conversation: convo,
                    dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
                await ExtensionRegistry.shared.turnEnd(conversation: convo, reason: "error")
                await events(.finished(reason: "error: \(error.localizedDescription)"))
                Self.fireStopHook(reason: "error", conversation: convo)
                mcpServerPool = nil
                throw error
            }
            didReactiveCompactThisStep = false

            let thinkingDurationSeconds: Int? = {
                guard !assistantReasoning.isEmpty, let start = reasoningStartedAt else { return nil }
                let end = reasoningEndedAt ?? Date()
                return max(1, Int(end.timeIntervalSince(start).rounded()))
            }()

            if streamCancelled || Task.isCancelled {
                // Keep prose AND partial reasoning so the user can re-read
                // what the model thought before Stop. DROP partial tool
                // calls — their argument JSON is truncated and replaying
                // it would only mislead the model later.
                let (body, reasoning, thinkSecs) = Self.normalizeAssistantThinking(
                    channelReasoning: assistantReasoning,
                    content: assistantContent,
                    thinkingDurationSeconds: thinkingDurationSeconds
                )
                if !body.isEmpty || reasoning != nil {
                    let partial = ChatMessage(
                        role: .assistant,
                        content: body,
                        reasoningContent: reasoning,
                        thinkingDurationSeconds: thinkSecs
                    )
                    convo.messages.append(partial)
                    await events(.assistantMessage(partial))
                }
                await InterjectionBuffer.shared.clear(conversationId: convo.id)
                // Grok dream consolidation (best-effort)
                // Wave C: flush session log so dream has fuel; always turnEnd.
                await Self.captureEndOfTurnMemory(memoryBackend, conversation: convo, dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
                await ExtensionRegistry.shared.turnEnd(conversation: convo, reason: "cancelled")
                await events(.finished(reason: "cancelled"))
                Self.fireStopHook(reason: "cancelled", conversation: convo)
                return convo
            }

            let normalized = streamAccumulator.finalize()
            let invocations = normalized.toolCalls.map { call in
                let cid = call.id.isEmpty
                    ? "tool_\(UUID().uuidString.prefix(8))"
                    : call.id
                return ToolCallInvocation(id: cid, name: call.name, arguments: call.arguments)
            }
            // Prefer dedicated reasoning channel; else promote <think> tags out
            // of content so history/panel get reasoningContent + clean body.
            // Parse tags from the raw stream so inline-cleaned content (think
            // blocks already stripped before extract) still yields reasoning.
            let thinkingSource = assistantContent.isEmpty ? normalized.content : assistantContent
            let (taggedBody, reasoningSnapshot, stampedThinkSecs) =
                Self.normalizeAssistantThinking(
                    channelReasoning: assistantReasoning,
                    content: thinkingSource,
                    thinkingDurationSeconds: thinkingDurationSeconds
                )
            let displayContent = normalized.usedInlineFallback
                ? normalized.content
                : taggedBody
            let assistantMsg = ChatMessage(
                role: .assistant,
                content: displayContent,
                reasoningContent: reasoningSnapshot,
                toolCalls: invocations,
                thinkingDurationSeconds: stampedThinkSecs
            )
            convo.messages.append(assistantMsg)
            await events(.assistantMessage(assistantMsg))

            if invocations.isEmpty {
                // PC6: Deliver mid-turn steers before accepting natural stop.
                // Steers enqueued during this assistant stream never hit
                // mid-dispatch (no tools) and would otherwise be wiped by
                // InterjectionBuffer.clear at loop end.
                let steered = await Self.applyInterjections(
                    conversationId: convo.id,
                    convo: &convo,
                    pendingNudges: &pendingNudges,
                    events: events)
                if steered > 0 {
                    await events(.info(
                        "User interjection received — continuing turn with steer"))
                    continue
                }

                let finishSnapshot = Self.makeTurnSnapshot(
                    iteration: iteration, maxIterations: config.maxIterations,
                    stallWindow: config.stallWindow,
                    modelWantsToFinish: true,
                    lastAssistantContent: displayContent,
                    messages: convo.messages,
                    turnStartIndex: turnStartIndex,
                    recentToolSignatures: recentToolSignatures,
                    recentErrorFlags: recentToolErrorFlags,
                    recentToolCalls: recentToolCalls,
                    recentErrorCounts: recentErrorCounts,
                    lastToolOutput: lastToolOutput,
                    groundingForceCount: groundingForceCount,
                    editVerifyForceCount: editVerifyForceCount,
                    decisionAlreadyNudged: decisionAlreadyNudged,
                    toolClassification: toolClassification)
                // Finish path: hard stops only, then grounding → editVerify
                // sequentially (old AgentLoop order — not both nudges at once).
                let finishHalt = PolicyEngine([
                    IterationCapPolicy(),
                    GovernorPolicy(),
                ]).decide(finishSnapshot).halt
                if let finishHalt {
                    // Policy hard-stop: never mark a session goal complete.
                    if let goal = goalOrchestrator, !config.rawMode {
                        _ = await goal.evaluateTurnEnd(achieved: false, gaps: [finishHalt])
                        await events(.info(await goal.progressInfoLine()))
                    }
                    // Grok dream consolidation (best-effort)
                await Self.captureEndOfTurnMemory(memoryBackend, conversation: convo, dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
                    await ExtensionRegistry.shared.turnEnd(conversation: convo, reason: "finished")
                    await events(.finished(reason: finishHalt))
                    lifecycleStopReason = finishHalt
                    didEmitFinished = true
                    break
                }
                if !config.rawMode {
                    if case let .forceContinue(nudge, _) = GroundingPolicy().evaluate(finishSnapshot) {
                        if let nudge { pendingNudges.append(nudge) }
                        groundingForceCount += 1
                        continue
                    }
                    if case let .forceContinue(nudge, _) = EditVerifyPolicy().evaluate(finishSnapshot) {
                        if let nudge { pendingNudges.append(nudge) }
                        editVerifyForceCount += 1
                        continue
                    }
                }
                // Goal-driven mode on natural finish: StopDetector + real assessment.
                // Use display-normalized content (think tags stripped) for finish gates.
                if let goal = goalOrchestrator, !config.rawMode {
                    if let pattern = StopDetector.matchedStopPattern(displayContent) {
                        let nudge = StopDetector.continuationNudge(for: pattern)
                        pendingNudges.append(nudge)
                        await events(.info(
                            "Premature stop detected (\(pattern.rawValue)) — injecting continuation nudge"))
                        continue
                    }
                    let plan = await PlanStore.shared.plan(
                        for: convo.id, workingDirectory: context.usableWorkspaceRoot)
                    // goalOrchestrator is only created when goalDescription is set.
                    let goalText = config.goalDescription ?? ""
                    let assessment = GoalAssessment.assess(
                        goalDescription: goalText,
                        plan: plan,
                        recentErrorFlags: recentToolErrorFlags,
                        soft: GoalAssessment.SoftSignals(
                            buildVerified: hasBuildGuardPass && !lastBuildGuardFailed,
                            // Count only true tool outcomes (exclude BuildGuard flag appends
                            // by using recent tool call count as rounds proxy).
                            successfulToolRounds: recentToolCalls.filter { call in
                                !["create_plan", "update_todo", "revise_plan"].contains(call.tool)
                            }.count,
                            hadSuccessfulMutation: recentToolCalls.contains {
                                ["edit_file", "write_file", "apply_patch", "delete_file", "move_file"]
                                    .contains($0.tool)
                            }))
                    let action = await goal.evaluateTurnEnd(
                        achieved: assessment.achieved,
                        gaps: assessment.gaps)
                    await events(.info(await goal.progressInfoLine()))
                    switch action {
                    case .continue:
                        let nudge = GoalAssessment.continuationNudge(
                            goalDescription: goalText,
                            gaps: assessment.gaps)
                        pendingNudges.append(nudge)
                        await events(.info("Goal still open — continuing"))
                        continue
                    case .pause(let reason):
                        await events(.info("Goal paused: \(reason.label)"))
                await Self.captureEndOfTurnMemory(memoryBackend, conversation: convo, dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
                        await ExtensionRegistry.shared.turnEnd(conversation: convo, reason: "finished")
                        let pauseReason = "goal paused (\(reason.rawValue))"
                        await events(.finished(reason: pauseReason))
                        Self.fireStopHook(reason: pauseReason, conversation: convo)
                        return convo
                    case .stop:
                        break // fall through to dream + finished
                    }
                }
                // Stop-hook continuation: honor `continue` + additionalContext
                // up to `maxStopContinuations`. Cap/cancel/error still use
                // `fireStopHook` (drops continue).
                let stopReason = Self.canonicalStopReason(
                    finishReason, maxIterations: config.maxIterations)
                let stop = HookDispatcher.stopDetailed(
                    reason: stopReason,
                    projectRoot: convo.projectRoot,
                    worktreeRoot: convo.worktreeRootURL)
                if HookDispatcher.shouldContinueAfterStop(
                    stop, continuationCount: stopContinuationCount)
                {
                    let body = HookDispatcher.formatHookAdditionalContext(
                        [stop.additionalContext].compactMap { $0 })
                    if !body.isEmpty {
                        let inject = ChatMessage(
                            role: .user,
                            content: """
                            # System reminder — hook
                            \(body)
                            """)
                        convo.messages.append(inject)
                        await events(.userMessage(inject))
                    }
                    stopContinuationCount += 1
                    await events(.info("Stop hook requested continuation"))
                    continue
                }
                stopHookAlreadyFired = true
                // Grok dream consolidation (best-effort)
                // Wave C: flush session log so dream has fuel; always turnEnd.
                await Self.captureEndOfTurnMemory(memoryBackend, conversation: convo, dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
                await ExtensionRegistry.shared.turnEnd(conversation: convo, reason: "finished")
                await events(.finished(reason: finishReason))
                lifecycleStopReason = finishReason
                didEmitFinished = true
                break
            }

            // Stall detection via StallPolicy — canonical signatures from
            // ChatLoop.turnToolSignature + detectStuckPattern.
            if !config.rawMode {
                if let sig = ChatLoop.turnToolSignature(messages: convo.messages) {
                    recentToolSignatures.append(sig)
                    while recentToolSignatures.count > config.stallWindow {
                        recentToolSignatures.removeFirst()
                    }
                    // Client-side doom-loop signal (was unwired). When the same
                    // tool signature repeats ≥3 times, record and inject a
                    // course-correction nudge early (threshold 4 matches
                    // DoomLoopDetector confident tail_repetition policy).
                    let suffix = recentToolSignatures.suffix(3)
                    if suffix.count >= 3, Set(suffix).count == 1 {
                        let doom = DoomLoopDetector()
                        doom.recordClientRepetition(4)
                        if doom.abortTriggers() != nil {
                            pendingNudges.append(ChatLoop.reflectionNudge)
                            await events(.info(
                                "Doom-loop signal: identical tool signature repeated — injecting reflection nudge"))
                        }
                    }
                }
                let stallSnapshot = Self.makeTurnSnapshot(
                    iteration: iteration, maxIterations: config.maxIterations,
                    stallWindow: config.stallWindow,
                    modelWantsToFinish: false,
                    lastAssistantContent: assistantContent,
                    messages: convo.messages,
                    turnStartIndex: turnStartIndex,
                    recentToolSignatures: recentToolSignatures,
                    recentErrorFlags: recentToolErrorFlags,
                    recentToolCalls: recentToolCalls,
                    recentErrorCounts: recentErrorCounts,
                    lastToolOutput: lastToolOutput,
                    groundingForceCount: groundingForceCount,
                    editVerifyForceCount: editVerifyForceCount,
                    decisionAlreadyNudged: decisionAlreadyNudged,
                    toolClassification: toolClassification)
                if let halt = policyEngine.decide(stallSnapshot).halt {
                    if halt.hasPrefix("stalled") {
                        await events(.stalled(
                            repeatedSignature: recentToolSignatures.last ?? ""))
                    }
                    // IterationCapPolicy also runs on this pre-dispatch path;
                    // emit capHit so listeners match the after-while cap path.
                    // P4: normalize cap wording so Stop/finished match the
                    // post-while path (`iteration cap (N)`), not the policy's
                    // humanized "reached the N-iteration limit…".
                    let terminalReason = Self.canonicalStopReason(
                        halt, maxIterations: config.maxIterations)
                    if halt.contains("iteration limit") || terminalReason.hasPrefix("iteration cap") {
                        await events(.iterationCapHit(cap: config.maxIterations))
                    }
                    await Self.closeToolCalls(
                        invocations, reason: terminalReason, convo: &convo, events: events)
                    // Must emit .finished — previously we only broke the loop,
                    // so UI/terminal never got a terminal reason (stall/governor/cap).
                await Self.captureEndOfTurnMemory(memoryBackend, conversation: convo, dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
                    await ExtensionRegistry.shared.turnEnd(conversation: convo, reason: terminalReason)
                    await events(.finished(reason: terminalReason))
                    Self.fireStopHook(reason: terminalReason, conversation: convo)
                    return convo
                }
            }

            if config.xcodeMCPEnabled {
                await XcodeMCPBridge.shared.beginAgentTurn()
                // Re-assert live bridge so tools stay registered after Xcode relaunch.
                _ = await XcodeMCPBridge.shared.ensureConnected()
            }

            // User MCP pool was connected at turn start (schemas already
            // in `tools`). Do not reconnect mid-dispatch — that dropped
            // live clients and re-paid stdio handshake cost every iteration.

            // Dispatch read-only builtins concurrently; keep mutations serial.
            var anyMutation = false
            var pendingAutoVerifyPaths: [String] = []
            var cancelledMidDispatch = false
            var dispatchIndex = 0
            while dispatchIndex < invocations.count && !cancelledMidDispatch {
                if Task.isCancelled {
                    for remaining in invocations[dispatchIndex...] {
                        let result = ToolResult(content: "Cancelled by user before execution.", isError: true)
                        convo.messages.append(.init(role: .tool, content: result.content, toolCallID: remaining.id))
                        await events(.toolResult(invocation: remaining, result: result))
                    }
                    cancelledMidDispatch = true
                    break
                }

                // Do NOT append user interjections mid-tool-batch — that inserts
                // role=user between tool results and breaks OpenAI tool pairing
                // (strict servers 400). Steers stay buffered and apply after the
                // full tool batch (below) or at the next iteration start.
                let batchStart = dispatchIndex
                // Parallel only for true I/O-safe RO tools. Soft mutators
                // (plan store, tool_search unlock) and ask_user stay serial
                // even if the registry marks them .readOnly.
                while dispatchIndex < invocations.count,
                      await isParallelSafeReadOnlyDispatch(invocations[dispatchIndex].name) {
                    dispatchIndex += 1
                }
                let readOnlyBatch = Array(invocations[batchStart..<dispatchIndex])

                if readOnlyBatch.count > 1 {
                    for inv in readOnlyBatch {
                        let label = Self.toolActivityLabel(invocation: inv)
                        await events(.toolStarted(id: inv.id, name: inv.name, label: label))
                    }
                    let results = await dispatchReadOnlyBatch(readOnlyBatch, context: context)
                    for (inv, result) in zip(readOnlyBatch, results) {
                        let label = Self.toolActivityLabel(invocation: inv)
                        await events(.toolCompleted(id: inv.id, name: inv.name, label: label, isError: result.isError))
                        anyMutation = await recordToolResult(
                            inv, result: result, convo: &convo, context: &context,
                            recentToolErrorFlags: &recentToolErrorFlags,
                            lastToolOutput: &lastToolOutput,
                            pendingAutoVerifyPaths: &pendingAutoVerifyPaths,
                            events: events) || anyMutation
                    }
                } else if let inv = readOnlyBatch.first {
                    let result = await dispatchOne(inv, context: context, events: events)
                    anyMutation = await recordToolResult(
                        inv, result: result, convo: &convo, context: &context,
                        recentToolErrorFlags: &recentToolErrorFlags,
                        lastToolOutput: &lastToolOutput,
                        pendingAutoVerifyPaths: &pendingAutoVerifyPaths,
                        events: events) || anyMutation
                }

                // Parallel `task` fan-out: consecutive `task` calls, max 10.
                if Task.isCancelled {
                    for remaining in invocations[dispatchIndex...] {
                        let result = ToolResult(content: "Cancelled by user before execution.", isError: true)
                        convo.messages.append(.init(role: .tool, content: result.content, toolCallID: remaining.id))
                        await events(.toolResult(invocation: remaining, result: result))
                    }
                    cancelledMidDispatch = true
                    break
                }
                let taskStart = dispatchIndex
                while dispatchIndex < invocations.count,
                      invocations[dispatchIndex].name == "task",
                      dispatchIndex - taskStart < 10 {
                    dispatchIndex += 1
                }
                let taskBatch = Array(invocations[taskStart..<dispatchIndex])
                if !taskBatch.isEmpty {
                    let results = await dispatchTaskBatch(
                        taskBatch, context: context, events: events)
                    for (inv, result) in zip(taskBatch, results) {
                        anyMutation = await recordToolResult(
                            inv, result: result, convo: &convo, context: &context,
                            recentToolErrorFlags: &recentToolErrorFlags,
                            lastToolOutput: &lastToolOutput,
                            pendingAutoVerifyPaths: &pendingAutoVerifyPaths,
                            events: events) || anyMutation
                    }
                }

                while dispatchIndex < invocations.count,
                      !(await isParallelSafeReadOnlyDispatch(invocations[dispatchIndex].name)),
                      invocations[dispatchIndex].name != "task" {
                    // Cancel between serial mutators so Stop does not run remaining edits.
                    if Task.isCancelled {
                        for remaining in invocations[dispatchIndex...] {
                            let result = ToolResult(content: "Cancelled by user before execution.", isError: true)
                            convo.messages.append(.init(role: .tool, content: result.content, toolCallID: remaining.id))
                            await events(.toolResult(invocation: remaining, result: result))
                        }
                        cancelledMidDispatch = true
                        break
                    }
                    let inv = invocations[dispatchIndex]
                    dispatchIndex += 1
                    let result = await dispatchOne(inv, context: context, events: events)
                    anyMutation = await recordToolResult(
                        inv, result: result, convo: &convo, context: &context,
                        recentToolErrorFlags: &recentToolErrorFlags,
                        lastToolOutput: &lastToolOutput,
                        pendingAutoVerifyPaths: &pendingAutoVerifyPaths,
                        events: events) || anyMutation
                }
            }
            if !cancelledMidDispatch {
                refill.recordToolTurn()
            }
            // Flush AutoVerify after all tool results (pairing-safe).
            if !cancelledMidDispatch, !pendingAutoVerifyPaths.isEmpty {
                flushAutoVerify(
                    paths: pendingAutoVerifyPaths,
                    workingDirectory: context.workingDirectory,
                    convo: &convo)
                pendingAutoVerifyPaths.removeAll()
            }
            // Safe to inject steers only after every tool_call has a tool result.
            if !cancelledMidDispatch {
                await Self.applyInterjections(
                    conversationId: convo.id,
                    convo: &convo,
                    pendingNudges: &pendingNudges,
                    events: events)
            }
            if cancelledMidDispatch {
                await InterjectionBuffer.shared.clear(conversationId: convo.id)
                // Grok dream consolidation (best-effort)
                // Wave C: flush session log so dream has fuel; always turnEnd.
                await Self.captureEndOfTurnMemory(memoryBackend, conversation: convo, dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
                await ExtensionRegistry.shared.turnEnd(conversation: convo, reason: "cancelled")
                await events(.finished(reason: "cancelled"))
                Self.fireStopHook(reason: "cancelled", conversation: convo)
                return convo
            }

            for inv in invocations {
                recentToolCalls.append(ToolCallSnapshot(tool: inv.name, arguments: inv.arguments))
            }
            while recentToolCalls.count > 12 { recentToolCalls.removeFirst() }

            if !config.rawMode {
                let allowReflection = iteration - lastReflectionIteration >= 3
                let postSnapshot = Self.makeTurnSnapshot(
                    iteration: iteration, maxIterations: config.maxIterations,
                    stallWindow: config.stallWindow,
                    modelWantsToFinish: false,
                    lastAssistantContent: assistantContent,
                    messages: convo.messages,
                    turnStartIndex: turnStartIndex,
                    recentToolSignatures: recentToolSignatures,
                    recentErrorFlags: recentToolErrorFlags,
                    recentToolCalls: recentToolCalls,
                    recentErrorCounts: recentErrorCounts,
                    lastToolOutput: lastToolOutput,
                    groundingForceCount: groundingForceCount,
                    editVerifyForceCount: editVerifyForceCount,
                    reflectionAlreadyNudged: reflectionNudgedThisIteration,
                    decisionAlreadyNudged: decisionAlreadyNudged,
                    allowReflectionNudge: allowReflection,
                    toolClassification: toolClassification)
                let postDecision = policyEngine.decide(postSnapshot)
                if let halt = postDecision.halt {
                    // Policy hard-stops (stall/governor/cap) always win.
                    // StopDetector only applies on *natural* finish (no tools),
                    // not after tool dispatch — bail prose must not defeat caps.
                    // Never mark the goal achieved on stall/governor/cap.
                    if let goal = goalOrchestrator, !config.rawMode {
                        let action = await goal.evaluateTurnEnd(
                            achieved: false,
                            gaps: [halt])
                        await events(.info(await goal.progressInfoLine()))
                        if case .pause(let reason) = action {
                            await events(.info("Goal paused: \(reason.label)"))
                            await Self.captureEndOfTurnMemory(
                                memoryBackend, conversation: convo,
                                dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
                            await ExtensionRegistry.shared.turnEnd(conversation: convo, reason: "finished")
                            let pauseReason = "goal paused (\(reason.rawValue))"
                            await events(.finished(reason: pauseReason))
                            Self.fireStopHook(reason: pauseReason, conversation: convo)
                            return convo
                        }
                    }
                    // Policy hard-stop wins (goal not marked complete).
                    await Self.captureEndOfTurnMemory(
                        memoryBackend, conversation: convo,
                        dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
                    await ExtensionRegistry.shared.turnEnd(conversation: convo, reason: "finished")
                    await events(.finished(reason: halt))
                    lifecycleStopReason = halt
                    didEmitFinished = true
                    break
                }
                if postDecision.nudges.contains(ChatLoop.reflectionNudge) {
                    lastReflectionIteration = iteration
                    reflectionNudgedThisIteration = true
                }
                if postDecision.nudges.contains(ChatLoop.decisionLoggingNudge) {
                    decisionAlreadyNudged = true
                }
                pendingNudges.append(contentsOf: postDecision.nudges)
            }

            // Stop after tools before expensive BuildGuard / next iteration.
            if Task.isCancelled {
                await InterjectionBuffer.shared.clear(conversationId: convo.id)
                await Self.captureEndOfTurnMemory(
                    memoryBackend, conversation: convo,
                    dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
                await ExtensionRegistry.shared.turnEnd(conversation: convo, reason: "cancelled")
                await events(.finished(reason: "cancelled"))
                Self.fireStopHook(reason: "cancelled", conversation: convo)
                didEmitFinished = true
                return convo
            }

            if anyMutation && config.verifyEdits && !config.rawMode {
                mutatingBatchesSinceBuildGuard += 1
                let shouldRunBuildGuard = !hasBuildGuardPass
                    || lastBuildGuardFailed
                    || mutatingBatchesSinceBuildGuard >= 3
                if shouldRunBuildGuard {
                    mutatingBatchesSinceBuildGuard = 0
                    let buildOutcome = await BuildGuard.verify(at: context.workingDirectory)
                    switch buildOutcome {
                    case .failed(let log):
                        lastBuildGuardFailed = true
                        // User-role system reminder — never an unpaired `.tool` row.
                        convo.messages.append(.init(
                            role: .user,
                            content: SystemReminder.buildGuard(
                                succeeded: false,
                                detail: String(log.prefix(8000)))))
                        recentToolErrorFlags.append(true)
                        recentErrorCounts.append(Governor.errorCount(inBuildLog: log))
                        await events(.buildFailed(log: log))
                    case .passed:
                        lastBuildGuardFailed = false
                        hasBuildGuardPass = true
                        // Inject success as a user-role system reminder so (1) the model
                        // knows the project compiles, (2) editAlreadyVerifiedThisTurn
                        // sees the success marker, without breaking OpenAI tool pairing.
                        convo.messages.append(.init(
                            role: .user,
                            content: SystemReminder.buildGuard(succeeded: true)))
                        recentToolErrorFlags.append(false)
                        recentErrorCounts.append(0)
                        await events(.buildPassed)
                    case .noBuildSystem:
                        // Cheap path — keep verifying next mutation until a project exists.
                        // Do not emit `.buildPassed` (that claimed a green build with no tool).
                        lastBuildGuardFailed = false
                        await events(.buildSkipped(reason:
                            "No Package.swift / .xcodeproj / Cargo.toml / package.json+tsconfig in the working directory."))
                    }
                }
            }

            // ZCode parity: emit step-finished so the UI can close out
            // this iteration's step marker. The loop may continue (more
            // tools to run) or break/return (.finished path, which also
            // emits .stepFinished via the converter).
            let stepSummary: String? = {
                if anyMutation { return "Edited files" }
                return nil
            }()
            await events(.stepFinished(iteration: iteration, summary: stepSummary))
        }

        // Only emit cap terminal events if we have not already finished
        // (finish / stall / governor break paths set didEmitFinished).
        let hitCap = iteration >= config.maxIterations
        if hitCap, !didEmitFinished {
            await events(.iterationCapHit(cap: config.maxIterations))
            // Cap exits the while without a finish-path event; emit one so
            // listeners (terminal notify, status) see a definitive end reason.
            let capReason = Self.iterationCapStopReason(config.maxIterations)
            await Self.captureEndOfTurnMemory(
                memoryBackend, conversation: convo,
                dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
            await ExtensionRegistry.shared.turnEnd(
                conversation: convo, reason: capReason)
            await events(.finished(reason: capReason))
            lifecycleStopReason = capReason
            didEmitFinished = true
        }

        // Headless wrap-up: append a readable status the user can scan in
        // the morning without replaying the transcript. Only on natural
        // settle / stall / cap — cancellation returns early above and
        // skips this (the user is already back at the keyboard).
        if config.headlessMode {
            let summary = ChatLoop.buildHeadlessSummary(
                messages: convo.messages,
                worktreePath: convo.worktreeRootURL?.path,
                iterations: iteration,
                hitCap: hitCap)
            let summaryMsg = ChatMessage(role: .assistant, content: summary)
            convo.messages.append(summaryMsg)
            await events(.assistantMessage(summaryMsg))
        }
        // Hard-stop fail-closed (P4): drop undelivered interjections so they
        // cannot appear as phantom user messages on the *next* AgentLoop.run.
        // See InterjectionBuffer.clear epoch bump — late enqueue is rejected.
        await InterjectionBuffer.shared.clear(conversationId: convo.id)
        // PB1/PC5/P4: Stop lifecycle after natural turn end (canonical reasons).
        // Natural no-tool finish already ran `stopDetailed` above.
        if !stopHookAlreadyFired {
            Self.fireStopHook(
                reason: Self.canonicalStopReason(
                    lifecycleStopReason, maxIterations: config.maxIterations),
                conversation: convo)
        }
        // Session-shared MCP: leave pool connected for the next turn.
        mcpServerPool = nil
        return convo
    }


    /// PC3/D3: end-of-turn memory flush + gated dream (best-effort; never aborts the turn).
    /// Optional consolidator enables LLM/inject dream; nil keeps extractive default.
    private static func captureEndOfTurnMemory(
        _ memoryBackend: MemoryBackend?,
        conversation: Conversation,
        dreamEnabled: Bool,
        consolidator: (any MemoryConsolidating)? = nil
    ) async {
        guard let mb = memoryBackend else { return }
        do {
            _ = try await mb.endTurnCapture(
                sessionId: conversation.id.uuidString,
                messages: conversation.messages,
                dreamEnabled: dreamEnabled,
                consolidator: consolidator)
        } catch {
            Diagnostics.warn(
                "endTurnCapture failed",
                detail: error.localizedDescription)
        }
    }

    // MARK: - Tool dispatch helpers

    private func dispatchOne(
        _ inv: ToolCallInvocation,
        context: ToolContext,
        events: @escaping @Sendable (LoopEvent) async -> Void
    ) async -> ToolResult {
        if config.disabledToolNames.contains(inv.name) {
            return ToolResult(
                content: "Error: tool `\(inv.name)` is disabled in Settings → Tools. Use a different tool or ask the user to enable it.",
                isError: true)
        }
        // Route namespaced MCP tools (`server__tool`) through the pool
        // after ToolAuthorization (Plan/Ask/deny/SafeMode). Never invoke
        // MCP before auth — user MCP servers can mutate remote state.
        if ToolAuthorization.isMCPToolName(inv.name) {
            let label = Self.toolActivityLabel(invocation: inv)
            await events(.toolStarted(id: inv.id, name: inv.name, label: label))
            // Parse arguments as a generic dict for MCP (the schema
            // comes from the server, not our ToolArguments decoder).
            let args: [String: Any]
            if let data = inv.arguments.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                args = parsed
            } else {
                args = [:]
            }
            let toolArgs = ToolArguments(dictionary: args)

            // Pre-tool hooks (same gate as ToolRegistry.execute).
            let pre = HookDispatcher.preTool(
                toolName: inv.name,
                argumentsSummary: String(describing: args),
                projectRoot: context.projectRoot,
                worktreeRoot: context.worktreeRoot)
            if !pre.allow {
                let msg = pre.message ?? "Denied by hook"
                await events(.toolCompleted(id: inv.id, name: inv.name, label: label, isError: true))
                return ToolResult(content: msg, isError: true)
            }

            // Hydrate live grants so ShellApproval "Always" within this turn
            // is honored on subsequent MCP calls (turn-start snapshot alone
            // would re-ask until the next agent turn).
            var rememberedGrants = context.authorization.remembered
            if !context.authorization.useInlineRememberedOnly {
                let projectKey = RememberedGrants.projectKey(from: context)
                let processSnap = await RememberedGrants.shared.snapshot(projectKey: projectKey)
                for (k, d) in processSnap { rememberedGrants[k] = d }
                let durableSnap = await DurableGrantStore.shared.snapshot(projectKey: projectKey)
                for (k, d) in durableSnap { rememberedGrants[k] = d }
            }
            let authOutcome = ToolAuthorization.authorizeMCP(
                toolName: inv.name,
                arguments: toolArgs,
                context: context,
                remembered: rememberedGrants)
            switch authOutcome {
            case .allow:
                break
            case .deny(let reason):
                await events(.toolCompleted(id: inv.id, name: inv.name, label: label, isError: true))
                return ToolResult(
                    content: "Permission denied: \(reason)",
                    isError: true)
            case .ask(let reason):
                // Wave B S4: same ShellApprovalGate as ToolRegistry (shell).
                let summary = String(describing: args).prefix(200)
                let gate = await ShellApprovalGate.resolve(
                    toolName: inv.name,
                    reason: reason,
                    kind: .mcp,
                    argumentsSummary: String(summary),
                    context: context)
                if !gate.allowed {
                    await events(.toolCompleted(id: inv.id, name: inv.name, label: label, isError: true))
                    return ToolResult(content: gate.denialMessage, isError: true)
                }
            }

            guard let pool = mcpServerPool else {
                await events(.toolCompleted(id: inv.id, name: inv.name, label: label, isError: true))
                return ToolResult(
                    content: "MCP error: no MCP server pool connected for this turn.",
                    isError: true)
            }
            do {
                let payload = try await pool.invokeTool(
                    namespacedName: inv.name, arguments: args)
                let content = Self.mcpResultContent(payload)
                let isErr = content.hasPrefix("MCP error:")
                    || (payload.value["isError"] as? Bool == true)
                let post = HookDispatcher.postTool(
                    toolName: inv.name,
                    resultSummary: String(content.prefix(200)),
                    projectRoot: context.projectRoot,
                    worktreeRoot: context.worktreeRoot)
                if !post.allow {
                    let msg = post.message ?? "Denied by post-tool hook"
                    let merged = content.isEmpty ? msg : "\(content)\n\n[PostTool hook deny] \(msg)"
                    await events(.toolCompleted(id: inv.id, name: inv.name, label: label, isError: true))
                    return ToolResult(content: merged, isError: true)
                }
                await events(.toolCompleted(id: inv.id, name: inv.name, label: label, isError: isErr))
                return ToolResult(content: content, isError: isErr)
            } catch {
                await events(.toolCompleted(id: inv.id, name: inv.name, label: label, isError: true))
                return ToolResult(content: "MCP error: \(error.localizedDescription)", isError: true)
            }
        }
        let label = Self.toolActivityLabel(invocation: inv)
        await events(.toolStarted(id: inv.id, name: inv.name, label: label))
        if inv.name == "ask_user",
           let args = try? ToolArguments(json: inv.arguments),
           let question = args.stringOptional("question"),
           !question.isEmpty {
            await events(.pendingQuestion(AgentQuestion(
                question: question,
                options: args.stringArray("options")
            )))
        }
        do {
            let args = try ToolArguments(json: inv.arguments)
            let result = try await registry.execute(name: inv.name, arguments: args, context: context)
            await events(.toolCompleted(id: inv.id, name: inv.name, label: label, isError: result.isError))
            return result
        } catch {
            await events(.toolCompleted(id: inv.id, name: inv.name, label: label, isError: true))
            return ToolResult(content: "Tool error: \(error.localizedDescription)", isError: true)
        }
    }

    /// Extract a display string from an MCP `tools/call` result payload.
    ///
    /// MCP results have a `content` array where each item has a `type`
    /// (usually "text") and a `text` field. We concatenate all text items.
    /// If the server reported an error (`isError: true`), we surface it.
    private static func mcpResultContent(_ payload: MCPJSONPayload) -> String {
        let value = payload.value
        if let content = value["content"] as? [[String: Any]] {
            let texts = content.compactMap { item -> String? in
                if let t = item["type"] as? String, t == "text",
                   let text = item["text"] as? String {
                    return text
                }
                // Non-text content (images, etc.) — summarize so the
                // model knows something was returned even if we can't
                // display it inline.
                if let t = item["type"] as? String {
                    return "[\(t) content]"
                }
                return nil
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        // Fallback: serialize the whole payload so the model sees something.
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "[empty MCP response]"
    }

    private static func toolActivityLabel(invocation: ToolCallInvocation) -> String {
        let args = ChatLoop.parseToolArgs(invocation.arguments)
        func str(_ key: String) -> String? { args[key] as? String }
        switch invocation.name {
        case "read_file", "read_file_range":
            let path = str("path") ?? str("file_path") ?? "file"
            let name = URL(fileURLWithPath: path).lastPathComponent
            return "Reading \(name)…"
        case "grep_code", "glob_files", "code_search":
            let query = str("pattern") ?? str("query") ?? str("glob") ?? "codebase"
            return "Searching for \(query)…"
        case "run_shell", "run_shell_command":
            let cmd = str("command") ?? "command"
            let short = cmd.count > 48 ? String(cmd.prefix(47)) + "…" : cmd
            return "Running \(short)…"
        case "edit_file", "apply_patch", "write_file":
            let path = str("path") ?? str("file_path") ?? "file"
            let name = URL(fileURLWithPath: path).lastPathComponent
            return "Editing \(name)…"
        case "create_plan":
            return "Planning…"
        case "update_todo":
            return "Updating plan…"
        case "ask_user":
            return "Waiting for your answer…"
        default:
            let human = invocation.name.replacingOccurrences(of: "_", with: " ")
            return human.prefix(1).uppercased() + human.dropFirst() + "…"
        }
    }

    /// Consecutive `task` invocations — `withTaskGroup` + `dispatchOne`, max 10.
    /// Other executes stay serial. Actor reentrancy overlaps at `await` points.
    private func dispatchTaskBatch(
        _ batch: [ToolCallInvocation],
        context: ToolContext,
        events: @escaping @Sendable (LoopEvent) async -> Void
    ) async -> [ToolResult] {
        if batch.count == 1, let inv = batch.first {
            return [await dispatchOne(inv, context: context, events: events)]
        }
        return await withTaskGroup(of: (Int, ToolResult).self) { group in
            for (index, inv) in batch.enumerated() {
                group.addTask {
                    let result = await self.dispatchOne(inv, context: context, events: events)
                    return (index, result)
                }
            }
            var slots = [ToolResult?](repeating: nil, count: batch.count)
            for await (index, result) in group {
                slots[index] = result
            }
            return slots.map { $0 ?? ToolResult(content: "Tool error: missing result", isError: true) }
        }
    }

    /// Parallel RO dispatch excludes `ask_user` — it suspends for a human
    /// and must emit `.pendingQuestion` via `dispatchOne`.
    private func isParallelSafeReadOnlyDispatch(_ name: String) async -> Bool {
        if name == "ask_user" { return false }
        return await registry.isParallelSafeReadOnlyTool(name)
    }

    private func dispatchReadOnlyBatch(
        _ batch: [ToolCallInvocation],
        context: ToolContext
    ) async -> [ToolResult] {
        var results = [ToolResult?](repeating: nil, count: batch.count)
        var runnable: [(index: Int, name: String, arguments: ToolArguments)] = []

        for (index, inv) in batch.enumerated() {
            if config.disabledToolNames.contains(inv.name) {
                results[index] = ToolResult(
                    content: "Error: tool `\(inv.name)` is disabled in Settings → Tools. Use a different tool or ask the user to enable it.",
                    isError: true)
                continue
            }
            do {
                let args = try ToolArguments(json: inv.arguments)
                runnable.append((index, inv.name, args))
            } catch {
                results[index] = ToolResult(
                    content: "Tool error: \(error.localizedDescription)", isError: true)
            }
        }

        if !runnable.isEmpty {
            let batchResults = await registry.executeReadOnlyBatch(
                invocations: runnable.map { ($0.name, $0.arguments) },
                context: context)
            for (offset, item) in runnable.enumerated() {
                results[item.index] = batchResults[offset]
            }
        }

        return results.map { $0 ?? ToolResult(content: "Tool error: missing result", isError: true) }
    }

    @discardableResult
    private func recordToolResult(
        _ inv: ToolCallInvocation,
        result: ToolResult,
        convo: inout Conversation,
        context: inout ToolContext,
        recentToolErrorFlags: inout [Bool],
        lastToolOutput: inout ToolOutputInfo?,
        pendingAutoVerifyPaths: inout [String],
        events: @escaping @Sendable (LoopEvent) async -> Void
    ) async -> Bool {
        let mutated = !result.mutatedPaths.isEmpty
        recentToolErrorFlags.append(result.isError)
        if recentToolErrorFlags.count > 8 { recentToolErrorFlags.removeFirst() }
        lastToolOutput = ToolOutputInfo(
            tool: inv.name,
            bytes: result.content.utf8.count)
        convo.messages.append(.init(role: .tool, content: result.content, toolCallID: inv.id))
        await events(.toolResult(invocation: inv, result: result))

        if !result.isError {
            context = Self.contextApplyingToolExtras(context, extras: result.extras)
        }

        // `tool_search` unlocks deferred tools for subsequent iterations.
        if inv.name == ToolSearchTool.name, !result.isError {
            let fromExtra = (result.extras["unlocked_deferred"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !fromExtra.isEmpty {
                var unlocked = Set(convo.unlockedDeferredTools)
                let before = unlocked.count
                for name in fromExtra { unlocked.insert(name) }
                if unlocked.count > before {
                    convo.unlockedDeferredTools = unlocked.sorted()
                    await events(.info(
                        "Unlocked deferred tools: \(fromExtra.joined(separator: ", "))"))
                }
            }
        }

        // Buffer AutoVerify paths — flush after the full tool batch so we never
        // insert role=user between tool results (OpenAI pairing).
        if !result.mutatedPaths.isEmpty && !result.isError
            && config.verifyEdits && !config.rawMode {
            pendingAutoVerifyPaths.append(contentsOf: result.mutatedPaths)
        }
        return mutated
    }

    /// Append AutoVerify reminders after all tool results for this assistant turn.
    private func flushAutoVerify(
        paths: [String],
        workingDirectory: URL,
        convo: inout Conversation
    ) {
        guard !paths.isEmpty else { return }
        for mutatedPath in paths {
            let url: URL
            if mutatedPath.hasPrefix("/") {
                url = URL(fileURLWithPath: mutatedPath)
            } else {
                url = URL(fileURLWithPath: mutatedPath, relativeTo: workingDirectory)
                    .standardizedFileURL
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            let tailContent: String
            do {
                let raw = try String(contentsOf: url, encoding: .utf8)
                let lines = raw.components(separatedBy: "\n")
                let keepLines = 20
                if lines.count <= keepLines {
                    tailContent = raw
                } else {
                    let tail = lines.suffix(keepLines).joined(separator: "\n")
                    tailContent = "… [\(lines.count - keepLines) lines above] …\n\(tail)"
                }
            } catch {
                continue
            }
            convo.messages.append(.init(
                role: .user,
                content: SystemReminder.autoVerify(
                    path: mutatedPath,
                    tail: tailContent)))
        }
    }

    // MARK: - Thinking normalize

    /// Merge dedicated reasoning channel with optional `<think>` tags in content.
    /// Returns (displayBody, reasoningContent?, thinkingDurationSeconds?).
    static func normalizeAssistantThinking(
        channelReasoning: String,
        content: String,
        thinkingDurationSeconds: Int?
    ) -> (body: String, reasoning: String?, thinkingSeconds: Int?) {
        let channel = channelReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !channel.isEmpty {
            return (content, channel, thinkingDurationSeconds)
        }
        let split = ThinkTagSplit.parse(content)
        guard let thinking = split.thinking, !thinking.isEmpty else {
            return (content, nil, nil)
        }
        // Tag-only path has no dedicated wall clock; keep provided duration
        // if any, else leave nil (UI shows "Thought" without fake seconds).
        return (split.body, thinking, thinkingDurationSeconds)
    }

    // MARK: - Policy helpers

    private static func makeTurnSnapshot(
        iteration: Int,
        maxIterations: Int,
        stallWindow: Int,
        modelWantsToFinish: Bool,
        lastAssistantContent: String,
        messages: [ChatMessage],
        turnStartIndex: Int,
        recentToolSignatures: [String],
        recentErrorFlags: [Bool],
        recentToolCalls: [ToolCallSnapshot],
        recentErrorCounts: [Int],
        lastToolOutput: ToolOutputInfo?,
        groundingForceCount: Int,
        editVerifyForceCount: Int,
        reflectionAlreadyNudged: Bool = false,
        decisionAlreadyNudged: Bool = false,
        allowReflectionNudge: Bool = true,
        toolClassification: ToolClassification
    ) -> TurnSnapshot {
        TurnSnapshot(
            iteration: iteration,
            maxIterations: maxIterations,
            modelWantsToFinish: modelWantsToFinish,
            lastAssistantContent: lastAssistantContent,
            messages: messages,
            turnStartIndex: turnStartIndex,
            recentToolSignatures: recentToolSignatures,
            recentErrorFlags: recentErrorFlags,
            recentToolCalls: recentToolCalls,
            recentErrorCounts: recentErrorCounts,
            lastToolOutput: lastToolOutput,
            groundingForceCount: groundingForceCount,
            editVerifyForceCount: editVerifyForceCount,
            reflectionAlreadyNudged: reflectionAlreadyNudged,
            decisionAlreadyNudged: decisionAlreadyNudged,
            allowReflectionNudge: allowReflectionNudge,
            mutatingToolNames: toolClassification.mutating,
            verificationToolNames: toolClassification.verification,
            readOnlyToolNames: toolClassification.readOnly,
            stallWindow: stallWindow)
    }

    private static func closeToolCalls(
        _ invocations: [ToolCallInvocation],
        reason: String,
        convo: inout Conversation,
        events: @escaping @Sendable (LoopEvent) async -> Void
    ) async {
        for inv in invocations {
            let result = ToolResult(
                content: "Skipped: \(reason)",
                isError: true)
            convo.messages.append(.init(role: .tool, content: result.content, toolCallID: inv.id))
            await events(.toolResult(invocation: inv, result: result))
        }
    }

    /// Drain `InterjectionBuffer` into the live transcript + system-reminder
    /// nudges for the next model request. Used at iteration start,
    /// mid-dispatch, and **before natural finish** so steers that arrive
    /// during a final assistant response are not discarded by end-of-turn
    /// `clear` (PC6).
    ///
    /// - Returns: number of interjections applied (0 if buffer empty).
    @discardableResult
    private static func applyInterjections(
        conversationId: UUID,
        convo: inout Conversation,
        pendingNudges: inout [String],
        events: @escaping @Sendable (LoopEvent) async -> Void
    ) async -> Int {
        let interjections = await InterjectionBuffer.shared.drain(conversationId: conversationId)
        for text in interjections {
            let msg = ChatMessage(role: .user, content: text)
            convo.messages.append(msg)
            await events(.userMessage(msg))
            pendingNudges.append(SystemReminder.interjection(text))
        }
        return interjections.count
    }

    /// Depth D4: drain `PendingWakeInject` (background job completions) into
    /// the transcript + system-reminder nudges so the **parent model** sees
    /// wakes on the next loop iteration — not only the UI status line.
    /// Survives InterjectionBuffer hard-stop `clear`.
    @discardableResult
    static func applyWakeInjects(
        conversationId: UUID,
        convo: inout Conversation,
        pendingNudges: inout [String],
        events: @escaping @Sendable (LoopEvent) async -> Void
    ) async -> Int {
        let wakes = await PendingWakeInject.shared.drain(conversationID: conversationId)
        for text in wakes {
            let wrapped = SystemReminder.interjection(text)
            // Wire-only: model still sees the wake; it must not render as a user bubble.
            let msg = ChatMessage(
                role: .user,
                content: """
                # System reminder — background job
                \(text)
                """
            )
            convo.messages.append(msg)
            await events(.userMessage(msg))
            pendingNudges.append(wrapped)
            await events(.info("Background job completed — wake injected for model"))
        }
        return wakes.count
    }

    /// Honor `request_execution_mode` / `plan_approved` extras (COORDINATION).
    /// `plan_approved=false` ignores a mode switch.
    private static func contextApplyingToolExtras(
        _ context: ToolContext,
        extras: [String: String]
    ) -> ToolContext {
        let approved = extras["plan_approved"]
        var mode = context.executionMode
        var exited = context.planModeExited
        if approved == "true" {
            exited = true
        }
        if approved != "false",
           let raw = extras["request_execution_mode"],
           let parsed = ExecutionMode(rawValue: raw) {
            mode = parsed
        }
        if mode == context.executionMode && exited == context.planModeExited {
            return context
        }
        return ToolContext(
            projectRoot: context.projectRoot,
            worktreeRoot: context.worktreeRoot,
            safeMode: context.safeMode,
            patchReviewer: context.patchReviewer,
            userQuestionReviewer: context.userQuestionReviewer,
            shellApprovalCoordinator: context.shellApprovalCoordinator,
            conversationID: context.conversationID,
            inferenceBackend: context.inferenceBackend,
            model: context.model,
            subagentDepth: context.subagentDepth,
            executionMode: mode,
            authorization: context.authorization,
            sessionReadPaths: context.sessionReadPaths,
            sessionPlanFileURL: context.sessionPlanFileURL,
            preToolHookDenials: context.preToolHookDenials,
            planModeExited: exited,
            disabledToolNames: context.disabledToolNames
        )
    }

    /// Persist FullReplace (then Semantic) after a context-overflow stream error.
    @discardableResult
    private func applyReactiveCompact(
        convo: inout Conversation,
        systemPromptTokens: Int,
        events: @escaping @Sendable (LoopEvent) async -> Void
    ) async -> Bool {
        let estimate = ChatLoop.estimateTotalTokens(
            systemPromptTokens: systemPromptTokens, messages: convo.messages)
        let budget = config.contextBudgetTokens ?? max(1, estimate / 2)
        var didShrink = false
        if config.fullReplaceCompactEnabled && !config.rawMode {
            let fr = await FullReplaceCompactor.compact(
                convo.messages,
                systemPromptTokens: systemPromptTokens,
                budgetTokens: budget)
            if fr.droppedCount > 0 {
                convo.messages = fr.messages
                didShrink = true
                await events(.contextCompacted(
                    summaryPreview: String(fr.summary.prefix(240)),
                    droppedMessages: fr.droppedCount))
            }
        }
        if !didShrink {
            let semantic = await SemanticCompactor.compact(
                convo.messages,
                systemPromptTokens: systemPromptTokens,
                budgetTokens: budget)
            if semantic.didCompact {
                convo.messages = semantic.messages
                didShrink = true
                await events(.contextCompacted(
                    summaryPreview: String((semantic.summary ?? "").prefix(240)),
                    droppedMessages: semantic.droppedCount))
            }
        }
        return didShrink
    }

    private func finishRapidRefillBlocked(
        convo: Conversation,
        memoryBackend: MemoryBackend?,
        dreamConsolidator: (any MemoryConsolidating)?,
        events: @escaping @Sendable (LoopEvent) async -> Void
    ) async -> Conversation {
        await events(.error(description: "rapid refill blocked"))
        await InterjectionBuffer.shared.clear(conversationId: convo.id)
        await Self.captureEndOfTurnMemory(
            memoryBackend, conversation: convo,
            dreamEnabled: config.dreamEnabled, consolidator: dreamConsolidator)
        await ExtensionRegistry.shared.turnEnd(conversation: convo, reason: "error")
        await events(.finished(reason: "rapid refill blocked"))
        Self.fireStopHook(reason: "rapid refill blocked", conversation: convo)
        mcpServerPool = nil
        return convo
    }

    /// PC5: fire `HookDispatcher.stop` on every exit path (natural finish,
    /// cancel, halt, SessionStart deny). Fail-open inside the dispatcher.
    private static func fireStopHook(reason: String, conversation: Conversation) {
        _ = HookDispatcher.stop(
            reason: reason,
            projectRoot: conversation.projectRoot,
            worktreeRoot: conversation.worktreeRootURL
        )
    }

    // MARK: - Canonical stop reasons (P4)

    /// Stable cap token for Stop hooks + `.finished` events.
    /// Format: `iteration cap (N)` — same on policy pre-dispatch exit and post-while exit.
    static func iterationCapStopReason(_ maxIterations: Int) -> String {
        "iteration cap (\(maxIterations))"
    }

    /// Map policy humanized strings onto canonical cancel/cap tokens when possible.
    /// Other halt reasons (stalled…, goal paused…, custom policy text) pass through.
    static func canonicalStopReason(_ reason: String, maxIterations: Int) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "cancelled" || trimmed.hasPrefix("cancelled") {
            return "cancelled"
        }
        // IterationCapPolicy: "reached the N-iteration limit for this turn"
        if trimmed.contains("iteration limit")
            || trimmed.hasPrefix("iteration cap")
            || (trimmed.contains("iteration") && trimmed.contains("limit")) {
            return iterationCapStopReason(maxIterations)
        }
        return trimmed
    }
}

public enum LoopEvent: Sendable {
    case iterationStarted(iteration: Int)
    /// Emitted once per `run(...)` call, immediately after the user's
    /// text is wrapped in a `ChatMessage` and appended to the
    /// conversation. Listeners use this to render the user's bubble
    /// the instant they hit send, rather than waiting for the loop
    /// to finish. The same `ChatMessage` instance ends up in the
    /// returned conversation, so id-based UI keying is stable.
    case userMessage(ChatMessage)
    case contentDelta(String)
    case assistantMessage(ChatMessage)
    case toolResult(invocation: ToolCallInvocation, result: ToolResult)
    case buildPassed
    case buildFailed(log: String)
    /// No build system in the working directory — not a green compile.
    case buildSkipped(reason: String)
    case stalled(repeatedSignature: String)
    case iterationCapHit(cap: Int)
    case finished(reason: String)
    /// Errors are flattened to descriptions so the event itself remains
    /// trivially Sendable under strict concurrency. The full error is
    /// also re-thrown from `AgentLoop.run`, so a caller that wants the
    /// typed error catches it there.
    case error(description: String)
    /// Emitted immediately before a tool executes — drives live activity labels.
    case toolStarted(id: String, name: String, label: String)
    /// Emitted when a tool finishes — flips UI from running to settled.
    /// `id` matches the preceding `toolStarted` / tool_call id (C2: was
    /// dropped in AgentEvent conversion when empty).
    case toolCompleted(id: String, name: String, label: String, isError: Bool)
    /// Incremental reasoning / thinking tokens from the model stream.
    case reasoningDelta(String)
    /// Emitted when `ask_user` suspends for human input.
    case pendingQuestion(AgentQuestion)
    /// Informational status message — e.g. "Premature stop detected",
    /// "Goal paused: backoff". Surfaced to the UI as a status-line
    /// update without ending or altering the turn. Lighter-weight than
    /// `.error` (which implies a fault) or `.finished` (which ends).
    case info(String)
    /// ZCode parity: a logical "step" is starting. Each iteration of
    /// the agent loop is one step — a model round-trip that may invoke
    /// tools. Emitted at the start of each iteration, alongside
    /// `iterationStarted`, so existing status-line behavior is unchanged.
    case stepStarted(iteration: Int)
    /// ZCode parity: a logical "step" has finished. Carries an optional
    /// one-line summary (e.g. "Edited files"). Emitted at the end of each
    /// iteration, before the next `stepStarted` or `finished`.
    case stepFinished(iteration: Int, summary: String?)
    /// Semantic context compaction replaced older turns with a summary.
    case contextCompacted(summaryPreview: String, droppedMessages: Int)
    /// Actual token usage reported by the model server for the request that
    /// just completed (`promptTokens` = tokens the model saw, `completionTokens`
    /// = tokens it generated). Lets the context meter calibrate to real usage
    /// instead of the chars/4 estimate. Servers that don't report usage never
    /// emit this, so the meter falls back to the estimate.
    case usage(promptTokens: Int, completionTokens: Int)
}
