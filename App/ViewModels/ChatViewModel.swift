//
//  ChatViewModel.swift
//
//  One per conversation. Glues SwiftUI to AgentLoop. Owns the streaming
//  state (the currently-growing assistant content), the in-flight Task
//  handle (for cancel), and the persistence write-back.
//

import Foundation
import SwiftUI
import AppKit
import AgentCore

@MainActor
final class ChatViewModel: ObservableObject {

    @Published var conversation: Conversation
    @Published var streamingContent: String = ""        // assistant content currently being streamed
    @Published var streamingReasoning: String = ""      // reasoning tokens currently being streamed
    @Published var reasoningStartedAt: Date? = nil
    @Published var isRunning: Bool = false

    /// Coalesce high-frequency stream deltas (~30fps) to reduce MainActor thrash.
    private var pendingContentDelta = ""
    private var pendingReasoningDelta = ""
    private var streamFlushTask: Task<Void, Never>?
    /// Quiet human-facing status. Never shows iteration/loop counters.
    @Published var statusLine: String = ""
    @Published var pendingPatch: PendingPatch?          // patch awaiting review

    /// UI state for tool calls keyed by the assistant message that triggered
    /// them. Seeded as `.pending` when an `.assistantMessage` carries
    /// invocations, flipped to `.running` on `.toolStarted`, then to
    /// `.success` / `.failure` (with output content) on `.toolResult`. Stays in memory for
    /// the lifetime of this view-model; persistence isn't required because
    /// the underlying conversation already records the tool calls + results.
    @Published var toolCallsByMessage: [UUID: [ToolCallUIState]] = [:]

    // ── Artifact rail (Claude.ai parity) ─────────────────────────────
    @Published var artifactCards: [ArtifactCard] = []
    @Published var selectedArtifactId: String? = nil
    @Published var railVisible: Bool = false
    @Published var currentActivityLabel: String? = nil

    /// Structured activity line for BuildCode-style "Verb · Status" display.
    @Published var currentActivityLine: ActivityLine? = nil

    /// HunkTracker ids successfully rolled back via post-apply Undo (session).
    @Published var rolledBackHunkIDs: Set<UUID> = []

    /// ZCode parity: step markers for the transcript. Each agent-loop
    /// iteration emits `.stepStarted` then `.stepFinished`, and we track
    /// them here so the transcript can render "Step N" markers between
    /// tool-call groups — matching ZCode's per-step display.
    @Published var stepMarkers: [StepMarker] = []

    /// ZCode parity: the current step number (increments per iteration).
    /// 0 means no step has started yet.
    @Published var currentStep: Int = 0

    /// Count of mid-turn interjections waiting for the next AgentLoop
    /// iteration drain. Set when the user sends while `isRunning`; cleared
    /// on drain (via status refresh), cancel, or `finishRun`.
    /// Status bar shows "Steering" when non-zero. (Replaces the old
    /// end-of-turn `queuedPrompt` auto-send — Grok/Claude mid-turn steer.)
    @Published var pendingInterjectionCount: Int = 0

    /// Legacy alias for UI that still checks "something is queued while busy".
    /// Maps to interjection pending count (non-nil when count > 0).
    var queuedPrompt: String? {
        pendingInterjectionCount > 0 ? "interjection" : nil
    }

    /// ZCode parity: prompt history shared across all conversations,
    /// most-recent first. Populated lazily on first access via
    /// `ensurePromptHistoryLoaded()`. The composer cycles through this
    /// with ↑/↓ arrows.
    @Published var promptHistory: [String] = []

    /// ZCode parity (/undo): snapshot of the conversation before the
    /// most recent send, so /undo can restore it. nil = no snapshot.
    @Published var preSendSnapshot: Conversation? = nil

    /// ZCode parity: goal status banner. When non-nil, a banner shows
    /// the active/paused goal with its description and status. Set from
    /// premature-stop / stall / pause info events; also driven by `/goal`.
    @Published var goalStatusText: String? = nil
    @Published var goalDescription: String? = nil

    /// Session-scoped autonomous goal (Grok Build `/goal`). Survives across
    /// turns until `/goal clear`. Wired into `AgentLoop.Configuration.goalDescription`
    /// so GoalOrchestrator can defeat premature stops / enforce progress.
    @Published var sessionGoal: String? = nil

    /// Wave C2: user or orchestrator paused the session goal — do not arm
    /// GoalOrchestrator on the next send until `/goal resume`.
    private var sessionGoalPaused: Bool = false

    /// Wave C multi-turn goal seeds — accumulate across `AgentLoop.run` so
    /// stall/maxAttempts are not reset every user message.
    private var goalSeedAttemptCount: Int = 0
    private var goalSeedLastFingerprint: String? = nil
    private var goalSeedConsecutiveStallCount: Int = 0

    /// Notes pinned via `/remember` for this session — injected into the
    /// next user messages until cleared with the conversation.
    @Published var sessionRememberNotes: [String] = []

    /// Skill envelopes queued by `/skill` for the **next** user turn only
    /// (same `<skill>` format as `load_skill`). Cleared after one send.
    private var pendingSkillEnvelopes: [String] = []

    /// Live + recent background shell / subagent jobs for this conversation.
    /// Polled from `BackgroundJobManager` while a turn runs or jobs remain.
    @Published var backgroundJobs: [BackgroundJobSnapshot] = []

    /// Ephemeral transcript cards (compaction, etc.) — not stored on the
    /// conversation wire history, but shown in-session for trust/UX.
    @Published var transcriptNotices: [TranscriptNotice] = []

    private var jobPollTask: Task<Void, Never>?

    @Published var pendingAttachments: [ContextAttachment] = []

    /// Sticky @-context pins — re-injected every send until removed.
    /// Persisted on the conversation JSON (survives reload). Cleared on new chat.
    @Published var stickyContextPins: [StickyContextPin] = [] {
        didSet {
            // Avoid write loop during init rehydrate.
            guard !isRehydratingStickyPins else { return }
            let records = stickyContextPins.map(\.asRecord)
            if conversation.stickyContextPins != records {
                conversation.stickyContextPins = records
                persistConversation()
            }
        }
    }

    /// Suppress pin→disk writes while loading pins from a conversation snapshot.
    private var isRehydratingStickyPins = false

    /// When the current turn started (used for "Working for Ns" timer).
    @Published var workStartedAt: Date? = nil

    /// Flat list of tool UI states for the **in-flight turn only**
    /// (assistant messages after the latest user prompt). Never includes
    /// tools from earlier turns — that was duplicating old list/read/edit
    /// rows under every new prompt.
    var liveTurnToolStates: [ToolCallUIState] {
        guard isRunning else { return [] }
        var ordered: [ToolCallUIState] = []
        var seen = Set<String>()
        for msgID in currentTurnAssistantMessageIDs {
            for state in toolCallsByMessage[msgID] ?? [] {
                // Scope identity by message so reused model tool-call ids
                // ("call_0") don't collapse two turns into one row.
                let key = "\(msgID.uuidString)::\(state.id)"
                if seen.insert(key).inserted {
                    ordered.append(state)
                }
            }
        }
        return ordered
    }

    /// Assistant message ids belonging to the open turn (after last user msg).
    private var currentTurnAssistantMessageIDs: [UUID] {
        guard let lastUser = conversation.messages.lastVisibleUserIndex() else {
            return conversation.messages.filter { $0.role == .assistant }.map(\.id)
        }
        return conversation.messages[lastUser...]
            .filter { $0.role == .assistant }
            .map(\.id)
    }

    /// Prefer newest assistant messages when matching a tool-call id
    /// (models often reuse `call_0` / `tool_0` across turns).
    private func assistantMessageIDsNewestFirst() -> [UUID] {
        conversation.messages.reversed().compactMap { msg in
            msg.role == .assistant ? msg.id : nil
        }
    }

    /// User-chosen reasoning effort for the active model. The capability's
    /// `clamp()` maps this to a valid level per family (e.g. GLM-5 only
    /// supports Off/High/Max, so `.medium` → `.high`), so we can store a
    /// single neutral default and let each model interpret it. The picker
    /// is hidden entirely on non-reasoning models (see `activeThinkingCapability`).
    @Published var thinkingEffort: ThinkingEffort = .medium

    static let artifactRailWidth: CGFloat = 380

    private weak var app: AppViewModel?
    private var runTask: Task<Void, Never>?
    /// User-message id that opened the in-flight turn. `finishRun` only
    /// stamps `workDurationSeconds` on assistants after this id.
    private var currentTurnUserMessageID: UUID?
    /// Set when the conversation is deleted mid-turn so the run task must
    /// not persist and resurrect it.
    private var persistSuppressed = false

    /// Whether the in-flight run is headless. Set at `send`, read in
    /// `consume` (to bypass the notification frontmost-check) and in
    /// `finishRun` (to release the shared sleep assertion exactly once).
    private var isHeadlessRun = false

    /// Set after `prepareChatRun` on each send, before `AgentLoop.run`.
    internal private(set) var lastPreparedLoopConfig: AgentLoop.Configuration?
    /// Registry-derived mutating tool names — refreshed each send for rail auto-open.
    private var knownMutatingToolNames: Set<String> = []
    /// Mirrored from `prepareChatRun` (`applyActivation`) for tests/UI.
    internal private(set) var lastPreparedModelSettings: ModelSettings?
    /// Optional hook for unit tests to observe the resolved loop config.
    internal var onLoopConfigPrepared: ((AgentLoop.Configuration) -> Void)?

    /// Live estimated tokens for the context-usage chip (ARCHITECTURE §4.2).
    var liveContextTokens: Int {
        let systemEstimate = TokenEstimator.estimate(app?.settings.systemPrompt ?? "")
        return ChatLoop.estimateTotalTokens(
            systemPromptTokens: systemEstimate,
            messages: conversation.messages)
            + TokenEstimator.estimate(streamingContent)
            + TokenEstimator.estimate(streamingReasoning)
    }

    /// Effective context window (model, optionally capped by settings).
    var liveContextWindow: Int? {
        let maxCap = app?.settings.maxContextWindowTokens ?? 0
        if let settings = lastPreparedModelSettings,
           let modelID = conversation.modelID ?? app?.selectedModelID,
           let model = app?.availableModels.first(where: { $0.id == modelID }) {
            return ContextBudget.resolveWindow(
                modelSettings: settings.loadSettings,
                workerModel: model,
                maxContextWindowTokens: maxCap)
        }
        // Before first send: use selected model advertised length if any.
        if let modelID = conversation.modelID ?? app?.selectedModelID,
           let model = app?.availableModels.first(where: { $0.id == modelID }),
           let advertised = model.contextLength, advertised > 0 {
            return ContextBudget.cappedWindow(
                modelWindow: advertised,
                maxContextWindowTokens: maxCap)
        }
        return nil
    }

    /// Active per-request budget (threshold % of window) when known.
    var liveContextBudget: Int? {
        let pct = app?.settings.autoCompactThresholdPercent ?? 70
        let maxCap = app?.settings.maxContextWindowTokens ?? 0
        if let budget = lastPreparedLoopConfig?.contextBudgetTokens { return budget }
        guard let settings = lastPreparedModelSettings,
              let modelID = conversation.modelID ?? app?.selectedModelID,
              let model = app?.availableModels.first(where: { $0.id == modelID })
        else {
            if let window = liveContextWindow {
                return ContextBudget.budgetTokens(
                    effectiveContextLength: window,
                    compactThresholdPercent: pct)
            }
            return nil
        }
        return ContextBudget.resolveForChatRun(
            modelSettings: settings.loadSettings,
            workerModel: model,
            maxContextWindowTokens: maxCap,
            compactThresholdPercent: pct)
    }

    /// Breakdown for the context inspector sheet (ZCode parity).
    var contextUsageBreakdown: ContextUsageBreakdown {
        let pct = app?.settings.autoCompactThresholdPercent ?? 70
        let window = liveContextWindow ?? liveContextBudget ?? 32_768
        let budget = liveContextBudget
            ?? ContextBudget.budgetTokens(effectiveContextLength: window, compactThresholdPercent: pct)
        return ContextUsageBreakdown.build(
            systemPrompt: app?.settings.systemPrompt ?? "",
            messages: conversation.messages,
            streamingContent: streamingContent,
            streamingReasoning: streamingReasoning,
            windowTokens: window,
            budgetTokens: budget,
            compactThresholdPercent: pct)
    }

    /// Model id used for thinking-effort UI + request encoding.
    /// Prefer the **live** picker (and two-model worker) over a stale
    /// `conversation.modelID` so the brain chip reappears as soon as the
    /// user selects a reasoning model — same source of truth as `send()`.
    var activeThinkingModelID: String? {
        if let id = app?.selectedModelID, !id.isEmpty { return id }
        if let app, app.twoModelEnabled {
            let worker = app.settings.workerModelID
            if !worker.isEmpty { return worker }
        }
        if let id = conversation.modelID, !id.isEmpty { return id }
        return nil
    }

    /// Thinking capability for the active model. nil → brain chip hidden.
    /// Uses `ThinkingModelScanner` (id pattern scan) — local servers rarely
    /// advertise reasoning in `/v1/models`.
    var activeThinkingCapability: ThinkingCapability? {
        guard let modelID = activeThinkingModelID else { return nil }
        return ThinkingModelScanner.detect(modelId: modelID)
    }

    private let injectedModelSettingsStore: ModelSettingsStore?

    /// Two-model mode: the orchestrator's brief for the in-flight turn,
    /// produced BEFORE the worker loop starts. Stashed here so the
    /// `.userMessage` event (emitted once the loop begins) can key it to
    /// the user message that triggered it, for the collapsible plan block.
    private var pendingOrchestratorBrief: String?

    init(conversation: Conversation,
         app: AppViewModel,
         modelSettingsStore: ModelSettingsStore? = nil) {
        self.conversation = conversation
        self.app = app
        self.injectedModelSettingsStore = modelSettingsStore
        self.artifactCards = ArtifactRebuild.rebuild(
            from: conversation.messages,
            toolStates: [:]
        )
        // Artifact side rail is retired (PA10): never reopen from preference.
        // Diffs render inline in Chat.
        self.railVisible = false
        self.conversation.railUserPreference = false
        self.isRehydratingStickyPins = true
        self.stickyContextPins = conversation.stickyContextPins.map(StickyContextPin.init(record:))
        self.isRehydratingStickyPins = false
    }

    /// Replace sticky pins from a conversation snapshot (e.g. after list reload).
    func rehydrateStickyPins(from convo: Conversation) {
        isRehydratingStickyPins = true
        stickyContextPins = convo.stickyContextPins.map(StickyContextPin.init(record:))
        isRehydratingStickyPins = false
    }

    /// Clear sticky pins (new chat / explicit reset).
    func clearStickyPins() {
        stickyContextPins = []
    }

    // MARK: - Persistence

    /// Write the current conversation snapshot to disk (e.g. after attaching skills).
    func persistConversation() {
        guard !persistSuppressed else { return }
        let snapshot = conversation
        Task { try? await ConversationStore.shared.save(snapshot) }
    }

