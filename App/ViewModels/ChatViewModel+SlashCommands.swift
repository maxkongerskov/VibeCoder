//
//  ChatViewModel+SlashCommands.swift
//
//  SlashCommandHost + CVM-coupled slash handlers. Parse → route lives in
//  AgentCore.SlashCommandDispatcher; git commit/PR run there too.
//

import Foundation
import AppKit
import AgentCore

extension ChatViewModel: SlashCommandHost {
    var slashWorkingDirectory: URL? {
        conversation.worktreeRootURL ?? conversation.projectRoot
    }

    var slashProjectRoot: URL? {
        conversation.projectRoot ?? conversation.worktreeRootURL
    }

    func slashSetStatusLine(_ text: String) {
        statusLine = text
    }

    func slashNewConversation() {
        NotificationCenter.default.post(name: .newConversationRequested, object: nil)
    }

    func slashClearConversation() {
        clearConversationMessages()
    }

    func slashHome() {
        clearConversationMessages()
        NotificationCenter.default.post(name: .newConversationRequested, object: nil)
    }

    func slashFork() -> String {
        guard let app else {
            return "Cannot fork — app not ready."
        }
        app.duplicateConversation(conversation.id)
        return "Forked conversation (history preserved)."
    }

    func slashRename(to title: String) -> String {
        if let app {
            app.renameConversation(id: conversation.id, to: title)
        } else {
            conversation.title = title
            persistConversation()
        }
        return "Renamed to \"\(title)\"."
    }

    func slashExport() {
        NotificationCenter.default.post(name: .exportConversationRequested, object: conversation.id)
    }

    func slashQuit() {
        NSApp.terminate(nil)
    }

    func slashOpenSettings(pane: String?) {
        NotificationCenter.default.post(name: .settingsRequested, object: pane)
    }

    func slashHistoryPreview() -> String {
        ensurePromptHistoryLoaded()
        if promptHistory.isEmpty {
            return "No prompt history yet. Use ↑ on an empty composer after sending."
        }
        let preview = promptHistory.prefix(8).enumerated()
            .map { "  \($0.offset + 1). \(String($0.element.prefix(80)))" }
            .joined(separator: "\n")
        return "Recent prompts (↑/↓ in empty composer to cycle):\n\(preview)"
    }

    func slashContextUsage() -> String { formatContextUsage() }
    func slashSessionInfo() -> String { formatSessionInfo() }

    func slashCompact(preserve: String) -> SlashCommandResult {
        handleCompact(preserve: preserve)
    }

    func slashUndo() -> SlashCommandResult { handleUndo() }
    func slashRewind() -> SlashCommandResult { handleRewind() }
    func slashRestoreCheckpoint() -> SlashCommandResult { handleRestoreCheckpoint() }
    func slashCopy(nth: String) -> SlashCommandResult { handleCopy(nth: nth) }

    func slashModel(args: String) -> SlashCommandResult { handleModelCommand(args: args) }
    func slashEffort(args: String) -> SlashCommandResult { handleEffortCommand(args: args) }

    func slashPlan(args: String) -> SlashCommandResult { handlePlanCommand(args: args) }
    func slashViewPlan() -> SlashCommandResult { handleViewPlan() }
    func slashApprovePlan() { approvePlanAndContinue() }
    func slashStayPlan() { rejectPlanStayInPlan() }
    func slashToggleAlwaysApprove() -> SlashCommandResult { handleAlwaysApproveToggle() }
    func slashToggleAuto() -> SlashCommandResult { handleAutoToggle() }

    func slashGoal(args: String) -> SlashCommandResult { handleGoalCommand(args: args) }
    func slashRemember(args: String) -> SlashCommandResult { handleRemember(args: args) }
    func slashSkill(args: String) -> SlashCommandResult { handleSkillCommand(args: args) }
    func slashLoop(args: String) -> SlashCommandResult { handleLoopCommand(args: args) }

    func slashHelpText(filter: String) -> String {
        SlashCommandService.helpText(filter: filter)
    }

    func slashExpandCustomCommand(name: String, args: String) -> String? {
        SlashCommandService.expandCustomCommand(
            name: name,
            args: args,
            projectRoot: slashProjectRoot)
    }
}

extension ChatViewModel {
    // MARK: Slash command handlers

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
            await persistConversationSnapshot(self.conversation)
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
                await persistConversationSnapshot(self.conversation)
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
            await persistConversationSnapshot(self.conversation)
        }
        return .handled(message: "Undoing last send (files + conversation)…")
    }

    /// Compress button. Only the selected conversation's VM runs `/compact`.
    func handleCompactConversation(postedConversationID posted: UUID?) {
        if let posted, posted != conversation.id { return }
        if let selected = app?.selectedConversationID, selected != conversation.id {
            return
        }
        let result = handleSlashCommand("/compact")
        if case .handled(let message) = result, let message, !message.isEmpty {
            statusLine = message
        }
    }

    /// Turn-end Undo. Ignores notifications aimed at another conversation.
    func handleTurnRewind(postedConversationID posted: UUID?) {
        if let posted, posted != conversation.id { return }
        let result = handleRewind()
        if case .handled(let message) = result, let message, !message.isEmpty {
            statusLine = message
        }
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
            await persistConversationSnapshot(self.conversation)
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
            await persistConversationSnapshot(conversation)
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
}
