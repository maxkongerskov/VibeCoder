//
//  ChatView.swift
//
//  Real (un-mocked) chat pane. Drives `ChatViewModel`, which fronts the
//  AgentLoop + spawned backend. Visually mirrors `MockChatView`: same
//  ChatHeaderView, same EngineLoadBar strip, fluid transcript column
//  column, same InputBarViewV2 card. The only differences from the mock
//  are dynamic state (live message list, streaming bubble, statusLine
//  pill, cancel affordance).
//

import SwiftUI
import AppKit
import AgentCore

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @EnvironmentObject var app: AppViewModel
    @State private var draftInput: String = ""
    @State private var showWorktreeReview: Bool = false
    @State private var worktreeReviewFiles: [WorktreeFileChange] = []
    @State private var worktreeReviewBranch: String = ""
    @State private var showRemoteControl: Bool = false

    /// When true, streaming/new messages keep the transcript pinned to the
    /// live edge. A trackpad nudge upward detaches; scrolling back to the
    /// bottom re-attaches (see StickToBottomTracker).
    @State private var stickToBottom: Bool = true

    // BuildCode-style working header timer — "Working for Ns"
    @State private var elapsedSeconds: Int = 0

    /// Synchronous re-entry guard for send. Prevents the Return key
    /// handler and Send button from both dispatching a send on a single
    /// keypress. Stored as `@State` so SwiftUI's framework-managed
    /// storage backs the flag — writes are immediate at the cell level,
    /// so a second handler firing in the same event batch sees the
    /// updated value (unlike `draftInput` clearing, whose *view*
    /// update is batched). A plain stored property would not compile:
    /// a `View` struct's non-mutating methods cannot assign to its
    /// own properties.
    @State private var isSending: Bool = false
    /// User hid the floating plan panel (✕). Reappears when the plan identity changes.
    @State private var planPanelDismissedIdentity: String? = nil

    // MARK: - Derived header state

    /// The `ModelDescriptor` for the conversation's current model, if the
    /// active backend has surfaced it. Used to drive header chips + the
    /// context-usage gauge without falling back to mocks.
    private var activeModel: ModelDescriptor? {
        let id = viewModel.conversation.modelID ?? app.selectedModelID
        guard let id else { return nil }
        return app.availableModels.first { $0.id == id }
    }

    private var headerCapabilities: [ModelCapability] {
        // LMModel's capability heuristic is name-based (matches "qwen",
        // "gemma", "vision", etc. against the id string). If the model id
        // is unknown we keep `tools + reasoning` as the conservative
        // default that almost every modern instruct model supports.
        if let id = viewModel.conversation.modelID ?? app.selectedModelID {
            let caps = LMModel(id: id).capabilities
            if !caps.isEmpty { return caps }
        }
        // The backend also surfaces capabilities via supportsTools on
        // ModelDescriptor; reflect that into the chip set.
        if let desc = activeModel {
            var caps: [ModelCapability] = []
            if desc.supportsTools { caps.append(.toolCalling) }
            caps.append(.reasoning)
            return caps
        }
        return [.toolCalling, .reasoning]
    }

    private var contextTokens: Int { viewModel.liveContextTokens }

    /// Effective model context window (not auto-compact budget) for used/window meter.
    private var contextLimit: Int {
        viewModel.liveContextWindow
            ?? activeModel.flatMap { $0.contextLength }.map { max(2_048, $0) }
            ?? 32_768
    }

    var body: some View {
        GeometryReader { geo in
            // Artifact rail retired — diffs are inline in the transcript.
            // Shared fluid column: grows with the pane (soft max 1040 via
            // Theme.ChatLayout.contentWidth) so transcript + composer never
            // sit as a stuck ~720 island with huge empty side bands.
            let columnWidth = Theme.ChatLayout.contentWidth(paneWidth: geo.size.width)
            // Side gutter matches contentWidth math so the floating plan
            // aligns with the transcript column, not the raw window edge.
            let sideGutter = max(
                Theme.ChatLayout.sideGutter,
                (geo.size.width - columnWidth) / 2
            )

            chatColumn(columnWidth: columnWidth)
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .topTrailing) {
                    floatingPlanPanel(columnWidth: columnWidth)
                        .padding(.top, 52)
                        .padding(.trailing, sideGutter)
                }
        }
        .background(Theme.Palette.canvas)
        .onReceive(NotificationCenter.default.publisher(for: .exportConversationRequested)) { note in
            // Only export when this chat is the target (or object is nil).
            if let id = note.object as? UUID, id != viewModel.conversation.id { return }
            exportMarkdownToFile()
        }
        // Worktree review sheet — real `git diff` / status from the worktree.
        .sheet(isPresented: $showWorktreeReview) {
            WorktreeReviewSheet(
                branchName: worktreeReviewBranch.isEmpty
                    ? (viewModel.conversation.worktreeBranch ?? "worktree")
                    : worktreeReviewBranch,
                files: worktreeReviewFiles,
                onDismiss: { showWorktreeReview = false },
                onMerge: { message in
                    showWorktreeReview = false
                    app.mergeWorktree(for: viewModel.conversation.id, commitMessage: message)
                },
                onDiscard: {
                    showWorktreeReview = false
                    app.discardWorktree(for: viewModel.conversation.id)
                }
            )
        }
        // Error alert — surfaces "not a git repository", merge conflicts,
        // etc. Cleared as soon as the user dismisses.
        //
        // The setter and the OK button both defer the @Published mutation
        // via `Task { @MainActor in ... }`. SwiftUI sometimes calls the
        // binding's `set` closure while the alert is still in a render
        // pass; mutating `@Published` synchronously from there triggers
        // "Publishing changes from within view updates is not allowed."
        // Deferring lands the write on the next runloop tick.
        .alert(
            "Worktree error",
            isPresented: Binding(
                get: { app.worktreeError != nil },
                set: { newValue in
                    if !newValue {
                        Task { @MainActor in app.worktreeError = nil }
                    }
                }
            ),
            presenting: app.worktreeError
        ) { _ in
            Button("OK", role: .cancel) {
                Task { @MainActor in app.worktreeError = nil }
            }
        } message: { msg in
            Text(msg)
        }
        // Patch review sheet. When Safe Mode is on, `apply_patch`
        // suspends and publishes a batch into the coordinator; we
        // present the sheet here. Mounted as an empty background view
        // because the coordinator (held on AppViewModel) is a separate
        // ObservableObject that needs explicit @ObservedObject binding
        // — env-object propagation would skip its @Published changes.
        .background(
            PatchReviewSheetMount(
                coordinator: app.patchReviewCoordinator,
                // Prefer worktree when active so @-mentions / path UX match
                // where ToolContext.workingDirectory writes (Wave C W13).
                projectRoot: viewModel.conversation.worktreeRootURL
                    ?? viewModel.conversation.projectRoot
            )
        )
        .background(
            ShellApprovalSheetMount(coordinator: app.shellApprovalCoordinatorService)
        )
        .sheet(isPresented: $showRemoteControl) {
            RemoteControlSheet(onDismiss: { showRemoteControl = false })
                .environmentObject(app)
        }

        // Live timer — ticks every second while a turn is in flight,
        // driving the WorkingHeader "Working for Ns" display.
        .task(id: viewModel.workStartedAt) {
            if let started = viewModel.workStartedAt {
                elapsedSeconds = 0
                while !Task.isCancelled && viewModel.isRunning {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    await MainActor.run { elapsedSeconds = Int(Date().timeIntervalSince(started)) }
                }
            } else {
                elapsedSeconds = 0
            }
        }
    }

    @ViewBuilder
    private func chatColumn(columnWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            ChatHeaderView(
                title: viewModel.conversation.title.isEmpty
                    ? "New conversation"
                    : viewModel.conversation.title,
                projectName: nil,
                capabilities: headerCapabilities,
                // Real worktree state — pill lights when a worktree branch
                // is persisted on the conversation. Toggling routes to
                // WorktreeService via AppViewModel.
                worktreeActive: viewModel.conversation.worktreeBranch != nil,
                contextTokens: contextTokens > 0 ? contextTokens : nil,
                contextLimit: contextLimit,
                onRename: { newTitle in
                    app.renameConversation(id: viewModel.conversation.id, to: newTitle)
                },
                onDuplicate: {
                    app.duplicateConversation(viewModel.conversation.id)
                },
                onExportMarkdown: { exportMarkdownToFile() },
                onCopyMarkdown: { copyMarkdownToClipboard() },
                onToggleWorktree: { handleToggleWorktree() },
                onRemoteControl: { showRemoteControl = true },
                onDelete: {
                    app.deleteConversation(viewModel.conversation.id)
                },
                // Defer the @Published write: `.onChange` inside
                // ChatHeaderView can fire mid-update on rapid toggle
                // transitions; bouncing through `Task { @MainActor in }`
                // guarantees we mutate on a clean runloop tick.
                onSafeModeChanged: { isOn in
                    Task { @MainActor in
                        // Writing safeModeOn syncs executionMode via didSet.
                        app.safeModeOn = isOn
                    }
                },
                onHeadlessModeChanged: { isOn in
                    Task { @MainActor in app.headlessModeOn = isOn }
                },
                safeModeAllowedPaths: $app.safeModeAllowedPaths,
                safeModeAllowedShellPrefixes: $app.safeModeAllowedShellPrefixes
            )
            // ZCode: ⇧Tab cycles execution mode (Plan → Ask → Auto → Full).
            .onKeyPress(keys: [.tab], phases: .down) { press in
                if press.modifiers.contains(.shift) {
                    app.cycleExecutionMode()
                    return .handled
                }
                return .ignored
            }

            // Engine-load bar reflects both subprocess startup and per-turn
            // streaming. Either keeps the strip lit so the user always has
            // a visual answer to "is something happening?".
            // No hairline under the title chrome — canvas is continuous.
            EngineLoadBar(isLoading: isEngineBusy || app.isLoadingModel)
                .background(Theme.Palette.canvas)

            // oMLX / backend load failure when the user picks a model.
            if let loadErr = app.modelLoadError, !loadErr.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Palette.error)
                    Text(loadErr)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.error)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        app.modelLoadError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Palette.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.Palette.error.opacity(0.08))
            }

            // Goal stall / premature-stop / pause — slides in from the top.
            if let status = viewModel.goalStatusText {
                GoalStatusBanner(
                    statusText: status,
                    goalDescription: viewModel.goalDescription
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Background shell + subagent jobs (killable while running).
            if !viewModel.backgroundJobs.isEmpty {
                BackgroundJobsBanner(
                    jobs: viewModel.backgroundJobs,
                    onKill: { viewModel.killBackgroundJob($0) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Plan UI is a floating overlay (see floatingPlanPanel) — not a
            // full-width sticky bar, so the transcript stays uncluttered.

            // Model · mode · context chrome removed from chat; pickers live
            // in the composer / Settings. Quiet run status only when needed
            // is optional via statusLine inside the transcript flow.

            transcript(columnWidth: columnWidth)

            QuestionCardMount(coordinator: app.userQuestionCoordinator)
                .chatFluidColumn(width: columnWidth)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.82),
                           value: app.userQuestionCoordinator.pendingQuestion != nil)

            // No ProcessingStatusBar above the composer — run/thinking state
            // already lives in the transcript (Working header, ReasoningBlock,
            // PendingAssistantBubble). Docked bar was redundant chrome.

            // Live fluid column — same width as transcript (`columnWidth` from
            // Theme.ChatLayout.contentWidth). Composer also re-measures the
            // pane so the input card cannot stick at a stale default.
            MentionAwareComposer(
                text: $draftInput,
                attachments: $viewModel.pendingAttachments,
                stickyPins: $viewModel.stickyContextPins,
                // Prefer worktree when active so @-mentions / path UX match
                // where ToolContext.workingDirectory writes (Wave C W13).
                projectRoot: viewModel.conversation.worktreeRootURL
                    ?? viewModel.conversation.projectRoot,
                onSend: handleSend,
                isRunning: viewModel.isRunning,
                onCancel: { viewModel.cancel() },
                promptHistory: viewModel.promptHistory,
                maxCardWidth: columnWidth,
                sideGutter: 0, // gutters baked into contentWidth; card self-centers
                contextTokens: contextTokens > 0 ? contextTokens : nil,
                contextLimit: contextLimit,
                contextBreakdown: viewModel.contextUsageBreakdown,
                thinkingCapability: viewModel.activeThinkingCapability,
                thinkingEffort: $viewModel.thinkingEffort
            )
            .frame(maxWidth: .infinity)
            .onAppear {
                viewModel.ensurePromptHistoryLoaded()
                viewModel.syncPlanFromStore()
            }
            .onChange(of: viewModel.conversation.id) { _, _ in
                viewModel.syncPlanFromStore()
            }
        }
    }

    // MARK: - Floating plan / todo

    /// Floating plan card. Width tracks the fluid chat column (`contentWidth`)
    /// so narrow splits don't overflow and wide panes stay aligned with gutters.
    @ViewBuilder
    private func floatingPlanPanel(columnWidth: CGFloat) -> some View {
        if viewModel.planIsLive, let plan = viewModel.activePlan {
            let identity = plan.panelIdentity
            let dismissed = planPanelDismissedIdentity == identity
            if !dismissed {
                // Compact card; never wider than the fluid transcript column.
                let plannerWidth = min(320, max(200, columnWidth))
                StickyPlannerView(
                    plan: plan,
                    panelWidth: plannerWidth,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            planPanelDismissedIdentity = identity
                        }
                    },
                    showApprovalActions: viewModel.planNeedsApproval,
                    onApprove: {
                        planPanelDismissedIdentity = nil
                        viewModel.approvePlanAndContinue()
                    },
                    onRejectStay: {
                        viewModel.rejectPlanStayInPlan()
                    },
                    onToggleTodo: viewModel.planNeedsApproval
                        ? { viewModel.togglePlanTodo(id: $0) }
                        : nil
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(50)
            }
        }
    }

    // MARK: - Worktree toggle

    /// Routes the header's worktree toggle to the right AppViewModel call.
    ///   * inactive → enable a fresh worktree
    ///   * active   → load real git diff and present WorktreeReviewSheet
    private func handleToggleWorktree() {
        if viewModel.conversation.worktreeBranch == nil {
            app.enableWorktree(for: viewModel.conversation.id)
        } else {
            worktreeReviewBranch = viewModel.conversation.worktreeBranch ?? "worktree"
            if let root = viewModel.conversation.worktreeRootURL?.path {
                worktreeReviewFiles = WorktreeFileChange.from(worktreePath: root)
            } else {
                worktreeReviewFiles = []
            }
            showWorktreeReview = true
        }
    }

    // MARK: - Engine-busy heuristic

    private var isEngineBusy: Bool {
        viewModel.isRunning
    }

    /// Empty-chat brand watermark — hide as soon as anything transcript-worthy appears.
    static func shouldShowEmptyBrandHero(
        messages: [ChatMessage],
        isRunning: Bool,
        streamingContent: String,
        noticesEmpty: Bool
    ) -> Bool {
        guard noticesEmpty else { return false }
        guard !isRunning else { return false }
        if !streamingContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        // Only user/assistant count — system/tool noise shouldn't clear the hero.
        let visible = messages.contains { $0.role == .user || $0.role == .assistant }
        return !visible
    }

    /// Stamp approximate "Worked for Ns" for older transcripts that never
    /// persisted `workDurationSeconds` (user message → assistant message).
    private static func messageWithDurationFallback(
        _ message: ChatMessage,
        precedingBlocks: [RenderBlock]
    ) -> ChatMessage {
        guard message.role == .assistant, message.workDurationSeconds == nil else {
            return message
        }
        guard let userTS = precedingBlocks.last(where: { $0.displayMessage.role == .user })?
            .displayMessage.timestamp else {
            return message
        }
        let secs = Int(message.timestamp.timeIntervalSince(userTS).rounded())
        guard secs > 0 else { return message }
        var copy = message
        copy.workDurationSeconds = min(secs, 24 * 3600)
        return copy
    }

    // MARK: - Status pill

    private var statusPill: some View {
        // Cancel moved into the input bar — when isRunning, the Send
        // button morphs to a square stop button. This keeps the status
        // line as quiet running commentary ("Iteration 2…", tool ✓/✗,
        // errors) without competing affordances.
        HStack(spacing: 6) {
            Text(viewModel.statusLine)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.Palette.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// Empty-chat copy: guide first-run when no backend/model is ready.
    private var emptyHeroTitle: String {
        if app.availableModels.isEmpty {
            return "Connect a model server"
        }
        if app.selectedModelID == nil || (app.selectedModelID?.isEmpty ?? true) {
            return "Pick a model to start"
        }
        return "What are we working on?"
    }

    private var emptyHeroSubtitle: String {
        if app.availableModels.isEmpty {
            return "Start LM Studio, Ollama, or oMLX on this Mac, then open Settings → Connection and Test."
        }
        if app.selectedModelID == nil || (app.selectedModelID?.isEmpty ?? true) {
            return "Use the model chip in the composer (bottom-right) to select a tool-capable coding model."
        }
        return "Bind a project folder, describe a task, and the agent will plan, edit, and verify on your machine."
    }

    // MARK: - Transcript
    //
    // Identical column geometry to MockChatView so the visual treatment
    // stays consistent across the demo path and the real path: max card
    // fluid column via Theme.ChatLayout.contentWidth(pane) (Claude-style
    // growth with capped gutters). Auto-scrolls to the latest message
    // as the stream grows.

    // MARK: - Render-block grouping
    //
    // Walks the visible (non-tool/non-system) message list and
    // produces an array of blocks. User messages are 1:1. Consecutive
    // assistant messages collapse into ONE block whose
    // displayMessage is the last in the run (its content is the final
    // prose response, the only one users care about visually) and
    // whose aggregatedToolCalls is the union of every tool call from
    // every message in the run. The downstream MessageBubbleViewV2
    // then renders one ToolUseBanner spanning the whole turn.

    private struct RenderBlock: Identifiable {
        let id: UUID
        let displayMessage: ChatMessage
        let aggregatedToolCalls: [ToolCallUIState]
        /// Full assistant run for chronological think→tool→think layout.
        let assistantTurnMessages: [ChatMessage]
        /// Tools keyed by assistant message id (same run only).
        let toolsByMessageID: [UUID: [ToolCallUIState]]
        /// First assistant message of this run — seed file contents from tools *before* it.
        let runStartMessageID: UUID?
    }

    private var renderBlocks: [RenderBlock] {
        let visible = viewModel.conversation.messages.filter {
            $0.role != .tool && $0.role != .system
        }
        var out: [RenderBlock] = []
        var assistantRun: [ChatMessage] = []

        func flushRun() {
            guard let last = assistantRun.last else { return }
            // Tools only for messages in THIS run (between user prompts).
            var byID: [UUID: [ToolCallUIState]] = [:]
            for msg in assistantRun {
                let calls = viewModel.toolCalls(forMessageID: msg.id)
                if !calls.isEmpty { byID[msg.id] = calls }
            }
            let calls = assistantRun.flatMap { viewModel.toolCalls(forMessageID: $0.id) }
            // Find the most recent non-empty content in the run — that's
            // what the user wants to read. Earlier iterations often have
            // empty content (pure tool-call turns) or scratch text like
            // "Let me try X" that no longer matters once the final
            // answer has arrived.
            var display = last
            if display.content.isEmpty,
               let withText = assistantRun.reversed().first(where: { !$0.content.isEmpty }) {
                display = withText
            }
            out.append(RenderBlock(id: last.id,
                                   displayMessage: display,
                                   aggregatedToolCalls: calls,
                                   assistantTurnMessages: assistantRun,
                                   toolsByMessageID: byID,
                                   runStartMessageID: assistantRun.first?.id))
            assistantRun.removeAll(keepingCapacity: true)
        }

        for msg in visible {
            switch msg.role {
            case .assistant:
                assistantRun.append(msg)
            case .user:
                flushRun()
                out.append(RenderBlock(id: msg.id,
                                       displayMessage: msg,
                                       aggregatedToolCalls: [],
                                       assistantTurnMessages: [],
                                       toolsByMessageID: [:],
                                       runStartMessageID: nil))
            default:
                break   // .tool and .system already filtered above
            }
        }
        flushRun()
        return out
    }

    @ViewBuilder
    private func pendingAssistantBubble(scaledFont: CGFloat) -> some View {
        let liveTools = viewModel.liveTurnToolStates
        let orchCaption: String? = app.orchestrationActive
            ? "\(ModelPickerButton.prettyModelName(app.settings.orchestratorModelID)) → \(ModelPickerButton.prettyModelName(app.settings.workerModelID))"
            : nil
        PendingAssistantBubble(
            streamBuffer: viewModel.streamingContent,
            reasoningBuffer: viewModel.streamingReasoning,
            reasoningStartedAt: viewModel.reasoningStartedAt,
            activityLabel: viewModel.currentActivityLabel,
            hasProcess: !liveTools.isEmpty,
            playfulLabels: app.settings.playfulWaitingLabels && liveTools.isEmpty,
            cleanModelChrome: app.settings.cleanModelChrome,
            fontSize: scaledFont,
            activityLine: viewModel.currentActivityLine,
            liveToolStates: liveTools,
            orchestrationCaption: orchCaption,
            priorFileContents: viewModel.fileContentsBeforeCurrentTurn(),
            onKillJob: { viewModel.killBackgroundJob($0) },
            backgroundJobs: viewModel.backgroundJobs,
            elapsedSeconds: elapsedSeconds,
            rolledBackHunkIDs: viewModel.rolledBackHunkIDs,
            onUndoEdit: { edit in
                Task { @MainActor in
                    await viewModel.undoFileEdits(
                        hunkIDs: edit.hunkIDs,
                        shortPath: edit.shortPath
                    )
                }
            }
        )
        .padding(.top, Theme.ChatLayout.beforeAssistant)
        .id("pending")
    }

    /// Isolated so the main transcript VStack type-checks in reasonable time.
    @ViewBuilder
    private func transcriptBlock(
        block: RenderBlock,
        index: Int,
        blocks: [RenderBlock],
        running: Bool,
        scaledFont: CGFloat
    ) -> some View {
        // While a turn is live, the last assistant block is the in-flight turn
        // already painted by PendingAssistantBubble — skip the finished twin.
        let isLiveAssistant = running
            && index == blocks.count - 1
            && block.displayMessage.role == .assistant
        if !isLiveAssistant {
            let priorFiles: [String: String] = {
                guard let start = block.runStartMessageID else { return [:] }
                return viewModel.fileContents(beforeMessageID: start)
            }()
            let displayMsg = Self.messageWithDurationFallback(
                block.displayMessage,
                precedingBlocks: Array(blocks.prefix(index))
            )
            MessageBubbleViewV2(
                message: displayMsg,
                attachedToolCalls: block.aggregatedToolCalls,
                assistantTurnMessages: block.assistantTurnMessages,
                toolsByMessageID: block.toolsByMessageID,
                isStreaming: false,
                isActiveTurn: false,
                fontSize: scaledFont,
                priorFileContents: priorFiles,
                onKillJob: { viewModel.killBackgroundJob($0) },
                backgroundJobs: viewModel.backgroundJobs,
                rolledBackHunkIDs: viewModel.rolledBackHunkIDs,
                onUndoEdit: { edit in
                    Task { @MainActor in
                        await viewModel.undoFileEdits(
                            hunkIDs: edit.hunkIDs,
                            shortPath: edit.shortPath
                        )
                    }
                },
                cleanModelChrome: app.settings.cleanModelChrome
            )
            .id(block.id)
        }

        if block.displayMessage.role == .user,
           let brief = viewModel.conversation.orchestratorBriefs[block.id.uuidString],
           !brief.isEmpty {
            OrchestratorPlanView(brief: brief)
        }
    }

    private func transcript(columnWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Fixed gap between transcript blocks so the trailing user
                // pill never sits flush against flat LLM prose (and vice
                // versa). Extra after-user / before-assistant padding lives
                // on MessageBubbleViewV2.
                //
                // We also filter `.tool` and `.system` messages out of
                // the rendered list entirely. Returning `EmptyView()`
                // from MessageBubbleViewV2 wasn't enough — SwiftUI
                // still allots VStack spacing around each child slot.
                // Skipping them in the ForEach removes the slot, so
                // the gap collapses with them.
                VStack(alignment: .leading, spacing: Theme.ChatLayout.messageGap) {
                    // Build render blocks: each block is either a single
                    // user message OR a *group* of consecutive assistant
                    // messages that together represent one logical
                    // "turn". The agent loop emits one assistant message
                    // per iteration — for tool-heavy turns that's 5-10
                    // separate ChatMessage rows. Rendering each as its
                    // own bubble produced the "stack of 'Used 1 tool'
                    // banners" misery. Merging gives the Claude Cowork
                    // pattern: one banner aggregating every tool call
                    // of the turn + the FINAL prose response below it.
                    // The LAST block during an active run is treated as
                    // "still streaming" — even if its underlying message
                    // is technically persisted. Without this, the
                    // agent loop's intermediate iterations would render
                    // their "done" treatment (static sparkle + Copy
                    // chip) underneath an active in-flight turn.
                    let blocks = renderBlocks
                    // ZCode body ~15pt; chatFontScale multiplies from that base.
                    // Same base as the composer so transcript + input stay on parity.
                    let scaledFont: CGFloat = Theme.ChatLayout.bodyFontSize
                        * CGFloat(app.settings.chatFontScale)
                    let running = viewModel.isRunning
                    let showBrandHero = Self.shouldShowEmptyBrandHero(
                        messages: viewModel.conversation.messages,
                        isRunning: running,
                        streamingContent: viewModel.streamingContent,
                        noticesEmpty: viewModel.transcriptNotices.isEmpty
                    )

                    // ZCode-style empty chat: outline monogram fills the
                    // pane until the first user turn (or stream) starts.
                    if showBrandHero {
                        EmptyChatBrandHero(
                            title: emptyHeroTitle,
                            subtitle: emptyHeroSubtitle
                        )
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 220)
                            .padding(.top, 48)
                    }

                    // Compaction / harness notices — narrate silent wire work.
                    // User-stop markers render under the assistant turn instead.
                    ForEach(viewModel.transcriptNotices.filter { $0.kind != .userStopped }) { notice in
                        TranscriptNoticeCard(notice: notice) {
                            viewModel.dismissTranscriptNotice(notice.id)
                        }
                        .id(notice.id)
                        .padding(.bottom, 8)
                    }

                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        transcriptBlock(
                            block: block,
                            index: index,
                            blocks: blocks,
                            running: running,
                            scaledFont: scaledFont
                        )
                    }

                    if running {
                        pendingAssistantBubble(scaledFont: scaledFont)
                    }

                    // Stop button → quiet marker under the LLM reply.
                    ForEach(viewModel.transcriptNotices.filter { $0.kind == .userStopped }) { notice in
                        TurnEndedByUserLabel(notice: notice) {
                            viewModel.dismissTranscriptNotice(notice.id)
                        }
                        .id(notice.id)
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Live-edge anchor used by stick-to-bottom follow.
                    Color.clear
                        .frame(height: 1)
                        .id("transcript-bottom")
                }
                .padding(.vertical, 20)
                // Hard width so ScrollView content actually tracks resize
                // (maxWidth alone leaves the stack at ideal text width).
                .chatFluidColumn(width: columnWidth)
                // Probe lives inside the scroll content so it can find NSScrollView.
                .background(
                    StickToBottomTracker(isPinned: $stickToBottom, threshold: 72)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                )
            }
            .onChange(of: viewModel.conversation.id) { _, _ in
                // Fresh conversation → re-attach follow.
                stickToBottom = true
                scrollToLatest(proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.conversation.messages.count) { _, _ in
                // Sending a new user turn always re-pins (ChatGPT behavior).
                if viewModel.conversation.messages.last?.role == .user {
                    stickToBottom = true
                }
                guard stickToBottom else { return }
                scrollToLatest(proxy: proxy)
            }
            .onChange(of: viewModel.streamingContent) { _, _ in
                guard stickToBottom else { return }
                // Instant follow while streaming — animated scroll fights the
                // trackpad and makes the whole pane feel like it's bucking.
                scrollToLatest(proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.streamingReasoning) { _, _ in
                guard stickToBottom else { return }
                scrollToLatest(proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.liveTurnToolStates.count) { _, _ in
                // Tool rows / edit cards grow without content tokens — keep pin.
                guard stickToBottom else { return }
                scrollToLatest(proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.isRunning) { _, running in
                // When a turn finishes, settle on the final bubble if still pinned.
                guard stickToBottom, !running else { return }
                scrollToLatest(proxy: proxy, animated: true)
            }
            .onAppear {
                stickToBottom = true
                // First paint of a long user prompt: land on its start,
                // not scrolled past into the middle of the bubble.
                scrollToLatest(proxy: proxy, animated: false)
            }
        }
    }

    /// Scroll policy (only called when `stickToBottom` is true, except
    /// forced paths like conversation switch / first appear):
    /// - Streaming → follow the pending assistant bubble (bottom).
    /// - Last message is user → pin to the **top** of that bubble so a
    ///   long first prompt's start is visible (never mid-clipped).
    /// - Last message is assistant → pin to bottom of the turn.
    private func scrollToLatest(proxy: ScrollViewProxy, animated: Bool = true) {
        let run: () -> Void = {
            if viewModel.isRunning {
                proxy.scrollTo("pending", anchor: .bottom)
            } else if let last = viewModel.conversation.messages.last {
                if last.role == .user {
                    proxy.scrollTo(last.id, anchor: .top)
                } else {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            } else {
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        }
        if animated {
            withAnimation(.easeOut(duration: 0.15), run)
        } else {
            run()
        }
    }

    // MARK: - Send

    private func handleSend() {
        // Synchronous re-entry guard: the Return key handler in
        // InputBarViewV2 and the Send button can both fire on a single
        // keypress. `@State` text-clearing is deferred by SwiftUI's
        // batching, so checking for empty text doesn't work — both
        // handlers see the same non-empty draft. This flag is set
        // synchronously and cleared when the send Task completes.
        guard !isSending else { return }
        let text = draftInput
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true

        // ZCode parity: intercept slash commands before sending as a
        // normal message. The handler may clear state, open pickers, or
        // show status feedback — in which case we don't call send().
        let result = viewModel.handleSlashCommand(text)
        if case .handled(let message) = result {
            if let message, !message.isEmpty {
                viewModel.statusLine = message
            }
            draftInput = ""
            isSending = false
            return
        }

        // Clear draft only after we know send will run. Restore if send
        // rejects early (no model / hook deny) so user text is not lost.
        draftInput = ""

        // Defer to a fresh runloop tick. `viewModel.send` synchronously
        // mutates four @Published properties (isRunning, streamingContent,
        // statusLine, conversation) before kicking off the agent task.
        // Hitting Return inside `TextEditor` fires `.onKeyPress` during
        // SwiftUI's body update pass on macOS 14+ — mutating @Published
        // from there triggers "Publishing changes from within view
        // updates is not allowed." Bouncing through `Task { @MainActor }`
        // lands the prefix mutations on the next tick, after the current
        // body finishes. Same code path covers Send-button taps and
        // accessibility default-action invocations.
        Task { @MainActor in
            let accepted = viewModel.send(text)
            if !accepted {
                // Restore draft when send bailed without starting a turn.
                if self.draftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.draftInput = text
                }
            }
            self.isSending = false
        }
    }

    // MARK: - Title-menu helpers

    /// Renders the conversation as plain markdown (S6 pure helper).
    private func renderMarkdown() -> String {
        ConversationMarkdownExport.render(
            conversation: viewModel.conversation,
            streamingContent: viewModel.streamingContent,
            streamingReasoning: viewModel.streamingReasoning
        )
    }

    /// Copies the rendered markdown to the system clipboard.
    private func copyMarkdownToClipboard() {
        let md = renderMarkdown()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        viewModel.statusLine = "Copied conversation Markdown (\(md.utf8.count) bytes)"
    }

    /// Presents an NSSavePanel and writes the rendered markdown to the
    /// selected URL. Surfaces write failures in the status line.
    private func exportMarkdownToFile() {
        let panel = NSSavePanel()
        panel.title = "Export conversation as Markdown"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = ConversationMarkdownExport.suggestedFilename(
            for: viewModel.conversation)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else {
            viewModel.statusLine = "Export cancelled"
            return
        }
        let md = renderMarkdown()
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusLine = "Exported Markdown → \(url.lastPathComponent)"
        } catch {
            viewModel.statusLine = "Export failed: \(error.localizedDescription)"
        }
    }

}

// MARK: - ShellApprovalSheetMount (Wave B S4)

private struct ShellApprovalSheetMount: View {
    @ObservedObject var coordinator: ShellApprovalCoordinatorService

    var body: some View {
        Color.clear
            .sheet(item: $coordinator.pending, onDismiss: {
                // Esc / close without a button → fail closed so the turn does not hang.
                coordinator.handleSheetDismiss()
            }) { pending in
                ShellApprovalSheet(request: pending.request) { decision in
                    coordinator.resolve(decision)
                }
            }
    }
}

// MARK: - PatchReviewSheetMount
//
// Standalone observer view for the PatchReviewCoordinator. Lives next
// to ChatView because that's the only screen patch review is meaningful
// from. Carries the coordinator as @ObservedObject so its @Published
// `pendingBatch` re-renders this view — env-object propagation alone
// would skip ObservableObject children.

private struct PatchReviewSheetMount: View {
    @ObservedObject var coordinator: PatchReviewCoordinator
    /// Active conversation project root — scopes durable folder grants.
    var projectRoot: URL?

    var body: some View {
        Color.clear
            .sheet(item: $coordinator.pendingBatch, onDismiss: {
                coordinator.rejectIfStillPending()
            }) { batch in
                // Translate previews → UI FilePatch values, and keep a
                // path→preview-id map so file-level decisions map back
                // to AgentCore `PatchDecision` (accept/reject whole files).
                let uiPatches = batch.previews.map(FilePatch.from(preview:))
                let pathToPreviewID: [String: UUID] = Dictionary(
                    uniqueKeysWithValues: batch.previews.map { ($0.path, $0.id) }
                )
                let grantProjectKey = SafeModeConfig.normalizePath(
                    (projectRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path
                )

                PatchReviewSheetV2(
                    patches: uiPatches,
                    onApply: { fileDecisions in
                        // File-level only — UI and wire format agree (v1).
                        let decision = PatchReviewApplyMapping.toPatchDecision(
                            decisions: fileDecisions,
                            pathToPreviewID: pathToPreviewID,
                            previewCount: batch.previews.count
                        )
                        coordinator.resolve(decision)
                    },
                    onCancel: {
                        coordinator.resolve(.rejectAll)
                    },
                    onAlwaysAllowFolder: { fileDecisions in
                        // Remember the common directory so future Ask prompts
                        // for this tree are skipped (durable grants).
                        let acceptedPaths = fileDecisions
                            .filter { $0.value == .accepted }
                            .map { URL(fileURLWithPath: $0.key) }
                        if let dir = PathConfinement.commonDirectory(for: acceptedPaths) {
                            Task {
                                await RememberedGrants.shared.alwaysAllowDirectory(
                                    dir,
                                    projectKey: grantProjectKey
                                )
                            }
                        }
                        let decision = PatchReviewApplyMapping.toPatchDecision(
                            decisions: fileDecisions,
                            pathToPreviewID: pathToPreviewID,
                            previewCount: batch.previews.count
                        )
                        coordinator.resolve(decision)
                    }
                )
            }
    }
}

// MARK: - Orchestrator plan block

/// Collapsible card shown under a user prompt in two-model mode: the plan
/// the orchestrator model produced and handed to the worker. Collapsed by
/// default so it never crowds the transcript, expandable to read the full
/// handoff. Left-aligned and narrower than a message bubble — it reads as
/// a meta annotation on the turn, not a chat message.
private struct OrchestratorPlanView: View {
    let brief: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.Palette.accent)
                    Text("Orchestrator plan")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.Palette.secondary)
                    Text("· handed to worker")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Palette.tertiary)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.Palette.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)

            if expanded {
                Divider().opacity(0.4)
                ScrollView {
                    Text(brief)
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.Palette.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                }
                .frame(maxHeight: 300)
            }
        }
        .background(Theme.Palette.subtle.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
        // Fill the fluid transcript column (no hard 680/720 island).
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - QuestionCardMount

private struct QuestionCardMount: View {
    @ObservedObject var coordinator: UserQuestionCoordinator

    var body: some View {
        if let question = coordinator.pendingQuestion {
            QuestionCardView(
                question: question,
                queuedCount: coordinator.queuedCount
            ) { answer in
                coordinator.resolve(answer: answer)
            }
        }
    }
}