    // MARK: - Plan projection (S2: PlanStore + transcript)

    /// Live plan from `PlanStore` (tools write here). Prefer over transcript-only projection.
    @Published var planStoreSnapshot: Plan? = nil

    /// Preferred display plan: PlanStore first, then transcript tool_calls projection.
    var activePlan: Plan? {
        if let planStoreSnapshot, !planStoreSnapshot.todos.isEmpty {
            return planStoreSnapshot
        }
        return CodeSessionBuilder.currentPlan(
            conversation: conversation,
            toolStates: toolCallsByMessage
        )
    }

    /// Plan mode + structured todos → show Approve / Stay chrome (S2).
    var planNeedsApproval: Bool {
        guard let app, app.executionMode == .plan else { return false }
        guard let plan = activePlan, !plan.todos.isEmpty else { return false }
        return !isRunning
    }

    var planIsLive: Bool {
        guard let plan = activePlan, !plan.todos.isEmpty else { return false }
        // Show while the turn is live, until complete, or while awaiting plan approval.
        return isRunning || !plan.isComplete || planNeedsApproval
    }

    /// Compact plan progress for the docked status bar (e.g. "2/5").
    var planProgressLabel: String? {
        guard let plan = activePlan, !plan.todos.isEmpty else { return nil }
        let done = plan.todos.filter { $0.status == .done || $0.status == .skipped }.count
        return "\(done)/\(plan.todos.count)"
    }

    /// Rehydrate PlanStore from disk/transcript and publish for the sticky checklist.
    func syncPlanFromStore() {
        let id = conversation.id
        let cwd = conversation.worktreeRootURL ?? conversation.projectRoot
        let messages = conversation.messages
        Task {
            // Split ?? so each await is a full expression (Swift rejects `await a ?? await b`).
            var plan = await PlanStore.shared.hydrateIfNeeded(
                for: id, messages: messages, workingDirectory: cwd)
            if plan == nil {
                plan = await PlanStore.shared.plan(for: id, workingDirectory: cwd)
            }
            await MainActor.run {
                // Prefer store; if only transcript has it, still keep snapshot for approve path.
                if let plan {
                    self.planStoreSnapshot = plan
                } else if let projected = CodeSessionBuilder.currentPlan(
                    conversation: self.conversation,
                    toolStates: self.toolCallsByMessage
                ) {
                    self.planStoreSnapshot = projected
                    // Seed store so Approve/toggle write a durable plan.
                    Task {
                        await PlanStore.shared.setPlan(
                            projected, for: id, workingDirectory: cwd)
                    }
                }
            }
        }
    }

    /// User toggled a checklist row while reviewing (S2).
    func togglePlanTodo(id todoID: String) {
        let convoID = conversation.id
        let cwd = conversation.worktreeRootURL ?? conversation.projectRoot
        let projected = CodeSessionBuilder.currentPlan(
            conversation: conversation, toolStates: toolCallsByMessage)
        Task {
            guard var plan = await PlanStore.shared.plan(for: convoID, workingDirectory: cwd) ?? projected
            else { return }
            guard let idx = plan.todos.firstIndex(where: { $0.id == todoID }) else { return }
            switch plan.todos[idx].status {
            case .done, .skipped:
                plan.todos[idx].status = .pending
                plan.todos[idx].result = nil
            case .pending, .inProgress, .failed:
                plan.todos[idx].status = .done
                if plan.todos[idx].result == nil {
                    plan.todos[idx].result = "Reviewed"
                }
            }
            await PlanStore.shared.setPlan(plan, for: convoID, workingDirectory: cwd)
            await MainActor.run { self.planStoreSnapshot = plan }
        }
    }

    /// Approve plan → switch to **build** (Ask) mode and continue the agent (S2).
    func approvePlanAndContinue() {
        guard let app else { return }
        guard !isRunning else {
            statusLine = "Wait for the current turn to finish before approving."
            return
        }
        guard activePlan != nil else {
            statusLine = "No plan to approve yet."
            return
        }
        let previousMode = app.executionMode
        app.executionMode = .build
        let goal = activePlan?.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let goalBit = (goal?.isEmpty == false) ? goal! : "the approved plan"
        let steps = activePlan?.todos.map { "\($0.id). \($0.text)" }.joined(separator: "\n") ?? ""
        statusLine = "Plan approved — continuing in Ask mode…"
        let prompt = """
        Plan approved. Implement it now (Ask mode — expect review sheets on file edits).

        Goal: \(goalBit)

        Steps:
        \(steps)

        Use update_todo to mark steps in_progress/done as you work. Prefer edit_file/apply_patch over re-planning unless blocked.
        """
        let started = send(prompt)
        // send() reads executionMode for this turn, so flip first — but
        // revert if send bails (no model, empty compose, hook deny).
        if !started, app.executionMode == .build {
            app.executionMode = previousMode
        }
    }

    /// Reject / stay in plan mode — no mode change, no auto-run (S2).
    func rejectPlanStayInPlan() {
        guard let app else { return }
        app.executionMode = .plan
        statusLine = "Staying in Plan mode — revise the plan or Approve when ready."
    }

    // MARK: - Prompt history + queue

    /// Lazily load the shared prompt history on first access. Called
    /// when the composer mounts so ↑/↓ arrows work immediately.
    func ensurePromptHistoryLoaded() {
        guard promptHistory.isEmpty else { return }
        Task {
            let history = await PromptHistoryStore.shared.load()
            await MainActor.run { self.promptHistory = history }
        }
    }

    /// Record a prompt to the shared store and update our in-memory copy.
    private func recordPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Update in-memory history immediately for responsive ↑/↓ cycling.
        promptHistory.removeAll { $0 == trimmed }
        promptHistory.insert(trimmed, at: 0)
        // Persist asynchronously — fire-and-forget.
        Task { await PromptHistoryStore.shared.record(trimmed) }
    }

    // MARK: - Send / cancel

    /// - Parameter forceHeadless: when true, the turn runs headless
    ///   regardless of the global toggle. Used by the scheduler so a
    ///   scheduled/overnight run is always unattended.
    /// - Returns: `true` when a turn was started or a mid-turn interjection
    ///   was accepted; `false` when send bailed early (restore composer draft).
    @discardableResult
    func send(_ text: String, forceHeadless: Bool = false) -> Bool {
        let hookRoots = lifecycleHookRoots()

        // Mid-turn interjection (Grok / Claude Code parity): if a turn is
        // already running, enqueue into InterjectionBuffer. AgentLoop drains
        // after tool batches / at iteration start — never mid-tool-pairing.
        // Do NOT start a second AgentLoop or wait until the turn finishes.
        if isRunning {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            // PB2: UserPromptSubmit gates mid-turn steers as well as new turns.
            if let blocked = ChatPromptHooks.userPromptSubmitDeniedMessage(
                text: trimmed,
                projectRoot: hookRoots.project,
                worktreeRoot: hookRoots.worktree
            ) {
                setStatus(blocked)
                return false
            }
            recordPrompt(trimmed)
            let convoId = conversation.id
            // Sample epoch *before* scheduling the Task so a post-clear bump rejects.
            // InterjectionBuffer is an actor — we still await, but pass expectedEpoch.
            Task { @MainActor in
                let epoch = await InterjectionBuffer.shared.currentEpoch(conversationId: convoId)
                // Re-check turn still live after hop (cancel may have finished).
                guard self.isRunning else {
                    self.statusLine = "Turn ended — interjection not applied."
                    return
                }
                let accepted = await InterjectionBuffer.shared.enqueue(
                    conversationId: convoId,
                    text: trimmed,
                    expectedEpoch: epoch
                )
                if !accepted {
                    self.statusLine = "Turn ended — interjection not applied."
                    return
                }
                // If turn ended after enqueue, clear again so next turn is clean.
                if !self.isRunning {
                    await InterjectionBuffer.shared.clear(conversationId: convoId)
                    self.pendingInterjectionCount = 0
                    self.statusLine = "Turn ended — interjection not applied."
                    return
                }
                let n = await InterjectionBuffer.shared.peekCount(conversationId: convoId)
                self.pendingInterjectionCount = n
                self.statusLine = n <= 1
                    ? "Interjection sent — applied on next step."
                    : "\(n) interjections pending — applied on next step."
            }
            return true
        }
        guard let app else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var textForCompose = trimmed
        // Session `/remember` notes — inject once at the top of the user turn.
        if !sessionRememberNotes.isEmpty {
            let block = sessionRememberNotes
                .map { "- \($0)" }
                .joined(separator: "\n")
            textForCompose = "[Session notes]\n\(block)\n\n\(trimmed)"
        }
        // `/skill` bodies — same envelope as load_skill, one-shot for this turn.
        if !pendingSkillEnvelopes.isEmpty {
            let skillBlock = pendingSkillEnvelopes.joined(separator: "\n\n")
            textForCompose = skillBlock + "\n\n" + textForCompose
            pendingSkillEnvelopes.removeAll()
        }
        // S1: sticky pins + one-shot attachments. Pins survive send.
        let fileAtts = StickyContextCompose.fileAttachments(
            pins: stickyContextPins,
            pending: pendingAttachments
        )
        let pinHeader = StickyContextCompose.pinHeaderText(pins: stickyContextPins)
        let textWithPins = pinHeader.isEmpty ? textForCompose : pinHeader + textForCompose
        let composed = ContextAttachmentFormatter.composeMultimodal(
            text: textWithPins,
            attachments: fileAtts
        )
        // Allow image-only turns (vision models) as well as text.
        guard !composed.isEmpty else { return false }

        // PB2: UserPromptSubmit — deny blocks the turn before isRunning flips.
        if let blocked = ChatPromptHooks.userPromptSubmitDeniedMessage(
            text: trimmed.isEmpty ? composed.text : trimmed,
            projectRoot: hookRoots.project,
            worktreeRoot: hookRoots.worktree
        ) {
            setStatus(blocked)
            return false
        }

        // One-shot only — sticky pins stay for the next turn.
        pendingAttachments = []
        recordPrompt(trimmed)
        let visionImages = composed.images
        let composedText = composed.text

        // Two-model mode. Two independent conditions:
        //   • handoff       — a GENUINE orchestrator→worker handoff runs
        //                     (toggle on, both roles set to DIFFERENT models).
        //   • executingRole — which role's model actually runs the turn
        //                     (worker if set, else orchestrator, else nil →
        //                     the classic single engine-strip model).
        // This split is what makes "worker = a model, orchestrator = None"
        // (or both the same model) run as a clean single-model turn instead
        // of pointlessly planning. When the toggle is off, executingRole is
        // nil and the classic path is byte-for-byte unchanged.
        let handoff = app.orchestrationActive
        let executingRole = app.executingRole()
        let backend = executingRole.map { app.backend(for: $0) } ?? app.currentBackend()
        // Best-effort synchronous model seed: used for auto-titling and the
        // availability check. When the executing model lives on a backend
        // that isn't the active one, the authoritative model is resolved
        // asynchronously inside the run task, so a nil seed is NOT fatal.
        let seedModel = preferredModel(backend: backend, app: app)
        guard executingRole != nil || seedModel != nil else {
            if app.availableModels.isEmpty {
                statusLine = "No models from \(app.settings.backend.shortLabel) — open Settings → Connection, confirm oMLX/Ollama is running, then pick a model."
            } else {
                statusLine = "Select a model in the picker (bottom-right) before sending. Listing models is not the same as selecting one."
            }
            return false
        }

        // ZCode /undo parity: snapshot conversation before we mutate it,
        // so /undo can restore the pre-send state.
        preSendSnapshot = conversation

        // Auto-title untitled conversations from the first prompt. Runs
        // BEFORE the agent loop kicks off so the sidebar row renames
        // instantly — no waiting for the assistant's first turn to
        // complete. Routes through `app.renameConversation` so the
        // parent's @Published `conversations` array and this VM's
        // `conversation` stay in lockstep and the rename is persisted.
        if Self.isUntitled(conversation) {
            let derived = Self.deriveTitle(from: trimmed)
            if !derived.isEmpty {
                app.renameConversation(id: conversation.id, to: derived)
            }
        }

        // Optimistic user bubble: show the prompt the instant Send is
        // pressed. Orchestrator planning + model resolve can take seconds
        // (or minutes) before AgentLoop would normally emit `.userMessage`.
        // Same UUID is passed into the loop so SwiftUI keeps one stable row.
        let optimisticUserMessageId = UUID()
        let optimisticUserMsg = ChatMessage(
            id: optimisticUserMessageId,
            role: .user,
            content: composedText,
            images: visionImages
        )
        conversation.messages.append(optimisticUserMsg)
        currentTurnUserMessageID = optimisticUserMessageId

        isRunning = true
        streamingContent = ""
        streamingReasoning = ""
        reasoningStartedAt = nil
        workStartedAt = Date()
        statusLine = "Starting…"
        currentActivityLabel = "Starting…"
        // ZCode parity: reset step markers for the new turn.
        stepMarkers = []
        currentStep = 0
        // Clear ephemeral stall/premature-stop chrome, but keep the
        // session goal banner (Grok Build `/goal` is multi-turn).
        if let goal = sessionGoal, !goal.isEmpty {
            goalDescription = goal
            goalStatusText = goalStatusText ?? "Goal active"
        } else {
            goalStatusText = nil
            goalDescription = nil
        }
        // Keep compaction notices for the session.
        startBackgroundJobPolling()
        // Clear any brief left over from a turn that was cancelled before it
        // emitted its user message — otherwise it could attach to this turn.
        pendingOrchestratorBrief = nil

        // When Safe Mode is on, install both:
        //   1. `safeMode: SafeModeConfig` — drives
        //      `ToolRegistry.checkPermission`'s path + shell allow-list
        //      enforcement. write_file / delete_file / move_file /
        //      run_shell all check this before executing.
        //   2. `patchReviewer` — drives `ApplyPatchTool`'s suspend +
        //      surface-the-sheet behaviour for unified-diff edits.
        //
        // Both come from the live AppViewModel so the user's edits in
        // PermissionsSheetView take effect on the very next turn —
        // there's no per-conversation snapshot lock.
        // Snapshot the input-card permission mode for this turn. Plan =
        // hard read-only; Ask = patch review on every write; Auto/Full =
        // free rein (Full also skips Safe Mode allow-lists).
        let mode = app.executionMode
        // Wave B S10a: Plan/Ask auto-SafeMode must seed the open project root
        // and not dual-deny SafeBash RO inspect shell (cat/rg/echo/…).
        let projectRoots: [URL] = [
            conversation.worktreeRootURL,
            conversation.projectRoot,
            app.openedProject?.url,
        ].compactMap { $0 }
        let resolvedSafeMode: SafeModeConfig? = mode.enablesSafeMode
            ? app.settings.safeModeConfig(projectRoots: projectRoots)
            : nil
        let reviewer: PatchReviewer? = mode.enablesPatchReview
            ? app.patchReviewCoordinator.makeReviewer()
            : nil

        // Compose the conversation we'll persist into (includes optimistic
        // user bubble). The agent loop receives pre-send history only so
        // SessionStart still treats a first turn as empty, and we re-append
        // the same message id inside the loop for a stable finalConvo.
        var convo = conversation
        if convo.modelID == nil, let id = seedModel?.id { convo.modelID = id }
        self.conversation = convo
        // Loop input: snapshot before optimistic insert (+ model id seed).
        var loopSeedConvo = preSendSnapshot ?? conversation
        // Drop the optimistic bubble if it leaked onto the seed (should not).
        if loopSeedConvo.messages.last?.id == optimisticUserMessageId {
            loopSeedConvo.messages.removeLast()
        }
        if loopSeedConvo.modelID == nil, let id = seedModel?.id {
            loopSeedConvo.modelID = id
        }

        let settings = app.settings
        let samplingOverride = convo.samplingOverride

        // Headless: snapshot the flag for this run, hold the Mac awake
        // while it works (released in finishRun), and tell the loop to
        // run unattended + append a morning-readable summary.
        let headless = forceHeadless || app.headlessModeOn
        let questionReviewer: UserQuestionReviewer? = headless
            ? nil
            : app.userQuestionCoordinator.makeReviewer()
        isHeadlessRun = headless
        if headless { app.beginHeadlessRun() }

        runTask = Task { [weak self] in
            guard let self else { return }

            // ── Resolve the executing model (authoritative). ───────────
            // In two-model mode the executing model lives on its role's
            // backend, which may differ from the active one — so we ask the
            // role resolver rather than trusting the active-backend seed.
            // Falls back to the seed, then errors out cleanly.
            let workerModel: ModelDescriptor
            if let role = executingRole {
                if let m = await app.resolveRoleModel(for: role) ?? seedModel {
                    workerModel = m
                } else {
                    await MainActor.run {
                        self.removeOptimisticUserMessage(id: optimisticUserMessageId)
                        self.finishRun(status: "No model available on the selected backend — open Settings and check the connection.")
                    }
                    return
                }
            } else if let m = seedModel {
                workerModel = m
            } else {
                await MainActor.run {
                    self.removeOptimisticUserMessage(id: optimisticUserMessageId)
                    self.finishRun(status: "No model available.")
                }
                return
            }

            // Record the resolved worker model on the conversation we
            // persist — covers the orchestrating-no-seed case where the
            // synchronous seed was nil and convo.modelID is still unset.
            // Use pre-send history (no optimistic bubble) so AgentLoop can
            // append the same message id cleanly.
            var runConvo = loopSeedConvo
            // Always pin the turn to the model the user actually selected
            // for this run (not a leftover conversation default).
            runConvo.modelID = workerModel.id

            // ── Orchestrator planning pass (two-model mode only). ──────
            // A read-only planning pass on the orchestrator backend
            // produces a brief that's injected into the worker's system
            // prompt. Stream tokens into the same PendingAssistantBubble
            // path as single-model thinking so visuals stay in parity.
            // The pass NEVER blocks the turn: if the orchestrator has no
            // model, errors, or produces nothing usable, the worker runs
            // solo. Skipped for headless runs.
            var orchestratorBrief: String? = nil
            if handoff && !headless {
                await MainActor.run {
                    // Same chrome as single-model: Working header +
                    // Thinking… phrases, not a blank "Orchestrator planning…"
                    // freeze with no stream.
                    self.statusLine = "Thinking…"
                    self.currentActivityLabel = "Thinking…"
                    self.streamingContent = ""
                    self.streamingReasoning = ""
                    self.reasoningStartedAt = nil
                }
                let orchBackend = app.backend(for: .orchestrator)
                let orchModel = await app.resolveRoleModel(for: .orchestrator)
                // Defense in depth: even though `handoff` already requires
                // two DIFFERENT selections, the resolver can fall back to a
                // backend's first-loaded model — so skip the planning pass if
                // the orchestrator and worker RESOLVED to the same model. A
                // model planning for itself adds nothing and, with weaker
                // models, a self-plan derails the worker into refusing tools.
                let resolvedSame = (orchModel?.id == workerModel.id)
                    && app.settings.orchestratorBackend == app.settings.workerBackend
                if let orchModel, !resolvedSame {
                    // Same thinking effort as the agent brain chip so
                    // Gemma/Qwen-style orchestrators stream reasoning
                    // into the pending bubble (single-model parity).
                    let orchThinking: ThinkingRequestConfig?
                    if let cap = ThinkingModelScanner.detect(modelId: orchModel.id) {
                        orchThinking = ThinkingRequestConfig(
                            capability: cap,
                            effort: cap.clamp(thinkingEffort))
                    } else {
                        orchThinking = nil
                    }
                    let plan = await Orchestrator.plan(
                        task: composedText,
                        backend: orchBackend,
                        model: orchModel,
                        projectRoot: convo.worktreeRootURL ?? convo.projectRoot,
                        parentConversationID: convo.id,
                        thinking: orchThinking,
                        onStream: { event in
                            await MainActor.run {
                                self.consumeOrchestratorStream(event)
                            }
                        }
                    )
                    if plan.succeeded { orchestratorBrief = plan.brief }
                }
                // Honour a cancel issued during planning before spending
                // the worker's first (expensive) iteration.
                if Task.isCancelled {
                    await MainActor.run { self.finishRun(status: "Cancelled.") }
                    return
                }
                await MainActor.run {
                    // Stash the brief so the upcoming `.userMessage` event
                    // can attach it to that message for the collapsible
                    // "Orchestrator plan" block in the transcript.
                    self.pendingOrchestratorBrief = orchestratorBrief
                    // Clear planner stream so worker thinking reuses the
                    // same bubble chrome without concatenating plan prose.
                    self.streamingContent = ""
                    self.streamingReasoning = ""
                    self.reasoningStartedAt = nil
                    self.pendingContentDelta = ""
                    self.pendingReasoningDelta = ""
                    // Same entry label as single-model turn start — not
                    // "Executing plan…" which felt like a different mode.
                    self.statusLine = "Thinking…"
                    self.currentActivityLabel = "Thinking…"
                }
            }

            let settingsStore = injectedModelSettingsStore ?? ModelSettingsStore.shared
            // Build the thinking config from the AUTHORITATIVE worker model —
            // not `conversation.modelID` (which may still be nil for a fresh
            // untitled conversation, or stale if the user just switched models).
            // `ThinkingModelScanner.detect` is a cheap string scan, so running
            // it here per-turn costs nothing and always matches the model that
            // actually executes. The user's chosen effort is clamped to the
            // resolved capability so a model swap mid-conversation can never
            // send an effort the new family doesn't support.
            let thinkingConfig: ThinkingRequestConfig?
            if let cap = ThinkingModelScanner.detect(modelId: workerModel.id) {
                thinkingConfig = ThinkingRequestConfig(
                    capability: cap,
                    effort: cap.clamp(thinkingEffort))
            } else {
                thinkingConfig = nil
            }
            // Heal Xcode MCP before tool schemas are built for this turn.
            // Without this, a dead bridge leaves xcodeMCPLive false and the
            // model never sees BuildProject / Xcode* tools.
            if settings.xcodeMCPEnabled {
                _ = await XcodeMCPBridge.shared.ensureConnected()
                let status = await XcodeMCPBridge.shared.connectionStatus()
                await MainActor.run { app.xcodeMCPStatus = status }
            }
            let xcodeLive = await MainActor.run { app.xcodeMCPLive }
            let shellApprover: ShellApprovalCoordinator? = headless
                ? nil
                : await MainActor.run { app.shellApprovalCoordinatorService.makeCoordinator() }
            var (loopConfig, sampling, modelSettings) = await AgentRunBootstrap.prepareChatRun(
                workerModel: workerModel,
                settings: settings,
                store: settingsStore,
                xcodeMCPLive: xcodeLive,
                headless: headless,
                safeMode: resolvedSafeMode,
                patchReviewer: reviewer,
                userQuestionReviewer: questionReviewer,
                shellApprovalCoordinator: shellApprover,
                orchestratorBrief: orchestratorBrief,
                thinking: thinkingConfig,
                samplingOverride: samplingOverride,
                executionMode: mode)
            // Grok Build `/goal` — activate GoalOrchestrator when a session goal is set
            // and not paused (Wave C2: /goal pause must stick across sends).
            let (goalText, goalPaused, seedAttempts, seedFP, seedStall) = await MainActor.run {
                (self.sessionGoal, self.sessionGoalPaused, self.goalSeedAttemptCount,
                 self.goalSeedLastFingerprint, self.goalSeedConsecutiveStallCount)
            }
            if !goalPaused,
               let g = goalText?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
                loopConfig.goalDescription = g
                loopConfig.goalSeedAttemptCount = seedAttempts
                loopConfig.goalSeedLastFingerprint = seedFP
                loopConfig.goalSeedConsecutiveStallCount = seedStall
            }
            let toolClassification = await ToolClassification.load(
                registry: ToolRegistry.shared,
                xcodeMCPEnabled: xcodeLive)
            await MainActor.run {
                self.lastPreparedLoopConfig = loopConfig
                self.lastPreparedModelSettings = modelSettings
                self.knownMutatingToolNames = toolClassification.mutating
                self.onLoopConfigPrepared?(loopConfig)
                app.applyPreparedModelSettings(modelSettings)
            }

            let definition = AgentDefinition(
                backend: backend,
                model: workerModel,
                loopConfig: loopConfig,
                sampling: sampling
            )
            let session = AgentSession(definition: definition)

            await MainActor.run {
                // Same pending-bubble language as single-model agent mode
                // (avoid "Contacting / Connecting" only in two-model path).
                self.statusLine = "Thinking…"
                self.currentActivityLabel = "Thinking…"
            }

            do {
                // On cancellation the loop returns GRACEFULLY with the
                // partial turn (open tool calls closed with synthetic
                // results), so this path persists cancelled turns too.
                let finalConvo = try await session.execute(
                    userMessage: composedText,
                    conversation: runConvo,
                    images: visionImages,
                    userMessageId: optimisticUserMessageId
                ) { event in
                    await MainActor.run { self.consume(event: event) }
                }
                // Merge on MainActor — `self.conversation` is isolated
                // there. Preserve any conversation-level state the user
                // toggled while the turn was in flight (worktree mode,
                // project rebinds): `finalConvo` is the loop's view of
                // the conversation at the moment it started and doesn't
                // know about subsequent UI mutations. We then save the
                // merged value (not raw `finalConvo`) so disk + memory
                // agree.
                let persisted: Conversation? = await MainActor.run {
                    var merged = finalConvo
                    merged.worktreeBranch = self.conversation.worktreeBranch
                    merged.projectRoot = self.conversation.projectRoot
                    // The loop's finalConvo doesn't carry the orchestrator
                    // briefs (they're UI-side state set during the run) —
                    // preserve them so the plan block survives persistence.
                    merged.orchestratorBriefs = self.conversation.orchestratorBriefs
                    // SessionStart deny / early exit can return history without
                    // the user turn — keep the optimistic bubble if so.
                    if !merged.messages.contains(where: { $0.id == optimisticUserMessageId }),
                       let opt = self.conversation.messages.first(where: {
                           $0.id == optimisticUserMessageId && $0.role == .user
                       }) {
                        merged.messages.append(opt)
                    }
                    self.conversation = merged
                    self.streamingContent = ""
                    // Wave C2: attempt seed is updated from goal-progress info
                    // events during the run; do not blindly +1 here (that
                    // double-counted with evaluateTurnEnd).
                    self.finishRun(status: Task.isCancelled ? "Cancelled." : "Done.")
                    return self.persistSuppressed ? nil : merged
                }
                if let persisted {
                    try? await ConversationStore.shared.save(persisted)
                    await app.refreshConversations()
                }
            } catch {
                // Real failure (backend unreachable, stream error). The
                // user's message and any partial progress were mirrored
                // into self.conversation by the event stream — persist
                // them so the turn isn't lost. Cancellation can also land
                // here if the backend tears the stream down mid-stop.
                let partial: Conversation? = await MainActor.run {
                    let cancelled = Task.isCancelled
                        || error is CancellationError
                        || (error as? BackendError).map { if case .cancelled = $0 { return true }; return false } ?? false
                    self.finishRun(status: cancelled
                                   ? "Cancelled."
                                   : "Error: \(error.localizedDescription)")
                    return self.persistSuppressed ? nil : self.conversation
                }
                if let partial {
                    try? await ConversationStore.shared.save(partial)
                }
            }
        }
        return true
    }

    /// Drop an optimistic user bubble when the turn never reaches the loop
    /// (e.g. model missing). Leaves history intact if the message is gone.
    private func removeOptimisticUserMessage(id: UUID) {
        if let idx = conversation.messages.lastIndex(where: { $0.id == id && $0.role == .user }) {
            conversation.messages.remove(at: idx)
        }
    }

    /// Cancel the in-flight turn and skip the end-of-run save so deleting
    /// this conversation cannot resurrect it from disk.
    func cancelForDeletion() {
        persistSuppressed = true
        cancel()
    }

    /// Request cooperative cancellation. State is NOT flipped here — the
    /// loop unwinds (closing open tool calls), returns the partial
    /// conversation, and the run task's completion path persists it and
    /// calls `finishRun`. Until then the Stop button shows "Cancelling…".
    func cancel() {
        guard isRunning else { return }
        statusLine = "Cancelling…"
        // Grok: cancel discards buffered interjections so they do not apply
        // to a later turn after the user stopped this one.
        let convoId = conversation.id
        pendingInterjectionCount = 0
        Task { await InterjectionBuffer.shared.clear(conversationId: convoId) }
        // Fail-closed any open approval sheets so the turn can unwind.
        app?.shellApprovalCoordinatorService.denyPendingAndDrain()
        app?.patchReviewCoordinator.resolve(.rejectAll)
        runTask?.cancel()
    }

    /// Common end-of-run state cleanup (success, cancel, and error).
    private func finishRun(status: String) {
        let wasCancelled = status.localizedCaseInsensitiveContains("cancel")

        // PB2: Stop lifecycle hook (fire-and-forget; first-class HookDispatcher.stop).
        let roots = lifecycleHookRoots()
        ChatPromptHooks.fireStop(
            reason: wasCancelled ? "cancelled" : "completed",
            detail: status,
            projectRoot: roots.project,
            worktreeRoot: roots.worktree
        )

        // Stamp "Worked for Ns" on THIS turn's final assistant only —
        // never rewrite a previous turn when this one produced no reply.
        if let started = workStartedAt {
            let secs = max(1, Int(Date().timeIntervalSince(started).rounded()))
            let afterUser: Int
            if let userID = currentTurnUserMessageID,
               let userIdx = conversation.messages.firstIndex(where: { $0.id == userID }) {
                afterUser = userIdx
            } else {
                afterUser = conversation.messages.count
            }
            if let idx = conversation.messages.lastIndex(where: { $0.role == .assistant }),
               idx > afterUser {
                conversation.messages[idx].workDurationSeconds = secs
            }
        }
        currentTurnUserMessageID = nil

        // Drop undelivered interjections so they never poison the *next* turn
        // (drain only runs at iteration start — late follow-ups after the last
        // model call would otherwise stick in the buffer).
        let convoId = conversation.id
        pendingInterjectionCount = 0
        Task { await InterjectionBuffer.shared.clear(conversationId: convoId) }

        // Drop completed background job records; leave running jobs for the
        // user to wait/kill. Full cleanup on conversation delete / app quit.
        isRunning = false
        runTask = nil
        flushStreamBuffersNow()
        statusLine = wasCancelled ? "Task ended by user" : status
        streamingContent = ""
        streamingReasoning = ""
        pendingContentDelta = ""
        pendingReasoningDelta = ""
        reasoningStartedAt = nil
        workStartedAt = nil
        currentActivityLabel = nil

        // Inline marker under the assistant turn (session-local, not wire history).
        if wasCancelled {
            // Avoid stacking duplicates if cancel is reported more than once.
            let already = transcriptNotices.contains {
                $0.kind == .userStopped && Date().timeIntervalSince($0.createdAt) < 2
            }
            if !already {
                transcriptNotices.append(
                    TranscriptNotice(
                        id: UUID(),
                        kind: .userStopped,
                        title: "Task ended by user",
                        detail: "You stopped generation. Send a follow-up to continue.",
                        createdAt: Date()
                    )
                )
            }
        }
        // Clear transient "still working" premature-stop banner when the
        // turn actually ends (keep true "Goal paused" state).
        if let g = goalStatusText?.lowercased(),
           g.contains("still working") || g.contains("premature") {
            goalStatusText = nil
        }
        Task { @MainActor in
            await BackgroundJobManager.shared.removeFinished()
            await refreshBackgroundJobs()
            if backgroundJobs.contains(where: { $0.status == .running }) {
                startBackgroundJobPolling()
            } else {
                stopBackgroundJobPolling()
            }
        }
        // Release the shared sleep assertion this run acquired. Guarded by
        // isHeadlessRun so non-headless runs never touch the refcount.
        if isHeadlessRun {
            app?.endHeadlessRun()
            isHeadlessRun = false
        }
        // Any card still "running" belongs to a turn that ended without
        // its tool result (cancelled mid-dispatch) — flip it so the UI
        // doesn't show a perpetual spinner.
        for (msgID, states) in toolCallsByMessage {
            let updated = states.map { state in
                state.status == .running || state.status == .pending
                    ? ToolCallUIState(id: state.id, toolName: state.toolName,
                                      status: .failure, input: state.input,
                                      output: state.output.isEmpty ? "Cancelled" : state.output)
                    : state
            }
            toolCallsByMessage[msgID] = updated
        }

        // Interjections are drained mid-turn by AgentLoop; nothing left to
        // auto-fire after finish. Clear the pending badge.
        pendingInterjectionCount = 0
    }

    // MARK: - Event consumption

    /// Sanitize any agent-loop machinery out of status chrome.
    private func setStatus(_ line: String) {
        statusLine = Self.humanStatus(line)
    }

    /// Maps internal loop messages → quiet human labels. Never surfaces
    /// "Iteration N" / step counters in the chat UI.
    ///
    /// P3: also normalizes UserPromptSubmit deny + background-job wake
    /// strings so the status bar stays scannable (no raw task UUIDs).
    static func humanStatus(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("iteration ") || lower.hasPrefix("iter ") {
            return "Working…"
        }
        if lower.contains("iteration cap") || lower.contains("hit iteration") {
            return "Stopped — turn limit reached"
        }
        if lower.hasPrefix("tool:") {
            // "tool: read_file ✓" → "Read · done"
            let rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: " ")
            let name = parts.first.map(String.init) ?? rest
            let verb = humanToolVerb(name)
            let ok = !rest.contains("✗")
            return ok ? "\(verb) · done" : "\(verb) · failed"
        }
        // Hook deny (ChatPromptHooks + legacy "Blocked by hook" forms).
        if lower.hasPrefix("prompt blocked") {
            return trimmed
        }
        if lower.hasPrefix("blocked by hook:") {
            let reason = trimmed.dropFirst("Blocked by hook:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? "Prompt blocked by project hook." : "Prompt blocked: \(reason)"
        }
        if lower.hasPrefix("blocked by userpromptsubmit") {
            return "Prompt blocked by project hook."
        }
        // PC4 background completion wakes — drop task_id=UUID noise.
        if lower.hasPrefix("background ") {
            return humanBackgroundWake(trimmed)
        }
        // PC8 / subagent tool-strip diagnostics (if surfaced as info).
        if lower.hasPrefix("stripped tools") {
            return "Subagent tools limited — \(trimmed)"
        }
        return trimmed
    }

    /// Shorten BackgroundJobCompletionNotice.wakeMessage for the status bar.
    static func humanBackgroundWake(_ line: String) -> String {
        var s = line
        // Strip " (task_id=<uuid>)" (and any trailing fragment after it).
        if let range = s.range(of: " (task_id=", options: .caseInsensitive) {
            s = String(s[..<range.lowerBound])
        }
        if s.hasPrefix("Background subagent ") {
            s = "Subagent " + s.dropFirst("Background subagent ".count)
        } else if s.hasPrefix("Background job ") {
            s = "Job " + s.dropFirst("Background job ".count)
        }
        if s.count > 140 {
            return String(s.prefix(137)) + "…"
        }
        return s
    }

    /// True when status is ephemeral loop chrome (safe to replace with Working…).
    static func isTransientStatus(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return true }
        if s.hasPrefix("Iteration") || s.hasPrefix("iter ") { return true }
        return s == "Starting…" || s == "Working…" || s == "Thinking…"
            || s == "Orchestrator planning…" || s == "Executing plan…"
    }

    private static func humanToolVerb(_ toolName: String) -> String {
        switch toolName {
        case "read_file", "read_file_range": return "Read"
        case "write_file", "edit_file", "apply_patch", "search_replace": return "Edit"
        case "list_directory": return "Explore"
        case "run_shell", "run_shell_command": return "Bash"
        case "grep_code", "glob_files", "code_search": return "Search"
        case "web_search", "fetch_url": return "Fetch"
        default:
            // title-case first segment of snake_case
            let first = toolName.split(separator: "_").first.map(String.init) ?? toolName
            return first.prefix(1).uppercased() + first.dropFirst()
        }
    }

    private func consume(event: LoopEvent) {
        switch event {
        case .iterationStarted:
            // Quiet status — never "Iteration N…".
            // P3: do not clobber sticky statuses (hook deny, job wake, etc.).
            if Self.isTransientStatus(statusLine) {
                setStatus("Thinking…")
            }
            currentActivityLabel = "Thinking…"
            // Each iteration starts a fresh assistant message; clear the
            // streaming buffer so we don't concatenate across turns.
            streamingContent = ""
            streamingReasoning = ""
            reasoningStartedAt = nil
        case .userMessage(let msg):
            // Mirror the user's bubble into our local conversation the
            // instant the loop has wrapped it. Same ChatMessage id ends
            // up in `finalConvo` at the end, so SwiftUI's id-keyed
            // ForEach keeps the bubble stable across the replacement.
            // Also covers mid-turn interjections drained by AgentLoop.
            // De-dupe: send() may already have inserted an optimistic
            // bubble with this id (before orchestrator planning).
            if let idx = conversation.messages.firstIndex(where: { $0.id == msg.id }) {
                conversation.messages[idx] = msg
            } else {
                conversation.messages.append(msg)
            }
            // Refresh interjection badge after a drain (buffer peek is 0
            // once applied); ignore for the turn's first user message.
            if isRunning && pendingInterjectionCount > 0 {
                let convoId = conversation.id
                Task { @MainActor in
                    let n = await InterjectionBuffer.shared.peekCount(conversationId: convoId)
                    self.pendingInterjectionCount = n
                    if n == 0 {
                        self.statusLine = "Interjection applied."
                    }
                }
            }
            // Attach the orchestrator's brief (if this turn had one) to the
            // user message it answered, so the transcript can render the
            // collapsible "Orchestrator plan" block under this prompt.
            if let brief = pendingOrchestratorBrief, !brief.isEmpty {
                conversation.orchestratorBriefs[msg.id.uuidString] = brief
                pendingOrchestratorBrief = nil
            }
        case .reasoningDelta(let s):
            if reasoningStartedAt == nil { reasoningStartedAt = Date() }
            pendingReasoningDelta += s
            scheduleStreamFlush()
        case .contentDelta(let s):
            pendingContentDelta += s
            scheduleStreamFlush()
        case .assistantMessage(let msg):
            flushStreamBuffersNow()
            conversation.messages.append(msg)
            streamingContent = ""
            streamingReasoning = ""
            reasoningStartedAt = nil
            // Seed pending cards for every tool invocation this assistant
            // turn carries. `.toolStarted` flips to running; `.toolResult`
            // flips to success/failure below.
            if !msg.toolCalls.isEmpty {
                toolCallsByMessage[msg.id] = msg.toolCalls.map { inv in
                    ToolCallUIState(
                        id: inv.id,
                        toolName: inv.name,
                        status: .pending,
                        input: inv.arguments,
                        output: ""
                    )
                }
                maybeAutoOpenRail(toolNames: msg.toolCalls.map(\.name))
                syncArtifacts(messageID: msg.id, createdAt: msg.timestamp)
                refreshActivityLabel()
            }
        case .toolStarted(let id, _, let label):
            currentActivityLabel = label
            // Newest-first: avoid updating an older turn that reused the same tool id.
            for msgID in assistantMessageIDsNewestFirst() {
                guard var states = toolCallsByMessage[msgID],
                      let idx = states.firstIndex(where: { $0.id == id }),
                      states[idx].status == .pending
                else { continue }
                states[idx] = ToolCallUIState(
                    id: states[idx].id,
                    toolName: states[idx].toolName,
                    status: .running,
                    input: states[idx].input,
                    output: states[idx].output
                )
                toolCallsByMessage[msgID] = states
                refreshActivityLabel()
                break
            }
        case .toolCompleted:
            refreshActivityLabel()
        case .toolResult(let inv, let result):
            conversation.messages.append(.init(role: .tool, content: result.content, toolCallID: inv.id))
            setStatus("tool: \(inv.name) \(result.isError ? "✗" : "✓")")
            // Newest-first match so a reused tool-call id updates this turn only.
            for msgID in assistantMessageIDsNewestFirst() {
                guard var states = toolCallsByMessage[msgID],
                      let idx = states.firstIndex(where: { $0.id == inv.id })
                else { continue }
                states[idx] = ToolCallUIState(
                    id: inv.id,
                    toolName: inv.name,
                    status: result.isError ? .failure : .success,
                    input: states[idx].input,
                    output: result.content
                )
                toolCallsByMessage[msgID] = states
                if let msg = conversation.messages.first(where: { $0.id == msgID }) {
                    syncArtifacts(messageID: msgID, createdAt: msg.timestamp)
                }
                refreshActivityLabel()
                break
            }
            // S2: keep sticky checklist in sync with PlanStore after plan tools.
            if ["create_plan", "update_todo", "revise_plan"].contains(inv.name) {
                syncPlanFromStore()
            }
        case .buildPassed:
            setStatus("Build · verified")
            appendBuildVerifyNotice(succeeded: true, detail: nil)
        case .buildFailed(let log):
            // AgentLoop injects the BuildGuard system reminder for the model;
            // surface a transcript notice so the user sees the result too.
            setStatus("Build · failed")
            appendBuildVerifyNotice(succeeded: false, detail: log)
        case .buildSkipped(let reason):
            setStatus("Build · skipped")
            appendBuildVerifyNotice(skipped: true, detail: reason)
        case .stalled(let sig):
            handleStalled(signature: sig)
        case .iterationCapHit(let cap):
            setStatus("Hit iteration cap (\(cap))")
            notifyTerminal(.budgetExceeded(iterations: cap))
        case .finished(let reason):
            setStatus("Finished")
            // The loop emits .finished(reason: "cancelled") on user cancel —
            // no "task complete" ping in that case (the user is right here).
            if reason != "cancelled" {
                notifyTerminal(.completed(taskSummary: ChatLoop.summariseCompletion(messages: conversation.messages)))
            }
        case .error(let desc):
            statusLine = "Error: \(desc)"
            notifyTerminal(.streamFailed)
        case .pendingQuestion:
            statusLine = "Waiting for your answer…"
            currentActivityLabel = "Waiting for your answer…"

        case .info(let msg):
            handleInfoStatus(msg)

        case .stepStarted(let i):
            // ZCode parity: mark a new step. The summary is filled in
            // when .stepFinished arrives.
            currentStep = i
            stepMarkers.append(StepMarker(iteration: i, summary: nil))

        case .stepFinished(let iteration, let summary):
            // ZCode parity: close out the step with its summary.
            if let idx = stepMarkers.lastIndex(where: { $0.iteration == iteration }) {
                stepMarkers[idx].summary = summary
            }

        case .contextCompacted(let preview, let dropped):
            handleContextCompacted(preview: preview, dropped: dropped)
        }
    }

    // MARK: - Stream coalesce (~30 fps)

    /// Pipe orchestrator SubAgentRunner stream into the same pending-bubble
    /// buffers as the main worker loop (thinking phrases, reasoning block,
    /// streaming answer). Keeps two-model planning visually in parity with
    /// single-model agent mode.
    private func consumeOrchestratorStream(_ event: SubAgentRunner.StreamEvent) {
        switch event {
        case .iterationStarted:
            // Fresh model call within planning — same reset as worker
            // `.iterationStarted` so multi-iter plans don't concatenate.
            if Self.isTransientStatus(statusLine) {
                setStatus("Thinking…")
            }
            currentActivityLabel = "Thinking…"
            streamingContent = ""
            streamingReasoning = ""
            reasoningStartedAt = nil
            pendingContentDelta = ""
            pendingReasoningDelta = ""
        case .reasoningDelta(let s):
            guard !s.isEmpty else { return }
            if reasoningStartedAt == nil { reasoningStartedAt = Date() }
            pendingReasoningDelta += s
            scheduleStreamFlush()
            if Self.isTransientStatus(statusLine) || statusLine == "Thinking…" {
                setStatus("Thinking…")
            }
            currentActivityLabel = "Thinking…"
        case .contentDelta(let s):
            guard !s.isEmpty else { return }
            pendingContentDelta += s
            scheduleStreamFlush()
            // Once plan prose streams, mirror single-model "writing" feel.
            if Self.isTransientStatus(statusLine) || statusLine == "Thinking…" {
                setStatus("Working…")
            }
            currentActivityLabel = "Working…"
        }
    }

    private func scheduleStreamFlush() {
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 33_000_000)
            self.flushStreamBuffersNow()
        }
    }

    private func flushStreamBuffersNow() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        if !pendingContentDelta.isEmpty {
            streamingContent += pendingContentDelta
            pendingContentDelta = ""
            if !streamingContent.isEmpty {
                refreshActivityLabel()
            }
        }
        if !pendingReasoningDelta.isEmpty {
            if reasoningStartedAt == nil { reasoningStartedAt = Date() }
            streamingReasoning += pendingReasoningDelta
            pendingReasoningDelta = ""
            currentActivityLabel = "Thinking…"
        }
    }

    // MARK: - AgentEvent consumer (granular event stream — Phase 2)

    /// Consume a granular `AgentEvent` from the new event stream. Mirrors
    /// `consume(event: LoopEvent)` but handles fine-grained events so the
    /// UI can render each sub-step independently. The implementation is
    /// functionally equivalent — only the event granularity differs.
    func consume(event: AgentEvent) {
        switch event {
        case .turnStarted:
            // Prefer Thinking… over a cold "Starting…" when the pending
            // bubble is already alive (optimistic send / post-orchestrator
            // handoff) so two-model doesn't flash different chrome than
            // single-model idle thinking.
            if streamingContent.isEmpty && streamingReasoning.isEmpty {
                statusLine = "Thinking…"
                currentActivityLabel = "Thinking…"
            }

        case .iterationStarted:
            // Do not surface "Iteration N…" in the chat window.
            // P3: sticky hook deny / job wake survive iteration chrome.
            if Self.isTransientStatus(statusLine) {
                setStatus("Thinking…")
            }
            if currentActivityLabel == nil
                || currentActivityLabel == "Starting…"
                || currentActivityLabel == "Working…"
                || currentActivityLabel == "Connecting to backend…" {
                currentActivityLabel = "Thinking…"
            }
            streamingContent = ""
            streamingReasoning = ""
            reasoningStartedAt = nil

        case .stepStarted(let i):
            // Track steps internally for tooling; do not push iteration UI.
            currentStep = i
            // Intentionally not appending stepMarkers — they clutter the
            // transcript ("Step 1") without adding useful signal.

        case .userMessage(let msg):
            // Live path (AgentSession → AgentEvent). Must de-dupe by id:
            // send() already inserts an optimistic bubble with this id before
            // orchestrator planning / loop start. Blind append collides
            // SwiftUI ForEach identity and can persist duplicates on error.
            // Mid-turn interjections use fresh UUIDs and still append.
            if let idx = conversation.messages.firstIndex(where: { $0.id == msg.id }) {
                conversation.messages[idx] = msg
            } else {
                conversation.messages.append(msg)
            }
            if isRunning && pendingInterjectionCount > 0 {
                let convoId = conversation.id
                Task { @MainActor in
                    let n = await InterjectionBuffer.shared.peekCount(conversationId: convoId)
                    self.pendingInterjectionCount = n
                    if n == 0 {
                        self.statusLine = "Interjection applied."
                    }
                }
            }
            if let brief = pendingOrchestratorBrief, !brief.isEmpty {
                conversation.orchestratorBriefs[msg.id.uuidString] = brief
                pendingOrchestratorBrief = nil
            }

        case .textDelta(let s):
            pendingContentDelta += s
            scheduleStreamFlush()

        case .thinkingDelta(let s):
            if reasoningStartedAt == nil { reasoningStartedAt = Date() }
            pendingReasoningDelta += s
            scheduleStreamFlush()

        case .assistantMessage(let msg):
            flushStreamBuffersNow()
            conversation.messages.append(msg)
            streamingContent = ""
            streamingReasoning = ""
            reasoningStartedAt = nil
            if !msg.toolCalls.isEmpty {
                toolCallsByMessage[msg.id] = msg.toolCalls.map { inv in
                    ToolCallUIState(
                        id: inv.id,
                        toolName: inv.name,
                        status: .pending,
                        input: inv.arguments,
                        output: ""
                    )
                }
                maybeAutoOpenRail(toolNames: msg.toolCalls.map(\.name))
                syncArtifacts(messageID: msg.id, createdAt: msg.timestamp)
                refreshActivityLabel()
            }

        case .toolStarted(let id, _, let label):
            currentActivityLabel = label
            for msgID in assistantMessageIDsNewestFirst() {
                guard var states = toolCallsByMessage[msgID],
                      let idx = states.firstIndex(where: { $0.id == id }),
                      states[idx].status == .pending
                else { continue }
                states[idx] = ToolCallUIState(
                    id: states[idx].id,
                    toolName: states[idx].toolName,
                    status: .running,
                    input: states[idx].input,
                    output: states[idx].output
                )
                toolCallsByMessage[msgID] = states
                refreshActivityLabel()
                break
            }

        case .toolUpdated(let id, let outputSnippet):
            for msgID in assistantMessageIDsNewestFirst() {
                guard var states = toolCallsByMessage[msgID],
                      let idx = states.firstIndex(where: { $0.id == id })
                else { continue }
                states[idx] = ToolCallUIState(
                    id: states[idx].id,
                    toolName: states[idx].toolName,
                    status: .running,
                    input: states[idx].input,
                    output: states[idx].output + outputSnippet
                )
                toolCallsByMessage[msgID] = states
                if let msg = conversation.messages.first(where: { $0.id == msgID }) {
                    syncArtifacts(messageID: msgID, createdAt: msg.timestamp)
                }
                break
            }

        case .toolFinished(let id, let name, let label, let isError):
            currentActivityLabel = label
            for msgID in assistantMessageIDsNewestFirst() {
                guard var states = toolCallsByMessage[msgID],
                      let idx = states.firstIndex(where: { $0.id == id })
                else { continue }
                states[idx] = ToolCallUIState(
                    id: states[idx].id,
                    toolName: name,
                    status: isError ? .failure : .success,
                    input: states[idx].input,
                    output: states[idx].output
                )
                toolCallsByMessage[msgID] = states
                refreshActivityLabel()
                break
            }

        case .toolResult(let inv, let result):
            conversation.messages.append(.init(role: .tool, content: result.content, toolCallID: inv.id))
            setStatus("tool: \(inv.name) \(result.isError ? "✗" : "✓")")
            if ["create_plan", "update_todo", "revise_plan"].contains(inv.name) {
                syncPlanFromStore()
            }
            for msgID in assistantMessageIDsNewestFirst() {
                guard var states = toolCallsByMessage[msgID],
                      let idx = states.firstIndex(where: { $0.id == inv.id })
                else { continue }
                states[idx] = ToolCallUIState(
                    id: inv.id,
                    toolName: inv.name,
                    status: result.isError ? .failure : .success,
                    input: states[idx].input,
                    output: result.content
                )
                toolCallsByMessage[msgID] = states
                if let msg = conversation.messages.first(where: { $0.id == msgID }) {
                    syncArtifacts(messageID: msgID, createdAt: msg.timestamp)
                }
                refreshActivityLabel()
                break
            }

        case .buildPassed:
            setStatus("Build · verified")
            appendBuildVerifyNotice(succeeded: true, detail: nil)

        case .buildFailed(let log):
            setStatus("Build · failed")
            appendBuildVerifyNotice(succeeded: false, detail: log)

        case .buildSkipped(let reason):
            setStatus("Build · skipped")
            appendBuildVerifyNotice(skipped: true, detail: reason)

        case .stalled(let sig):
            handleStalled(signature: sig)

        case .iterationCapHit(let cap):
            setStatus("Hit iteration cap (\(cap))")
            notifyTerminal(.budgetExceeded(iterations: cap))

        case .stepFinished(let iteration, let summary):
            // ZCode parity: close out the step with its summary.
            if let idx = stepMarkers.lastIndex(where: { $0.iteration == iteration }) {
                stepMarkers[idx].summary = summary
            }

        case .finished(let reason):
            setStatus("Finished")
            if reason != "cancelled" {
                notifyTerminal(.completed(taskSummary: ChatLoop.summariseCompletion(messages: conversation.messages)))
            }

        case .error(let desc):
            statusLine = "Error: \(desc)"
            notifyTerminal(.streamFailed)

        case .pendingQuestion:
            statusLine = "Waiting for your answer…"
            currentActivityLabel = "Waiting for your answer…"

        case .info(let msg):
            handleInfoStatus(msg)

        case .contextCompacted(let preview, let dropped):
            handleContextCompacted(preview: preview, dropped: dropped)

        case .hunkRecorded:
            break

        case .backgroundJobCompleted(_, _, _, let summary, let conversationID):
            // PC4: parent-visible wake when bg shell/subagent finishes.
            if let conversationID, conversationID != conversation.id { break }
            handleInfoStatus(summary)
            Task { await refreshBackgroundJobs() }
            startBackgroundJobPolling()

        case .toolAllowlistStripped(_, let summary, _, _):
            // P8: custom agent / subagent tool strip → status line.
            handleInfoStatus(summary)
        }
    }

    // MARK: - Goal / compaction / background jobs (surface harness power)

    private func handleInfoStatus(_ msg: String) {
        // P3: run through humanStatus (wake/hook formatting).
        setStatus(msg)
        let lower = statusLine.lowercased()
        // Wave C2: machine-readable multi-turn goal seed from AgentLoop.
        // Format: "goal-progress attempts=N stall=M fp=... status=..."
        if msg.hasPrefix("goal-progress ") {
            applyGoalProgressLine(msg)
            return
        }
        if lower.contains("premature stop") {
            // Model tried to bail; loop is injecting a continuation nudge.
            goalStatusText = "Still working on goal — model tried to stop early"
            if goalDescription == nil || goalDescription?.isEmpty == true {
                goalDescription = activePlan?.goal ?? sessionGoal
            }
        } else if lower.contains("goal paused") {
            goalStatusText = msg
            // Orchestrator stall/backoff pause must stick like /goal pause.
            sessionGoalPaused = true
            if let g = sessionGoal ?? activePlan?.goal, !g.isEmpty {
                goalDescription = g
            }
        } else if lower.contains("stall") || lower.contains("no progress") {
            goalStatusText = msg
            if goalDescription == nil {
                goalDescription = activePlan?.goal ?? sessionGoal
            }
        }
    }

    /// Parse `goal-progress attempts=N stall=M fp=... status=...` into seeds.
    private func applyGoalProgressLine(_ msg: String) {
        var attempts: Int?
        var stall: Int?
        var fp: String?
        var status: String?
        for token in msg.split(separator: " ").dropFirst() {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "attempts": attempts = Int(parts[1])
            case "stall": stall = Int(parts[1])
            case "fp": fp = parts[1]
            case "status": status = parts[1]
            default: break
            }
        }
        if let attempts {
            goalSeedAttemptCount = max(0, min(attempts, 50))
        }
        if let stall {
            goalSeedConsecutiveStallCount = max(0, stall)
        }
        if let fp, !fp.isEmpty {
            goalSeedLastFingerprint = fp
        } else if fp != nil {
            goalSeedLastFingerprint = nil
        }
        if let status {
            switch status {
            case "complete":
                // Goal achieved — clear sticky pause and leave seeds for diagnostics.
                sessionGoalPaused = false
                goalStatusText = "Goal complete"
            case "noProgressPaused", "backOffPaused", "userPaused", "blocked":
                sessionGoalPaused = true
                goalStatusText = "Goal paused (\(status))"
            case "active":
                if !sessionGoalPaused {
                    goalStatusText = "Goal active"
                }
            default:
                break
            }
        }
    }

    private func handleStalled(signature: String) {
        setStatus("Paused — repeating the same action")
        goalStatusText = "Goal stalled — no progress"
        let sigPreview = String(signature.prefix(72))
        if let g = activePlan?.goal, !g.isEmpty {
            goalDescription = g
        } else {
            goalDescription = "Repeated tool pattern: \(sigPreview)"
        }
        notifyTerminal(.looped(signature: signature))
    }

    private func handleContextCompacted(
        preview: String,
        dropped: Int,
        source: CompactEventCopy.Source = .autoWire
    ) {
        let copy = CompactEventCopy.make(
            summaryPreview: preview,
            droppedMessages: dropped,
            source: source
        )
        currentActivityLabel = copy.title
        statusLine = copy.statusLine
        transcriptNotices.append(
            TranscriptNotice(
                id: UUID(),
                kind: .compaction,
                title: copy.title,
                detail: copy.detail,
                createdAt: Date()
            )
        )
    }

    func dismissTranscriptNotice(_ id: UUID) {
        transcriptNotices.removeAll { $0.id == id }
    }

    func killBackgroundJob(_ id: UUID) {
        Task { @MainActor in
            _ = await BackgroundJobManager.shared.kill(id)
            await refreshBackgroundJobs()
        }
    }

    /// Result of post-apply Undo via `HunkTracker.reject`.
    enum UndoFileEditResult: Equatable {
        case undid(Int)
        case fileChanged
        case alreadyUndone
        case notFound
        case failed(String)
    }

    /// Roll disk back for tracked hunks from a successful edit tool card.
    /// Fail-closed when the file no longer matches applied content.
    @discardableResult
    func undoFileEdits(hunkIDs: [UUID], shortPath: String? = nil) async -> UndoFileEditResult {
        let pending = hunkIDs.filter { !rolledBackHunkIDs.contains($0) }
        guard !pending.isEmpty else {
            statusLine = "Already undone."
            return .alreadyUndone
        }

        var restored = 0
        var drifted = 0
        var missing = 0
        var lastError: String?

        for id in pending {
            do {
                let outcome = try await HunkTracker.shared.rejectDetailed(id: id)
                switch outcome {
                case .rolledBack, .alreadyRolledBack:
                    rolledBackHunkIDs.insert(id)
                    restored += 1
                case .fileChanged:
                    drifted += 1
                case .notFound:
                    missing += 1
                }
            } catch {
                lastError = error.localizedDescription
            }
        }

        let label = shortPath.map { " \($0)" } ?? ""
        if restored > 0, drifted == 0, missing == 0, lastError == nil {
            statusLine = "Undid edit\(restored == 1 ? "" : "s")\(label)."
            return .undid(restored)
        }
        if drifted > 0, restored == 0 {
            statusLine = "File changed since apply — undo skipped\(label)."
            return .fileChanged
        }
        if let lastError, restored == 0 {
            statusLine = "Undo failed\(label): \(lastError)"
            return .failed(lastError)
        }
        if missing > 0, restored == 0 {
            statusLine = "Nothing to undo\(label) (edit not tracked)."
            return .notFound
        }
        statusLine = "Undid \(restored) file\(restored == 1 ? "" : "s")\(label)"
            + (drifted > 0 ? "; \(drifted) skipped (file changed)." : ".")
        return .undid(restored)
    }

    /// Whether all hunks for an edit card have already been rolled back.
    func isEditUndone(hunkIDs: [UUID]) -> Bool {
        !hunkIDs.isEmpty && hunkIDs.allSatisfy { rolledBackHunkIDs.contains($0) }
    }

    func startBackgroundJobPolling() {
        jobPollTask?.cancel()
        jobPollTask = Task { [weak self] in
            // PC4: also drain pending completion wakes (in case no event stream).
            await self?.drainBackgroundJobCompletions()
            while !Task.isCancelled {
                await self?.refreshBackgroundJobs()
                await self?.drainBackgroundJobCompletions()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Apply PC4 auto-wake notices for this conversation (status line + job list).
    @MainActor
    func drainBackgroundJobCompletions() async {
        let notices = await BackgroundJobManager.shared.takePendingCompletions(
            conversationID: conversation.id)
        for notice in notices {
            handleInfoStatus(notice.wakeMessage)
            // Optional: if host is mid-turn with an AgentEvent consumer, also
            // no-op here — consume(event:) handles .backgroundJobCompleted.
        }
        if !notices.isEmpty {
            await refreshBackgroundJobs()
        }
        // P8: tool allowlist strip notices from SubAgentRunner / TaskTool.
        await drainToolStripNotices()
    }

    @MainActor
    func drainToolStripNotices() async {
        let strips = await AgentToolAllowlist.StripSurface.shared.takePending()
        for notice in strips {
            handleInfoStatus(notice.statusMessage)
        }
    }

    func stopBackgroundJobPolling() {
        jobPollTask?.cancel()
        jobPollTask = nil
    }

    @MainActor
    func refreshBackgroundJobs() async {
        let convoID = conversation.id
        let scoped = await BackgroundJobManager.shared.list(conversationID: convoID)
        // Include any running jobs that lack a conversation id (legacy
        // callers) so the banner still surfaces shell/subagent work.
        let running = await BackgroundJobManager.shared.listRunning()
        var byID: [UUID: BackgroundJobSnapshot] = [:]
        for j in scoped { byID[j.id] = j }
        for j in running where j.conversationID == nil || j.conversationID == convoID {
            byID[j.id] = j
        }
        backgroundJobs = byID.values.sorted { $0.startedAt > $1.startedAt }
    }

    /// Post a completion/halt notification when permitted (S6).
    /// - Headless / scheduled: always try (even if app is frontmost).
    /// - Interactive: notify only if the app is **not** frontmost (user
    ///   switched away); NotificationService requests auth on first post.
    private func notifyTerminal(_ kind: NotificationService.Kind) {
        let headless = isHeadlessRun
        let masterOn = app?.settings.notificationsEnabled ?? true
        NotificationService.shared.notify(
            kind,
            enabled: masterOn,
            bypassFrontmostCheck: headless
        )
    }

    // MARK: - Tool-call UI lookup

    /// Returns the live UI states for the tool calls a given assistant
    /// message kicked off. Empty when the message has no calls or the
    /// states haven't been seeded yet.
    func toolCalls(forMessageID id: UUID) -> [ToolCallUIState] {
        toolCallsByMessage[id] ?? []
    }

    /// Full file bodies known from successful edit tools **before** `messageID`
    /// (exclusive). Used so a later `write_file` rewrite shows red − lines.
    /// Pass `nil` to include the entire conversation so far.
    func fileContents(beforeMessageID messageID: UUID?) -> [String: String] {
        var map: [String: String] = [:]
        for msg in conversation.messages {
            if let messageID, msg.id == messageID { break }
            ingestEditTools(of: msg.id, into: &map)
        }
        return map
    }

    /// Content known **before the current user turn** (tools after the last
    /// user message are excluded). Use this for the live/pending bubble so
    /// `liveToolStates` are not double-applied (duplicate create cards).
    func fileContentsBeforeCurrentTurn() -> [String: String] {
        var map: [String: String] = [:]
        guard let lastUser = conversation.messages.lastVisibleUserIndex() else {
            return map
        }
        for msg in conversation.messages.prefix(lastUser) {
            ingestEditTools(of: msg.id, into: &map)
        }
        return map
    }

    private func ingestEditTools(of messageID: UUID, into map: inout [String: String]) {
        let states = toolCallsByMessage[messageID] ?? []
        for state in states where CodeSessionBuilder.isEditTool(state.toolName) {
            guard let rawPath = CodeSessionBuilder.path(from: state) else { continue }
            let key = CodeSessionBuilder.normalizePath(rawPath)
            let previous = CodeSessionBuilder.lookupContent(map, path: rawPath)
            if let after = CodeSessionBuilder.contentAfterEdit(previous: previous, state: state) {
                map[key] = after
            } else if let written = CodeSessionBuilder.writtenContent(from: state) {
                map[key] = written
            }
        }
    }

    // MARK: - Artifact rail

    func rebuildArtifactsFromHistory() {
        artifactCards = ArtifactRebuild.rebuild(
            from: conversation.messages,
            toolStates: toolCallsByMessage
        )
    }

    func focusArtifact(_ id: String) {
        // Keep selection for any residual callers; do not open the side rail.
        selectedArtifactId = id
    }

    func toggleRail() {
        // Rail disabled — no-op (kept so command palette / old call sites compile).
        railVisible = false
        conversation.railUserPreference = false
    }

    // MARK: - Slash commands

    /// Attempt to handle a text string as a slash command. Returns the
    /// result so the caller knows whether to clear the input field or send
    /// it as a normal message. Mirrors Grok Build session/model/mode commands.
    func handleSlashCommand(_ text: String) -> SlashCommandResult {
        guard let parsed = SlashCommandService.parse(text) else {
            return .notACommand
        }
        // Unknown built-in name → let it go as a normal message only if it
        // isn't in our catalog (skills may share names later). Known names
        // always handle even with empty args.
        if SlashCommandService.command(named: parsed.command) == nil {
            return .notACommand
        }

        switch parsed.command.lowercased() {
        case "/new":
            NotificationCenter.default.post(name: .newConversationRequested, object: nil)
            return .handled(message: "Started a new conversation.")

        case "/clear":
            clearConversationMessages()
            return .handled(message: "Cleared all messages.")

        case "/home", "/welcome":
            clearConversationMessages()
            NotificationCenter.default.post(name: .newConversationRequested, object: nil)
            return .handled(message: "Returned home.")

        case "/compact":
            return handleCompact(preserve: parsed.args)

        case "/context":
            return .handled(message: formatContextUsage())

        case "/session-info":
            return .handled(message: formatSessionInfo())

        case "/fork":
            guard let app else {
                return .handled(message: "Cannot fork — app not ready.")
            }
            app.duplicateConversation(conversation.id)
            return .handled(message: "Forked conversation (history preserved).")

        case "/rewind":
            return handleRewind()

        case "/undo":
            return handleUndo()

        case "/restore-checkpoint", "/restore":
            return handleRestoreCheckpoint()

        case "/copy":
            return handleCopy(nth: parsed.args)

        case "/export":
            NotificationCenter.default.post(name: .exportConversationRequested, object: conversation.id)
            return .handled(message: "Opening export…")

        case "/rename", "/title":
            let title = parsed.args.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return .handled(message: "Usage: /rename <new title>")
            }
            if let app {
                app.renameConversation(id: conversation.id, to: title)
            } else {
                conversation.title = title
                Task { try? await ConversationStore.shared.save(conversation) }
            }
            return .handled(message: "Renamed to \"\(title)\".")

        case "/quit", "/exit":
            NSApp.terminate(nil)
            return .handled(message: "Quitting…")

        case "/model", "/m":
            return handleModelCommand(args: parsed.args)

        case "/effort":
            return handleEffortCommand(args: parsed.args)

        case "/plan":
            return handlePlanCommand(args: parsed.args)

        case "/view-plan", "/show-plan", "/plan-view":
            return handleViewPlan()

        case "/approve-plan", "/approve":
            approvePlanAndContinue()
            return .handled(message: "Approving plan — switching to Ask mode and continuing…")

        case "/stay-plan", "/reject-plan":
            rejectPlanStayInPlan()
            return .handled(message: "Staying in Plan mode.")

        case "/always-approve":
            return handleAlwaysApproveToggle()

        case "/auto":
            return handleAutoToggle()

        case "/goal":
            return handleGoalCommand(args: parsed.args)

        case "/remember":
            return handleRemember(args: parsed.args)

        case "/skill", "/skills":
            return handleSkillCommand(args: parsed.args)

        case "/loop":
            return handleLoopCommand(args: parsed.args)

        case "/settings", "/config", "/preferences", "/prefs":
            NotificationCenter.default.post(name: .settingsRequested, object: nil)
            return .handled(message: "Opening Settings…")

        case "/mcps":
            NotificationCenter.default.post(name: .settingsRequested, object: "mcp")
            return .handled(message: "Opening MCP settings…")

        case "/history":
            ensurePromptHistoryLoaded()
            if promptHistory.isEmpty {
                return .handled(message: "No prompt history yet. Use ↑ on an empty composer after sending.")
            }
            let preview = promptHistory.prefix(8).enumerated()
                .map { "  \($0.offset + 1). \(String($0.element.prefix(80)))" }
                .joined(separator: "\n")
            return .handled(message: "Recent prompts (↑/↓ in empty composer to cycle):\n\(preview)")

        case "/help", "/?":
            let help = SlashCommandService.helpText(filter: parsed.args)
            statusLine = "Slash command help"
            return .handled(message: help)

        case "/commit", "/git-commit":
            return handleCommitCommand(args: parsed.args)

        case "/pr", "/pull-request", "/pull_request":
            return handlePRCommand(args: parsed.args)

        default:
            return .notACommand
        }
    }

    // MARK: Slash command handlers


    /// `/commit <message>` — stage all + commit in project/worktree.
    private func handleCommitCommand(args: String) -> SlashCommandResult {
        let message = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return .handled(message: "Usage: /commit <message>")
        }
        guard let cwd = conversation.worktreeRootURL ?? conversation.projectRoot else {
            return .handled(message: "No project open — open a folder before /commit.")
        }
        let result = GitWorkflow.commit(
            message: message,
            workingDirectory: cwd,
            stageAll: true)
        statusLine = result.success ? "Committed" : "Commit failed"
        return .handled(message: result.display)
    }

    /// `/pr <title> [| body…]` — create PR via `gh` when available.
    private func handlePRCommand(args: String) -> SlashCommandResult {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return .handled(message: "Usage: /pr <title> [| optional body]")
        }
        guard let cwd = conversation.worktreeRootURL ?? conversation.projectRoot else {
            return .handled(message: "No project open — open a folder before /pr.")
        }
        let title: String
        let body: String?
        if let pipe = raw.range(of: " | ") {
            title = String(raw[..<pipe.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            body = String(raw[pipe.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = raw
            body = nil
        }
        let result = GitWorkflow.createPullRequest(
            title: title,
            body: body,
            workingDirectory: cwd)
        statusLine = result.success ? "PR created" : "PR failed"
        return .handled(message: result.display)
    }

    private func clearConversationMessages() {
        conversation.messages.removeAll()
        artifactCards.removeAll()
        toolCallsByMessage.removeAll()
        transcriptNotices.removeAll()
        goalStatusText = nil
        goalDescription = nil
        sessionGoal = nil
        sessionRememberNotes.removeAll()
        pendingSkillEnvelopes.removeAll()
        streamingContent = ""
        streamingReasoning = ""
        reasoningStartedAt = nil
        currentActivityLabel = nil
        statusLine = "Conversation cleared."
        planStoreSnapshot = nil
        let convoID = conversation.id
        Task {
            await PlanStore.shared.clear(for: convoID)
            try? await ConversationStore.shared.save(self.conversation)
        }
    }

    /// `/skill [name] [args…]` — list skills, or queue a skill body for the next
    /// user message (human path; does not require the model to call `load_skill`).
    private func handleSkillCommand(args: String) -> SlashCommandResult {
        let outcome = SlashCommandService.evaluateSkillCommand(
            args: args,
            projectRoot: conversation.projectRoot,
            worktreeRoot: conversation.worktreeRootURL
        )
        switch outcome {
        case .list(let catalog):
            statusLine = "Skills"
            return .handled(message: catalog)
        case .loaded(_, let envelope, let statusMessage):
            pendingSkillEnvelopes.append(envelope)
            // Cap so a mistaken paste loop cannot bloat the next turn.
            if pendingSkillEnvelopes.count > 5 {
                pendingSkillEnvelopes = Array(pendingSkillEnvelopes.suffix(5))
            }
            statusLine = statusMessage
            return .handled(message: statusMessage)
        case .failed(let message):
            statusLine = message
            return .handled(message: message)
        }
    }

    private func handleCompact(preserve: String) -> SlashCommandResult {
        // Always clear live streaming chrome first.
        streamingContent = ""
        streamingReasoning = ""
        reasoningStartedAt = nil
        currentActivityLabel = nil

        let messages = conversation.messages
        guard messages.count > 4 else {
            statusLine = "Not enough history to compact."
            return .handled(message: "Nothing to compact yet (need more turns).")
        }

        let systemEstimate = TokenEstimator.estimate(app?.settings.systemPrompt ?? "")
        // Force compaction by using a tight budget relative to current size,
        // while always keeping a recent tail. Optional preserve string is
        // passed as summarizer systemHint (not a synthetic tail message that
        // can be stripped or kept as noise).
        let preserveHint = preserve.trimmingCharacters(in: .whitespacesAndNewlines)
        var systemHint = SemanticCompactor.defaultSystemHint
        if !preserveHint.isEmpty {
            systemHint += "\nUser asked to preserve: \(preserveHint)"
        }
        let total = ChatLoop.estimateTotalTokens(
            systemPromptTokens: systemEstimate, messages: messages)
        // Budget just below current total so SemanticCompactor always runs
        // when there's a compressible prefix (manual /compact is intentional).
        let budget = max(512, total - 1)

        statusLine = "Compacting history…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await SemanticCompactor.compact(
                messages,
                systemPromptTokens: systemEstimate,
                budgetTokens: budget,
                keepRecent: 6,
                systemHint: systemHint,
                summarizer: ExtractiveHistorySummarizer())
            let compacted = result.messages
            if result.didCompact {
                // Snapshot pre-compact transcript so /undo restores it
                // (manual compact rewrites persisted history — Wave C2).
                self.preSendSnapshot = self.conversation
                self.conversation.messages = compacted
                self.rebuildArtifactsFromHistory()
                self.handleContextCompacted(
                    preview: result.summary ?? preserveHint,
                    dropped: result.droppedCount,
                    source: .manualRewrite)
                // Keep slash feedback explicit for /undo.
                self.statusLine =
                    "Compacted — dropped \(result.droppedCount) older messages. /undo to restore."
                try? await ConversationStore.shared.save(self.conversation)
            } else {
                // Still clear buffers; history already small or cut failed.
                self.statusLine = "History already compact (buffers cleared)."
            }
        }
        return .handled(message: preserveHint.isEmpty
            ? "Compacting conversation history (rewrites transcript; /undo restores)…"
            : "Compacting (preserving: \(preserveHint.prefix(60)); /undo restores)…")
    }

    private func handleUndo() -> SlashCommandResult {
        guard preSendSnapshot != nil else {
            return .handled(message: "Nothing to undo.")
        }
        let convoID = conversation.id
        let snapshot = preSendSnapshot!
        // PA4: restore filesystem checkpoint then chat (async actor hop).
        Task { @MainActor [weak self] in
            guard let self else { return }
            let files = await CheckpointStore.shared.restoreLatest(conversationID: convoID)
            self.conversation.messages = snapshot.messages
            self.conversation.modelID = snapshot.modelID
            self.toolCallsByMessage.removeAll()
            self.artifactCards.removeAll()
            self.preSendSnapshot = nil
            let filePart = files.restoredFileCount > 0 || files.turnID != nil
                ? files.statusSummary
                : "conversation only (no file checkpoint)"
            self.statusLine = "Undid last send — \(filePart)."
            try? await ConversationStore.shared.save(self.conversation)
        }
        return .handled(message: "Undoing last send (files + conversation)…")
    }

    private func handleRewind() -> SlashCommandResult {
        // Prefer pre-send snapshot when available (same as /undo, code-aware).
        if preSendSnapshot != nil {
            return handleUndo()
        }
        // Otherwise restore latest file checkpoint and drop last user turn.
        guard let lastUser = conversation.messages.lastVisibleUserIndex() else {
            return .handled(message: "Nothing to rewind.")
        }
        let removed = conversation.messages.count - lastUser
        let convoID = conversation.id
        let kept = Array(conversation.messages.prefix(lastUser))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let files = await CheckpointStore.shared.restoreLatest(conversationID: convoID)
            self.conversation.messages = kept
            self.toolCallsByMessage.removeAll()
            self.rebuildArtifactsFromHistory()
            self.streamingContent = ""
            self.streamingReasoning = ""
            let filePart = files.restoredFileCount > 0 || files.turnID != nil
                ? files.statusSummary
                : "conversation only (no file checkpoint)"
            self.statusLine =
                "Rewound last turn (\(removed) messages) — \(filePart)."
            try? await ConversationStore.shared.save(self.conversation)
        }
        return .handled(message: "Rewinding last turn (files + conversation)…")
    }

    /// Code-only restore (no transcript change).
    private func handleRestoreCheckpoint() -> SlashCommandResult {
        let convoID = conversation.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            let files = await CheckpointStore.shared.restoreLatest(conversationID: convoID)
            self.statusLine = "Checkpoint: \(files.statusSummary)."
        }
        return .handled(message: "Restoring files from latest checkpoint…")
    }

    private func handleCopy(nth: String) -> SlashCommandResult {
        let n: Int
        if nth.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            n = 1
        } else if let parsed = Int(nth.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 {
            n = parsed
        } else {
            return .handled(message: "Usage: /copy [n]  — n = 1 for latest reply")
        }
        let assistants = conversation.messages
            .filter { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !assistants.isEmpty else {
            // Fall back to live streaming buffer.
            let stream = streamingContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stream.isEmpty {
                copyToPasteboard(stream)
                return .handled(message: "Copied streaming reply.")
            }
            return .handled(message: "No assistant reply to copy.")
        }
        let indexFromEnd = n - 1
        guard indexFromEnd < assistants.count else {
            return .handled(message: "Only \(assistants.count) assistant replies available.")
        }
        let msg = assistants[assistants.count - 1 - indexFromEnd]
        copyToPasteboard(msg.content)
        return .handled(message: n == 1 ? "Copied latest reply." : "Copied reply #\(n) from the end.")
    }

    private func copyToPasteboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    private func handleModelCommand(args: String) -> SlashCommandResult {
        let query = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let app else {
            NotificationCenter.default.post(name: .commandPaletteRequested, object: nil)
            return .handled(message: nil)
        }
        if query.isEmpty {
            NotificationCenter.default.post(name: .modelPickerRequested, object: nil)
            return .handled(message: "Opening model picker…")
        }
        // Match by id or display name (case-insensitive, substring).
        let q = query.lowercased()
        let models = app.availableModels
        let match = models.first { $0.id.lowercased() == q }
            ?? models.first { $0.displayName.lowercased() == q }
            ?? models.first { $0.id.lowercased().contains(q) }
            ?? models.first { $0.displayName.lowercased().contains(q) }
        guard let model = match else {
            NotificationCenter.default.post(name: .modelPickerRequested, object: nil)
            return .handled(message: "No model matching \"\(query)\". Opened picker.")
        }
        app.selectedModelID = model.id
        conversation.modelID = model.id
        // Re-clamp effort so the brain chip levels match the new family.
        if let cap = ThinkingModelScanner.detect(modelId: model.id) {
            thinkingEffort = cap.clamp(thinkingEffort)
        }
        Task {
            await app.activateModel(id: model.id)
            try? await ConversationStore.shared.save(conversation)
        }
        return .handled(message: "Switched to \(model.displayName).")
    }

    private func handleEffortCommand(args: String) -> SlashCommandResult {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else {
            let current = thinkingEffort.rawValue
            let cap = activeThinkingCapability
            let levels = (cap?.levels ?? ThinkingEffort.allCases).map(\.rawValue).joined(separator: ", ")
            return .handled(message: "Current effort: \(current). Levels: \(levels). Usage: /effort <level>")
        }
        // Accept Grok aliases: xhigh → max
        let normalized = (raw == "xhigh" || raw == "x-high") ? "max" : raw
        guard let effort = ThinkingEffort(rawValue: normalized) else {
            return .handled(message: "Unknown effort \"\(args)\". Use: off, low, medium, high, max")
        }
        if let cap = activeThinkingCapability {
            let clamped = cap.clamp(effort)
            thinkingEffort = clamped
            if clamped != effort {
                return .handled(message: "Set \(cap.label) to \(clamped.title) (clamped from \(effort.title)).")
            }
            return .handled(message: "Set \(cap.label) to \(clamped.title).")
        }
        thinkingEffort = effort
        return .handled(message: "Set effort to \(effort.title) (model may not advertise thinking).")
    }

    private func handlePlanCommand(args: String) -> SlashCommandResult {
        guard let app else { return .handled(message: "App not ready.") }
        app.executionMode = .plan
        let note = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            // Wave C: arm sessionGoal so GoalOrchestrator survives send()
            // (which only restores chrome from sessionGoal, not goalDescription).
            sessionGoal = note
            goalDescription = note
            goalStatusText = "Plan mode — describe intent before edits"
            goalSeedAttemptCount = 0
            goalSeedLastFingerprint = nil
            goalSeedConsecutiveStallCount = 0
        }
        return .handled(message: note.isEmpty
            ? "Plan mode on — inspect only. When the checklist appears, Approve & Run (or /approve-plan) to implement in Ask mode."
            : "Plan mode on. Focus: \(note)\nSend a message to plan. Approve & Run when the checklist is ready.")
    }

    private func handleViewPlan() -> SlashCommandResult {
        if let plan = activePlan {
            let done = plan.todos.filter { $0.status == .done || $0.status == .skipped }.count
            let total = plan.todos.count
            let goal = plan.goal.isEmpty ? "(no goal text)" : plan.goal
            let lines = plan.todos.prefix(12).map { t in
                let mark: String
                switch t.status {
                case .done, .skipped: mark = "✓"
                case .inProgress: mark = "…"
                case .failed: mark = "✗"
                case .pending: mark = "○"
                }
                return "  \(mark) \(t.text)"
            }.joined(separator: "\n")
            return .handled(message: "Plan (\(done)/\(total) done)\nGoal: \(goal)\n\(lines)")
        }
        if let g = sessionGoal, !g.isEmpty {
            return .handled(message: "Session goal: \(g)\n(No structured plan todos yet.)")
        }
        return .handled(message: "No active plan. Enter Plan mode with /plan, or set /goal.")
    }

    private func handleAlwaysApproveToggle() -> SlashCommandResult {
        guard let app else { return .handled(message: "App not ready.") }
        if app.executionMode == .yolo {
            app.executionMode = .build
            return .handled(message: "Full access off → Ask before changes.")
        }
        app.executionMode = .yolo
        return .handled(message: "Full access on — fewer confirmations.")
    }

    private func handleAutoToggle() -> SlashCommandResult {
        guard let app else { return .handled(message: "App not ready.") }
        if app.executionMode == .edit {
            app.executionMode = .build
            return .handled(message: "Auto edit off → Ask before changes.")
        }
        app.executionMode = .edit
        return .handled(message: "Auto edit on — workspace edits without per-file review.")
    }

    private func handleGoalCommand(args: String) -> SlashCommandResult {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()

        if raw.isEmpty || lower == "status" {
            if let g = sessionGoal, !g.isEmpty {
                let status: String
                if sessionGoalPaused {
                    status = goalStatusText ?? "paused"
                } else {
                    status = goalStatusText ?? (isRunning ? "running" : "idle")
                }
                return .handled(message: "Goal: \(g)\nStatus: \(status)"
                    + (sessionGoalPaused ? "\n(Use /goal resume to re-arm GoalOrchestrator.)" : ""))
            }
            if let planGoal = activePlan?.goal, !planGoal.isEmpty {
                return .handled(message: "Plan goal: \(planGoal)\n(No session /goal set.)")
            }
            return .handled(message: "No active goal. Usage: /goal <objective>")
        }

        if lower == "pause" {
            guard sessionGoal != nil else {
                return .handled(message: "No active goal to pause.")
            }
            // Wave C2: sticky pause — next send must not re-arm GoalOrchestrator.
            sessionGoalPaused = true
            goalStatusText = "Goal paused"
            if isRunning {
                statusLine = "Pausing goal…"
                runTask?.cancel()
                return .handled(message: "Goal paused — run cancelled. Use /goal resume to continue.")
            }
            return .handled(message: "Goal marked paused. Use /goal resume to continue.")
        }

        if lower == "resume" {
            guard let g = sessionGoal, !g.isEmpty else {
                return .handled(message: "No goal to resume. Set one with /goal <objective>.")
            }
            sessionGoalPaused = false
            goalStatusText = "Goal active"
            goalDescription = g
            return .handled(message: "Goal resumed: \(g)\nSend a message (or “continue”) to keep working.")
        }

        if lower == "clear" {
            sessionGoal = nil
            goalStatusText = nil
            goalDescription = nil
            sessionGoalPaused = false
            goalSeedAttemptCount = 0
            goalSeedLastFingerprint = nil
            goalSeedConsecutiveStallCount = 0
            return .handled(message: "Goal cleared.")
        }

        // Treat remaining args as the objective.
        sessionGoal = raw
        goalDescription = raw
        goalStatusText = "Goal active"
        sessionGoalPaused = false
        goalSeedAttemptCount = 0
        goalSeedLastFingerprint = nil
        goalSeedConsecutiveStallCount = 0
        return .handled(message: "Goal set: \(raw)\nSend a message to start working toward it.")
    }

    private func handleRemember(args: String) -> SlashCommandResult {
        let note = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else {
            if sessionRememberNotes.isEmpty {
                return .handled(message: "Usage: /remember <note>")
            }
            let list = sessionRememberNotes.enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            return .handled(message: "Session notes:\n\(list)")
        }
        sessionRememberNotes.append(note)
        // Cap so we don't bloat every turn.
        if sessionRememberNotes.count > 20 {
            sessionRememberNotes = Array(sessionRememberNotes.suffix(20))
        }
        return .handled(message: "Remembered for this session: \(note)")
    }

    private func handleLoopCommand(args: String) -> SlashCommandResult {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            NotificationCenter.default.post(name: .scheduledTasksRequested, object: nil)
            return .handled(message: "Usage: /loop [interval] <prompt>  — e.g. /loop 1h check deploy status")
        }

        // Parse optional leading interval token: 30m, 1h, 2d, every hour, etc.
        let (interval, prompt) = Self.parseLoopArgs(raw)
        guard !prompt.isEmpty else {
            return .handled(message: "Usage: /loop [interval] <prompt>")
        }

        let frequency: TaskFrequency
        let timeOfDay: Int?
        switch interval {
        case .hourly: frequency = .hourly; timeOfDay = nil
        case .daily: frequency = .daily; timeOfDay = nil
        case .weekly: frequency = .weekly; timeOfDay = nil
        case .manual, .none: frequency = .manual; timeOfDay = nil
        }

        let name = String(prompt.prefix(48))
        let task = ScheduledTask(
            name: name,
            shortPrompt: prompt,
            longPrompt: prompt,
            projectFolder: conversation.projectRoot?.path,
            frequency: frequency,
            timeOfDayMinutes: timeOfDay,
            setupComplete: true
        )
        Task {
            let vm = ScheduledTasksViewModel()
            await vm.add(task)
        }
        let freqLabel = frequency.label
        return .handled(message: "Scheduled \"\(name)\" (\(freqLabel)). Manage in Scheduled tasks.")
    }

    private enum LoopIntervalKind { case none, manual, hourly, daily, weekly }

    /// True for `30m` / `1h` / `2d` — a non-empty digit run then the unit.
    /// Bare `h`/`m`/`d` must not parse (`"".allSatisfy` is vacuously true).
    private static func isNumericDuration(_ token: String, unit: Character) -> Bool {
        guard token.count >= 2, token.last == unit else { return false }
        let digits = token.dropLast()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    private static func parseLoopArgs(_ raw: String) -> (LoopIntervalKind, String) {
        let lower = raw.lowercased()
        // "every hour" / "every day" at end
        if lower.hasSuffix(" every hour") {
            return (.hourly, String(raw.dropLast(" every hour".count)).trimmingCharacters(in: .whitespaces))
        }
        if lower.hasSuffix(" every day") || lower.hasSuffix(" every 1 day") {
            let drop = lower.hasSuffix(" every 1 day") ? " every 1 day".count : " every day".count
            return (.daily, String(raw.dropLast(drop)).trimmingCharacters(in: .whitespaces))
        }

        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return (.none, raw) }
        let token = String(first).lowercased()
        let rest = parts.count > 1 ? String(parts[1]) : ""

        let interval: LoopIntervalKind?
        if token == "hourly" || isNumericDuration(token, unit: "h") {
            interval = .hourly
        } else if token == "daily" || isNumericDuration(token, unit: "d") {
            let days = Int(token.dropLast()) ?? 1
            interval = days >= 7 ? .weekly : .daily
        } else if isNumericDuration(token, unit: "m") {
            // Sub-hour → hourly is the finest TaskFrequency we have.
            interval = .hourly
        } else if token == "weekly" {
            interval = .weekly
        } else {
            interval = nil
        }

        if let interval {
            // Interval token consumed. Empty remainder is a usage error,
            // not "the interval token is the prompt" (`/loop 1h`).
            return (interval, rest)
        }
        return (.none, raw)
    }

    private func formatContextUsage() -> String {
        let b = contextUsageBreakdown
        var lines = [
            "Context usage",
            "  Total: ~\(b.totalTokens) tokens",
            "  Window: \(b.windowTokens) · Budget (auto-compact @ \(Int(b.compactThresholdPercent))%): \(b.budgetTokens)",
            "  Until compact: \(b.tokensUntilCompact) tokens · \(String(format: "%.0f", b.budgetFraction * 100))% of budget"
        ]
        for cat in b.categories {
            let detail = cat.detail.isEmpty ? "" : " (\(cat.detail))"
            lines.append("  \(cat.label): ~\(cat.tokens)\(detail)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatSessionInfo() -> String {
        let modelID = conversation.modelID ?? app?.selectedModelID ?? "(none)"
        let modelName = app?.availableModels.first(where: { $0.id == modelID })?.displayName ?? modelID
        let turns = conversation.messages.filter { $0.role == .user && !$0.isWireOnlySystemReminder }.count
        let msgs = conversation.messages.count
        let mode = app?.executionMode.fullLabel ?? "?"
        let goal = sessionGoal.map { "Goal: \($0)" } ?? "Goal: (none)"
        let effort = thinkingEffort.title
        let b = contextUsageBreakdown
        return [
            "Session",
            "  Title: \(conversation.title.isEmpty ? "Untitled" : conversation.title)",
            "  Model: \(modelName)",
            "  Mode: \(mode) · Effort: \(effort)",
            "  Turns: \(turns) · Messages: \(msgs)",
            "  Context: ~\(b.totalTokens) / \(b.windowTokens) (budget \(b.budgetTokens))",
            "  \(goal)"
        ].joined(separator: "\n")
    }

    /// Opens a project file in the artifact rail (file-tree / explorer path).
    func previewProjectFile(relativePath: String, root: URL) {
        let url = root.appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let cardId = "tree:\(relativePath)"
        let card = ArtifactCard(
            id: cardId,
            toolName: "read_file",
            kind: .filePreview(path: relativePath),
            title: (relativePath as NSString).lastPathComponent,
            subtitle: relativePath,
            body: content,
            input: #"{"path":"\#(relativePath)"}"#,
            status: .success,
            createdAt: Date()
        )
        if let idx = artifactCards.firstIndex(where: { $0.id == cardId }) {
            artifactCards[idx] = card
        } else {
            artifactCards.insert(card, at: 0)
        }
        focusArtifact(cardId)
    }

    /// Artifact rail UI is retired (diffs live in-stream). closeRail remains
    /// for residual ArtifactRailView / ZCodePanelView until Phase 1 delete.
    func closeRail() {
        railVisible = false
        conversation.railUserPreference = false
        Task {
            try? await ConversationStore.shared.save(conversation)
        }
    }

    private func syncArtifacts(messageID: UUID, createdAt: Date) {
        guard let states = toolCallsByMessage[messageID] else { return }
        for state in states {
            guard ArtifactLabel.shouldShowInRail(toolName: state.toolName) else { continue }
            guard let card = ArtifactRebuild.card(from: state, createdAt: createdAt) else { continue }
            if let idx = artifactCards.firstIndex(where: { $0.id == card.id }) {
                artifactCards[idx] = card
            } else {
                artifactCards.insert(card, at: 0)
            }
        }
        if artifactCards.count > ArtifactRebuild.maxCards {
            artifactCards = Array(artifactCards.prefix(ArtifactRebuild.maxCards))
        }
    }

    private func refreshActivityLabel() {
        // Only the open turn while running — never earlier tools.
        let scoped = isRunning ? liveTurnToolStates : []
        if let running = scoped.first(where: { $0.status == .running }) {
            let label = ArtifactLabel.activityLabel(
                toolName: running.toolName, argsJSON: running.input)
            currentActivityLabel = label
            // Structured activity line for BuildCode-style "Verb · Status" display.
            currentActivityLine = ActivityLine(
                verb: ActivityLine.verb(forToolName: running.toolName),
                status: label
            )
        } else if isRunning && !streamingContent.isEmpty {
            currentActivityLabel = "Writing response…"
            currentActivityLine = nil
        } else if isRunning {
            currentActivityLabel = "Starting…"
            currentActivityLine = nil
        } else {
            currentActivityLabel = nil
            currentActivityLine = nil
        }
    }

    private func maybeAutoOpenRail(toolNames: [String]) {
        // Artifact rail retired as the primary diff surface — Chat shows
        // inline expandable edit cards. Never auto-open the rail.
        _ = toolNames
    }

    // MARK: - Helpers

    private func preferredModel(backend: any InferenceBackend, app: AppViewModel) -> ModelDescriptor? {
        // User's live picker choice wins over a stale conversation.modelID
        // (e.g. conversation still pinned to GLM after selecting Qwen).
        if let id = app.selectedModelID, !id.isEmpty {
            if let m = app.availableModels.first(where: { $0.id == id }) { return m }
            // Profile alias or freshly listed id — still send it; oMLX load
            // path strips `:profile` for the engine and uses full id in chat.
            return ModelDescriptor(
                id: id,
                displayName: id,
                backend: app.settings.backend,
                supportsTools: true
            )
        }
        if let id = conversation.modelID, !id.isEmpty {
            if let m = app.availableModels.first(where: { $0.id == id }) { return m }
            return ModelDescriptor(
                id: id,
                displayName: id,
                backend: app.settings.backend,
                supportsTools: true
            )
        }
        // No silent default — do not fall back to models.first (often
        // oMLX's pinned GLM). User must pick a model.
        return nil
    }

    // MARK: - Auto-title

    /// True when the conversation is still on its default title and
    /// should be auto-named on the next send. Treats the seeded
    /// placeholders ("New conversation", "Untitled", or empty) as
    /// untitled. Anything else is assumed to be a user-chosen title
    /// — including auto-derived titles from prior sends, which is why
    /// the auto-name only fires on the first user message.
    static func isUntitled(_ conv: Conversation) -> Bool {
        let t = conv.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "New conversation" || t == "Untitled"
    }

    /// Derives a sidebar title from the user's first prompt:
    ///   1. Stop at the first sentence terminator (. ! ? newline).
    ///   2. Collapse internal whitespace to single spaces.
    ///   3. Truncate at `maxLength` on a word boundary, append "…".
    ///   4. Capitalise the first letter when lowercase.
    /// Deterministic, no LLM round-trip, runs in O(prompt length).
    static func deriveTitle(from prompt: String, maxLength: Int = 50) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Sentence-bound the title — first ".", "!", "?", or newline.
        let terminators: Set<Character> = [".", "!", "?", "\n", "\r"]
        var firstSentence = ""
        for ch in trimmed {
            if terminators.contains(ch) { break }
            firstSentence.append(ch)
        }
        if firstSentence.isEmpty { firstSentence = trimmed }

        // Collapse internal whitespace runs.
        firstSentence = firstSentence
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+"#,
                                  with: " ",
                                  options: .regularExpression)

        // Word-boundary truncation with ellipsis.
        if firstSentence.count > maxLength {
            let cut = firstSentence.index(firstSentence.startIndex,
                                          offsetBy: maxLength)
            let head = firstSentence[..<cut]
            if let lastSpace = head.lastIndex(of: " ") {
                firstSentence = String(head[..<lastSpace]) + "…"
            } else {
                firstSentence = String(head) + "…"
            }
        }

        // Sentence-case if the first character is lowercase.
        if let first = firstSentence.first, first.isLowercase {
            firstSentence = first.uppercased() + firstSentence.dropFirst()
        }
        return firstSentence
    }
}

/// Marker for the PatchReviewSheet flow. P0 doesn't yet route patches
/// through review (the agent applies them directly); P1 hooks
/// `apply_patch` to pause here and wait for user accept/reject.
struct PendingPatch: Identifiable {
    let id = UUID()
    let path: String
    let original: String
    let updated: String
}

/// ZCode parity: a step marker for the transcript. Each agent-loop
/// iteration produces one step, shown as "Step N" with an optional
/// summary when it finishes. This lets users see the progression of a
/// multi-step turn (read → edit → build) in a way that a flat tool-call
/// list doesn't convey.
struct StepMarker: Identifiable, Equatable {
    let id = UUID()
    let iteration: Int
    var summary: String?

    /// Display label ("Step 1", "Step 2", etc.)
    var label: String { "Step \(iteration)" }
}

/// Structured activity line for BuildCode-style "Verb · Status" display.
struct ActivityLine: Equatable {
    /// Short verb for the tool category (e.g., "Explore", "Read", "Write").
    let verb: String
    /// Full status text from ArtifactLabel (e.g., "Running ls -la ~/Desktop").
    let status: String

    static func == (lhs: ActivityLine, rhs: ActivityLine) -> Bool {
        lhs.verb == rhs.verb && lhs.status == rhs.status
    }

    /// SF Symbol for the activity line, matching z.ai's per-category icons.
    /// Kept as a String so ChatViewModel (which lives in App/) stays free
    /// of SwiftUI dependencies; the view layer maps it to an Image.
    var icon: String {
        switch verb {
        case "Explore": return "magnifyingglass"
        case "Read":    return "book"
        case "Write":   return "pencil"
        case "Edit":    return "pencil.and.outline"
        case "Run":     return "terminal"
        case "Build":   return "hammer"
        case "Manage":  return "folder"
        case "Search":  return "globe"
        case "Ask":      return "questionmark.bubble"
        case "SubAgent": return "shippingbox"
        case "Agent":    return "shippingbox"
        default:         return "wrench"
        }
    }

    /// Map a tool name to its short verb for activity line display.
    static func verb(forToolName toolName: String) -> String {
        switch toolName {
        case "list_directory", "glob_files", "code_search", "grep_code":
            return "Explore"
        case "read_file", "read_file_range":
            return "Read"
        case "write_file":
            return "Write"
        case "edit_file", "apply_patch":
            return "Edit"
        case "run_shell", "run_shell_command":
            return "Run"
        case "build_xcode", "run_xcode_tests", "swift_check", "build_swift_package",
             "build_cargo", "build_npm", "xcode_build", "get_build_log":
            return "Build"
        case "delete_file", "move_file", "create_directory":
            return "Manage"
        case "fetch_url", "web_search", "fetch_rss":
            return "Search"
        case "ask_user":
            return "Ask"
        case "task":
            // Z Code label in the transcript (not the top jobs banner).
            return "SubAgent"
        default:
            // Capitalize the tool name with underscores replaced by spaces
            return toolName.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Transcript notices (compaction / harness surface)

/// In-session notice shown in the transcript (not persisted to wire history).
struct TranscriptNotice: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case compaction
        case goal
        case backgroundJob
        /// User hit Stop mid-turn — rendered under the assistant reply.
        case userStopped
        /// Post-edit BuildGuard result (S5 auto-verify).
        case buildVerify
    }

    let id: UUID
    let kind: Kind
    let title: String
    let detail: String
    let createdAt: Date
}

// MARK: - Build verify transcript notices (S5)

extension ChatViewModel {
    /// Build a transcript notice for BuildGuard outcomes (testable pure shape).
    static func makeBuildVerifyNotice(
        succeeded: Bool? = nil,
        skipped: Bool = false,
        detail: String?,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> TranscriptNotice {
        if skipped {
            return TranscriptNotice(
                id: id,
                kind: .buildVerify,
                title: "Auto-verify skipped",
                detail: detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (detail ?? "")
                    : "No build system found in the project folder. BuildGuard only runs for SwiftPM, Xcode, Cargo, or TypeScript (tsc) projects.",
                createdAt: createdAt
            )
        }
        if succeeded == true {
            return TranscriptNotice(
                id: id,
                kind: .buildVerify,
                title: "Auto-verify passed",
                detail: "BuildGuard compiled/checked the project after file edits. The agent saw the same result as a system reminder.",
                createdAt: createdAt
            )
        }
        let log = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = log.isEmpty
            ? "Build failed after the agent edited files. Open the project build log or re-run the build for full output."
            : String(log.prefix(500))
        return TranscriptNotice(
            id: id,
            kind: .buildVerify,
            title: "Auto-verify failed",
            detail: clipped,
            createdAt: createdAt
        )
    }

    fileprivate func appendBuildVerifyNotice(
        succeeded: Bool = false,
        skipped: Bool = false,
        detail: String?
    ) {
        let notice = Self.makeBuildVerifyNotice(
            succeeded: skipped ? nil : succeeded,
            skipped: skipped,
            detail: detail
        )
        // Avoid stacking identical success notices on every throttled pass.
        if notice.title == "Auto-verify passed",
           transcriptNotices.contains(where: {
               $0.kind == .buildVerify && $0.title == notice.title
               && Date().timeIntervalSince($0.createdAt) < 8
           }) {
            return
        }
        transcriptNotices.append(notice)
    }
}

// MARK: - PB2 lifecycle hooks (UserPromptSubmit / Stop)

/// Project/worktree roots used for hook discovery.
/// `project` is the bound project (or opened folder) — never the worktree
/// path — so `HookDispatcher.hooksDir` still finds `.vibecoder/hooks` in
/// the real project when a sibling worktree is active.
extension ChatViewModel {
    fileprivate func lifecycleHookRoots() -> (project: URL?, worktree: URL?) {
        let worktree = conversation.worktreeRootURL
        let project = conversation.projectRoot ?? app?.openedProject?.url
        return (project, worktree)
    }
}

/// App-side bridge to AgentCore lifecycle hooks for prompt submit / turn stop.
///
/// Uses PB1 first-class `HookDispatcher.userPromptSubmit` / `stop` (nested
/// `hooks.json` keys SessionStart / UserPromptSubmit / Stop / Notification).
///
/// Test seam: override `userPromptSubmitHandler` / `stopHandler` (reset in tearDown).
enum ChatPromptHooks {
    /// Optional test override. `nil` → default HookDispatcher lifecycle APIs.
    nonisolated(unsafe) static var userPromptSubmitHandler:
        ((String, URL?, URL?) -> HookDecision)?
    /// Optional test override. `nil` → default HookDispatcher lifecycle APIs.
    nonisolated(unsafe) static var stopHandler:
        ((String, String, URL?, URL?) -> Void)?

    /// Returns a user-facing status string when the hook denies; `nil` if allowed.
    static func userPromptSubmitDeniedMessage(
        text: String,
        projectRoot: URL?,
        worktreeRoot: URL?
    ) -> String? {
        let decision = runUserPromptSubmit(
            text: text,
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot
        )
        guard !decision.allow else { return nil }
        let reason = decision.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason, !reason.isEmpty {
            return "Prompt blocked: \(reason)"
        }
        return "Prompt blocked by project hook."

    }

    static func runUserPromptSubmit(
        text: String,
        projectRoot: URL?,
        worktreeRoot: URL?
    ) -> HookDecision {
        if let handler = userPromptSubmitHandler {
            return handler(text, projectRoot, worktreeRoot)
        }
        return HookDispatcher.userPromptSubmit(
            prompt: text,
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot
        )
    }

    static func fireStop(
        reason: String,
        detail: String,
        projectRoot: URL?,
        worktreeRoot: URL?
    ) {
        if let handler = stopHandler {
            handler(reason, detail, projectRoot, worktreeRoot)
            return
        }
        // Stop is observational after the turn finishes; deny is recorded only.
        let summary = "\(reason): \(detail.prefix(160))"
        _ = HookDispatcher.stop(
            reason: summary,
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot
        )
    }

    /// Reset test overrides (call from XCTest tearDown).
    static func resetTestHandlers() {
        userPromptSubmitHandler = nil
        stopHandler = nil
    }
}
