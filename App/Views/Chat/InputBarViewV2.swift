//
//  InputBarViewV2.swift
//
//  Ported from DEV PLAN (UI Iteration 2 Batch 9).
//  Claude.ai-style input card: rounded matte container with text area
//  on top, [+] attach + web toggle on bottom-left, model picker stub +
//  send button on bottom-right.
//
//  Adapted: uses SwiftUI TextEditor instead of DEV PLAN's NativeTextEditor
//  (NSViewRepresentable). Same visual, slightly less polished focus ring.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentCore

struct InputBarViewV2: View {
    @Binding var text: String
    /// Composer file/image attachments (chips). The + button and drag-drop
    /// append here — not as raw path text in the draft.
    /// Defaults to a no-op constant for previews; production passes
    /// `$viewModel.pendingAttachments` via `MentionAwareComposer`.
    var attachments: Binding<[ContextAttachment]> = .constant([])
    var onSend: () -> Void = {}
    /// True when the agent loop is mid-turn. While running, the trailing
    /// button morphs from Send (arrow up) into Cancel (square) so the
    /// user can stop the in-flight turn without leaving the input area.
    var isRunning: Bool = false
    var onCancel: () -> Void = {}

    // ── Context meter (BuildCode-style pill) ───────────────────
    /// Estimated tokens currently in context. nil = not measuring.
    var contextTokens: Int? = nil
    /// Effective model context window (used/window display). Prefer
    /// `contextBreakdown.windowTokens` when a full breakdown is supplied.
    /// nil = not measuring.
    var contextLimit: Int? = nil
    /// Full breakdown for the hover card. nil = pill still shows counts only.
    var contextBreakdown: ContextUsageBreakdown? = nil

    // ── Thinking-effort picker (Phase 1) ───────────────────────
    /// Capability for the active model. nil = model doesn't support
    /// thinking, so the picker stays hidden (non-reasoning models don't
    /// get a misleading toggle).
    var thinkingCapability: ThinkingCapability? = nil
    /// User-chosen effort, bound back to ChatViewModel.
    @Binding var thinkingEffort: ThinkingEffort

    // ── Geometry (BuildCode card dimensions; VibeCoder controls inside) ─
    // Production: MentionAwareComposer / ChatView pass live
    // `Theme.ChatLayout.contentWidth(paneWidth:)` so the card tracks the
    // transcript column (grows with the window, soft-capped at maxContentWidth).
    // Do not leave the default in place for chat — it only exists for previews.
    var maxCardWidth:     CGFloat = Theme.ChatLayout.maxContentWidth
    /// Extra pad outside the fixed card width. Prefer 0 when maxCardWidth is
    /// already a contentWidth (gutters baked in). Non-zero only for special layouts.
    var minSideMargin:    CGFloat = 0
    var cardHeight:       CGFloat = Theme.ChatLayout.inputCardMinHeight // legacy alias
    var topPad:           CGFloat = Theme.ChatLayout.inputVerticalPad
    var bottomPad:        CGFloat = Theme.ChatLayout.inputVerticalPad
    var horizontalInset:  CGFloat = Theme.ChatLayout.inputHorizontalInset
    var fontSize:         CGFloat = Theme.ChatLayout.bodyFontSize
    var liftFromBottom:   CGFloat = Theme.ChatLayout.inputBottomLift
    var cardCornerRadius: CGFloat = Theme.ChatLayout.inputCornerRadius
    var cardMinHeight:    CGFloat = Theme.ChatLayout.inputCardMinHeight

    @State private var cardHovering = false
    /// True while the user is dragging files over the input card.
    /// Drives a subtle accent border tint as drop affordance.
    @State private var isDropTarget = false

    /// ZCode parity: prompt history for ↑/↓ arrow cycling. Supplied
    /// by ChatViewModel (shared, persisted across conversations).
    var promptHistory: [String] = []
    /// Current index in `promptHistory` when navigating with ↑/↓.
    /// -1 = not navigating (draft mode). 0 = most recent prompt.
    @State private var historyIndex: Int = -1
    /// Snapshot of the user's in-progress draft, restored when they exit
    /// history navigation (↓ past the end, or Esc).
    @State private var draftSnapshot: String = ""
    /// Highlighted row in the slash-command autocomplete menu.
    @State private var slashHighlightIndex: Int = 0
    /// Hover state for the context-meter breakdown card (pill or card).
    @State private var contextPillHovered = false
    @State private var contextCardHovered = false
    @State private var showContextHoverCard = false
    @State private var contextHoverDismissTask: Task<Void, Never>? = nil
    @EnvironmentObject private var app: AppViewModel
    @FocusState private var focused: Bool

    /// Live slash-command matches for the current draft (empty when not drafting `/…`).
    private var slashMatches: [SlashCommand] {
        SlashCommandService.matchingCommands(
            draft: text,
            limit: 10,
            projectRoot: app.openedProject?.url
        )
    }

    private var showSlashMenu: Bool {
        !slashMatches.isEmpty
    }

    /// Bridge `app.selectedModelID` (optional `String?`) to the picker's
    /// non-optional `String` binding. When nothing's selected we pass an
    /// empty id — the picker then honestly shows "No model" rather than a
    /// fabricated default.
    private var modelIDBinding: Binding<String> {
        Binding(
            get: { app.selectedModelID ?? "" },
            set: { app.selectedModelID = $0.isEmpty ? nil : $0 }
        )
    }

    /// Compact two-model indicator: "orchestrator → worker", read-only.
    /// Models are chosen in the sidebar Agents panel; this reflects what
    /// will ACTUALLY run — the "→" arrow appears only for a genuine
    /// two-distinct-model handoff. When two-model mode is on but only one
    /// model is effectively active (same model on both roles, or one role
    /// is None), it honestly shows a single-model pill so the surface is
    /// never misleadingly "two models".
    @ViewBuilder
    private var twoModelIndicator: some View {
        if app.orchestrationActive {
            let orch = ModelPickerButton.prettyModelName(app.settings.orchestratorModelID)
            let work = ModelPickerButton.prettyModelName(app.settings.workerModelID)
            indicatorPill(icon: "person.2.fill",
                          iconColor: Theme.Palette.accent,
                          text: "\(orch) → \(work)",
                          help: "Two-model mode: orchestrator → worker. Change models in the sidebar Agents panel.")
        } else {
            // Single model effectively running (worker preferred, else orchestrator).
            let workerSet = app.settings.workerBackendSet && !app.settings.workerModelID.isEmpty
            let id = workerSet ? app.settings.workerModelID : app.settings.orchestratorModelID
            indicatorPill(icon: "person.fill",
                          iconColor: Theme.Palette.warning,
                          text: "\(ModelPickerButton.prettyModelName(id)) · 1 model",
                          help: "Two-model mode is on, but only one model is active. Add a second, different model in the sidebar Agents panel for a real handoff.")
        }
    }

    private func indicatorPill(icon: String, iconColor: Color, text: String, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(iconColor)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .help(help)
    }

    /// The web-search chip drives the REAL `web_search` tool — synced with
    /// Settings → Tools (missing key = enabled by default, matching
    /// ToolsSettingsView). Previously this was a dead `@State` the agent
    /// loop never read, so toggling it did nothing.
    private var webSearchBinding: Binding<Bool> {
        Binding(
            get: { app.settings.toolEnabled["web_search"] ?? true },
            set: { newValue in app.persistSettings { $0.toolEnabled["web_search"] = newValue } }
        )
    }

    /// Chat mode (`settings.rawMode`) vs Agent mode. Wired through
    /// `AgentRunBootstrap` → `AgentLoop.Configuration.rawMode`.
    private var chatModeBinding: Binding<Bool> {
        Binding(
            get: { app.settings.rawMode },
            set: { on in app.persistSettings { $0.rawMode = on } }
        )
    }

    // MARK: - Context meter helper methods

    /// Effective window for used/window math (prefer live breakdown).
    private var meterWindow: Int {
        if let w = contextBreakdown?.windowTokens, w > 0 { return w }
        return contextLimit ?? 0
    }

    /// Whether the context meter should be shown.
    private var showContextMeter: Bool {
        guard let tokens = contextTokens, tokens > 0, meterWindow > 0 else { return false }
        return true
    }

    /// Fraction of the **window** used (0.0 to 1.0+).
    private var contextWindowFraction: Double {
        guard let tokens = contextTokens, meterWindow > 0 else { return 0 }
        return Double(tokens) / Double(meterWindow)
    }

    /// Fraction toward auto-compact budget (drives color / “compact” state).
    private var contextBudgetFraction: Double {
        if let b = contextBreakdown {
            return b.budgetFraction
        }
        // Fallback: treat window as the limit when breakdown is unavailable.
        return contextWindowFraction
    }

    /// Color: pressure toward auto-compact budget (green / yellow / orange).
    private var contextColor: Color {
        let fraction = contextBudgetFraction
        if fraction > 0.85 { return .orange }
        if fraction > 0.60 { return Color.yellow.opacity(0.85) }
        return Theme.Palette.accent
    }

    /// Formatted token count (e.g., "12.3k").
    private func formatTokens(_ count: Int) -> String {
        ContextUsageBreakdown.formatTokenCount(count)
    }

    /// Quiet context meter: used / window · window%.
    /// e.g. "12.3k / 128k · 10%" — hover for category breakdown + compact budget.
    private var contextMeterPill: some View {
        let used = contextTokens ?? 0
        let window = meterWindow
        let windowFrac = contextWindowFraction
        let budgetFrac = contextBudgetFraction
        let pastCompact = contextBreakdown?.isAtOrPastCompact
            ?? (budgetFrac >= 1)
        let pctLabel = pastCompact
            ? "compact"
            : "\(Int((min(1, windowFrac) * 100).rounded()))%"
        let usedOverWindow = "\(formatTokens(used)) / \(formatTokens(window))"
        let remainingToCompact: Int = {
            if let b = contextBreakdown { return b.tokensUntilCompact }
            return max(0, window - used)
        }()

        return HStack(spacing: 6) {
            // Mini fill of the **window** (what the model can hold).
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 28, height: 5)
                Capsule()
                    .fill(contextColor)
                    .frame(width: max(3, 28 * min(1, windowFrac)), height: 5)
            }
            Text(usedOverWindow)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.secondary)
                .monospacedDigit()
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.tertiary)
            Text(pctLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    showContextHoverCard ? Theme.Palette.accent : Theme.Palette.secondary
                )
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // Flat like mode / thinking chips — no permanent filled capsule.
        .background(
            Capsule().fill(
                showContextHoverCard
                    ? Theme.Palette.accent.opacity(0.12)
                    : Color.clear
            )
        )
        .contentShape(Capsule())
        .accessibilityLabel("Context \(usedOverWindow), \(pctLabel) of window")
        .onHover { hovering in
            updateContextHover(pill: hovering)
        }
        // Anchor a zero-height frame at the *top* of the pill; content aligns
        // to that frame’s bottom so the card grows *upward* into free space
        // above the input bar (never below the window edge).
        .overlay(alignment: .topLeading) {
            if showContextHoverCard, let breakdown = contextBreakdown {
                ContextBreakdownHoverCard(breakdown: breakdown)
                    .fixedSize()
                    .padding(.bottom, 8) // air between card bottom and pill top
                    .frame(height: 0, alignment: .bottom)
                    .onHover { hovering in
                        updateContextHover(card: hovering)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomLeading)))
            }
        }
        .zIndex(showContextHoverCard ? 50 : 0)
        .animation(.easeOut(duration: 0.12), value: showContextHoverCard)
        .help(meterHelpText(
            pastCompact: pastCompact,
            remainingToCompact: remainingToCompact,
            window: window,
            used: used
        ))
    }

    private func meterHelpText(
        pastCompact: Bool,
        remainingToCompact: Int,
        window: Int,
        used: Int
    ) -> String {
        let base = "~\(formatTokens(used)) of \(formatTokens(window)) context window"
        if contextBreakdown == nil {
            return base
        }
        if pastCompact {
            return "\(base). At auto-compact budget. Hover for breakdown."
        }
        return "\(base). \(formatTokens(remainingToCompact)) until auto-compact. Hover for breakdown."
    }

    /// Coordinated hover for pill + card with a short grace period so the
    /// pointer can travel the gap without the card vanishing.
    private func updateContextHover(pill: Bool? = nil, card: Bool? = nil) {
        if let pill { contextPillHovered = pill }
        if let card { contextCardHovered = card }

        let inside = contextPillHovered || contextCardHovered
        contextHoverDismissTask?.cancel()
        if inside {
            guard contextBreakdown != nil else { return }
            showContextHoverCard = true
            return
        }
        contextHoverDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000) // 140ms grace
            guard !Task.isCancelled else { return }
            if !contextPillHovered && !contextCardHovered {
                showContextHoverCard = false
            }
        }
    }

    /// Posts `compactConversationRequested`; ChatViewModel runs `/compact`.
    private var compressHistoryButton: some View {
        Button {
            NotificationCenter.default.post(
                name: .compactConversationRequested,
                object: app.selectedConversationID
            )
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10, weight: .medium))
                Text("Compress")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.Palette.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Compress history (/compact)")
        .accessibilityLabel("Compress")
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// ZCode parity: navigate prompt history with ↑/↓ arrows.
    /// direction -1 = older (up), +1 = newer (down).
    private func navigateHistory(direction: Int) -> KeyPress.Result {
        // No history or empty text field — nothing to cycle.
        guard !promptHistory.isEmpty else { return .ignored }

        // First time entering history navigation: snapshot the draft.
        if historyIndex == -1 {
            draftSnapshot = text
            if direction < 0 {
                // ↑ from a fresh field loads the most recent prompt.
                historyIndex = 0
            } else {
                // ↓ from a fresh field does nothing (nothing to go "down" to).
                return .ignored
            }
        } else {
            let newIndex = historyIndex + direction
            if newIndex < 0 {
                // Can't go further back.
                return .handled
            }
            if newIndex >= promptHistory.count {
                // ↓ past the end: restore the in-progress draft.
                historyIndex = -1
                text = draftSnapshot
                return .handled
            }
            historyIndex = newIndex
        }

        // Clamp safety.
        if historyIndex >= 0 && historyIndex < promptHistory.count {
            text = promptHistory[historyIndex]
        }
        return .handled
    }

    /// Reset history navigation when the text changes by means other than
    /// arrow keys (e.g., user types, or send() clears the field).
    private func resetHistoryNavigation() {
        historyIndex = -1
        draftSnapshot = ""
    }

    var body: some View {
        // BuildCode outer dimensions; VibeCoder toolbar stays fully featured:
        // + · mode · web · bare/no-harness · context | thinking · model · send/cancel
        VStack(alignment: .leading, spacing: 10) {
            ComposerQueueBar()

            if showSlashMenu {
                slashCommandMenu
            }

            TextField(
                isRunning ? "Keep typing to queue…" : "Ask for follow-up changes",
                text: $text,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .hidesSystemFocusRing()
            .font(Theme.Typography.body(size: fontSize))
            .foregroundStyle(Theme.Palette.primary)
            .lineLimit(1 ... Theme.ChatLayout.inputEditorMaxLines)
            .frame(minHeight: Theme.ChatLayout.inputEditorMinHeight, alignment: .topLeading)
            .frame(maxHeight: Theme.ChatLayout.inputEditorMaxHeight, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .focused($focused)
            .onKeyPress(.return) {
                if NSEvent.modifierFlags.contains(.shift) {
                    text += "\n"
                    return .handled
                }
                // Tab-like accept for slash autocomplete when a row is highlighted.
                if showSlashMenu, acceptSlashHighlight() {
                    return .handled
                }
                if canSend { onSend() }
                return .handled
            }
            .onKeyPress(.tab) {
                if showSlashMenu, acceptSlashHighlight() {
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.upArrow) {
                if showSlashMenu {
                    slashHighlightIndex = max(0, slashHighlightIndex - 1)
                    return .handled
                }
                return navigateHistory(direction: -1)
            }
            .onKeyPress(.downArrow) {
                if showSlashMenu {
                    slashHighlightIndex = min(slashMatches.count - 1, slashHighlightIndex + 1)
                    return .handled
                }
                return navigateHistory(direction: 1)
            }
            .onKeyPress(.escape) {
                if showSlashMenu {
                    // Dismiss slash draft — clear leading command token.
                    text = ""
                    return .handled
                }
                return .ignored
            }
            .onChange(of: text) { _, newValue in
                if !SlashCommandService.isSlashDraft(newValue) {
                    slashHighlightIndex = 0
                } else {
                    // Keep highlight in range when filter shrinks.
                    let count = SlashCommandService.matchingCommands(
                        draft: newValue,
                        limit: 10,
                        projectRoot: app.openedProject?.url
                    ).count
                    if slashHighlightIndex >= count {
                        slashHighlightIndex = max(0, count - 1)
                    }
                }
            }

            // Toolbar — all VibeCoder controls preserved, BuildCode spacing.
            HStack(alignment: .center, spacing: 8) {
                // Attach
                Button { presentFilePicker() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Attach files, images, or folders (or drop them on the card). Images are sent to vision models.")

                // Primary: execution mode
                ExecutionModeChip(
                    mode: Binding(
                        get: { app.executionMode },
                        set: { app.executionMode = $0 }
                    ),
                    isRunning: isRunning
                )

                // Secondary: web search (labels only when active).
                WebSearchToggle(on: webSearchBinding)

                // Chat vs Agent — chat = no harness, web + read only.
                ChatAgentModeToggle(chatMode: chatModeBinding)

                if showContextMeter {
                    contextMeterPill
                    compressHistoryButton
                }

                Spacer(minLength: 8)

                // Brain chip: Off / Low / Medium / High / Max when the
                // active model is a known reasoning family (scanner).
                ThinkingEffortPicker(
                    capability: thinkingCapability,
                    effort: $thinkingEffort,
                    isRunning: isRunning
                )
                .disabled(isRunning)
                .layoutPriority(1)

                if app.twoModelEnabled, app.executingRole() != nil {
                    twoModelIndicator
                } else {
                    ModelPickerButton(selectedModelID: modelIDBinding)
                }

                // BuildCode-style: Send morphs into Stop while a turn is live.
                SendStopButton(
                    isRunning: isRunning,
                    canSend: canSend,
                    onSend: onSend,
                    onStop: onCancel
                )
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, topPad)
        // BuildCode resting thickness + full card width before chrome.
        .frame(maxWidth: .infinity, minHeight: cardMinHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(Theme.Palette.subtle)
                .shadow(
                    color: Color.black.opacity(focused ? 0.12 : 0.10),
                    radius: focused ? 18 : 12,
                    y: focused ? 8 : 5
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(
                    // Neutral hairline only — no orange/accent focus ring.
                    // Drop target keeps a soft primary lift so files still feel catchable.
                    isDropTarget
                        ? Color.primary.opacity(0.18)
                        : Color.primary.opacity(cardHovering || focused ? 0.10 : 0.08),
                    lineWidth: isDropTarget ? 1.25 : 1
                )
        )
        // Hard width + center — same helper as transcript so resize tracks.
        // maxCardWidth must be live contentWidth from MentionAwareComposer/ChatView.
        .chatFluidColumn(width: maxCardWidth)
        .onHover { cardHovering = $0 }
        .animation(.easeOut(duration: 0.18), value: focused)
        .animation(.easeOut(duration: 0.15), value: cardHovering)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .animation(.easeOut(duration: 0.12), value: maxCardWidth)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers: providers)
            return true
        }
        // Optional extra pad; prefer 0 when width is already contentWidth.
        .padding(.horizontal, minSideMargin)
        .padding(.bottom, liftFromBottom)
        // Lift the whole composer above the transcript while the context
        // hover card is open so the upward popup paints over chat content.
        .zIndex(showContextHoverCard ? 80 : 0)
        .onAppear { focused = true }
    }

    // MARK: - Slash command autocomplete

    @ViewBuilder
    private var slashCommandMenu: some View {
        InputCardPopupChrome(includePadding: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(slashMatches.enumerated()), id: \.element.id) { index, cmd in
                    Button {
                        applySlashCommand(cmd)
                    } label: {
                        HStack(spacing: 10) {
                            Text(cmd.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.Palette.primary)
                                .frame(minWidth: 110, alignment: .leading)
                            if !cmd.argumentHint.isEmpty {
                                Text(cmd.argumentHint)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.tertiary)
                                    .lineLimit(1)
                            }
                            Text(cmd.description)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Palette.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(index == slashHighlightIndex
                                      ? Theme.Palette.hover
                                      : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
    }

    /// Insert the selected command into the draft (with trailing space when it takes args).
    @discardableResult
    private func acceptSlashHighlight() -> Bool {
        guard showSlashMenu,
              slashHighlightIndex >= 0,
              slashHighlightIndex < slashMatches.count
        else { return false }
        applySlashCommand(slashMatches[slashHighlightIndex])
        return true
    }

    private func applySlashCommand(_ cmd: SlashCommand) {
        // Commands with no args run immediately on Enter after selection;
        // leave a trailing space when args are expected so the user can type them.
        if cmd.argumentHint.isEmpty {
            text = cmd.name
        } else {
            text = cmd.name + " "
        }
        slashHighlightIndex = 0
    }

    // MARK: - File attach (+ button and drag-drop)

    /// Open NSOpenPanel and append the user's chosen paths to the
    /// input. Supports both files and folders, multi-select.
    private func presentFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "Attach files or folders"
        panel.prompt = "Attach"
        if panel.runModal() == .OK {
            appendPaths(panel.urls)
        }
    }

    /// Async loader for the URLs carried by dropped `NSItemProvider`s.
    /// Each provider can return either a `URL` directly or a `Data`
    /// representation of a URL — Finder uses the latter on file drops.
    private func handleDrop(providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadDroppedURL(from: provider) {
                    urls.append(url)
                }
            }
            await MainActor.run { appendPaths(urls) }
        }
    }

    private func loadDroppedURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Attach chosen files/folders as real `ContextAttachment` chips so
    /// send → `composeMultimodal` can inline text files and encode images
    /// for vision. Paths are **not** dumped into the draft as plain text
    /// (that left the model path-only with no pixels).
    private func appendPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        var next = attachments.wrappedValue
        for url in urls {
            let path = url.path
            guard !next.contains(where: { $0.path == path }) else { continue }
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: path, isDirectory: &isDir)
            let size: Int? = {
                guard !isDir.boolValue,
                      let attrs = try? fm.attributesOfItem(atPath: path),
                      let n = attrs[.size] as? NSNumber else { return nil }
                return n.intValue
            }()
            next.append(ContextAttachment(
                path: path,
                displayName: url.lastPathComponent,
                byteSize: size
            ))
        }
        attachments.wrappedValue = next
        focused = true
    }
}

// MARK: - Toolbar icon chips (fixed size — no reflow when toggled)

/// Shared footprint for Web / Bare so toggling never pushes the context meter.
private enum InputToolbarChip {
    static let size: CGFloat = 26
}

// MARK: - Web search toggle

private struct WebSearchToggle: View {
    @Binding var on: Bool
    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { on.toggle() }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Theme.Palette.accent : Theme.Palette.tertiary)
                .frame(width: InputToolbarChip.size, height: InputToolbarChip.size)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(on ? Theme.Palette.accent.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Web search on — click to disable" : "Enable web search")
        .accessibilityLabel(on ? "Web search on" : "Web search off")
    }
}

// MARK: - Chat / Agent mode toggle

/// Toggles `AppSettings.rawMode` (chat vs agent) from the composer.
///
/// - **Chat** (on): no harness / pre-prompts; tools limited to web search
///   and `read_file` (document read). Attachments still inline into the message.
/// - **Agent** (off, default): full harness + full tool surface.
/// Same setting as Settings → Tools → "Chat mode".
private struct ChatAgentModeToggle: View {
    @Binding var chatMode: Bool
    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { chatMode.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chatMode ? "bubble.left.and.bubble.right" : "wrench.and.screwdriver")
                    .font(.system(size: 11, weight: .medium))
                Text(chatMode ? "Chat" : "Agent")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(chatMode ? Theme.Palette.accent : Theme.Palette.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    chatMode
                        ? Theme.Palette.accent.opacity(0.12)
                        : Color.clear
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(chatMode
            ? "Chat mode — no agent harness. Only web search + read file. Click for Agent mode."
            : "Agent mode — full harness, tools, and project rules. Click for Chat mode.")
        .accessibilityLabel(chatMode ? "Chat mode" : "Agent mode")
    }
}

// MARK: - Send / Stop (BuildCode parity)

/// Trailing control:
/// - Idle: Send (arrow) when draft non-empty
/// - Running: Stop always (Esc / red square); draft Send **queues** a follow-up.
private struct SendStopButton: View {
    let isRunning: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        if isRunning {
            HStack(spacing: 8) {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.red.opacity(0.9)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Stop generation")
                .accessibilityLabel("Stop")

                if canSend {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.Palette.accent))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Queue message")
                    .accessibilityLabel("Queue message")
                }
            }
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Theme.Palette.tertiary.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(
                            canSend
                                ? Theme.Palette.accent
                                : Color.primary.opacity(0.08)
                        )
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send message")
            .accessibilityLabel("Send")
        }
    }
}

// MARK: - Live tuning preview
//
// Open this file in Xcode → press ⌥⌘↩ to show the canvas → click the
// "Selectable" / play button so sliders are interactive. Drag the
// sliders and the card resizes instantly. When you find numbers you
// like, copy them into the defaults at the top of `InputBarViewV2`
// (topPad, bottomPad, fontSize, horizontalPad, liftFromBottom).
//
// This preview ONLY affects the canvas — it does not change runtime
// behaviour. Production `InputBarViewV2(text:)` callers continue to
// use the defaults.

#if DEBUG
private struct InputBarTuner: View {
    @State private var text = ""
    @State private var maxCardWidth:  CGFloat = Theme.ChatLayout.maxContentWidth
    @State private var cardHeight:    CGFloat = 110
    @State private var topPad:        CGFloat = 14
    @State private var bottomPad:     CGFloat = 12
    @State private var horizontalInset: CGFloat = 16
    @State private var fontSize:      CGFloat = 15
    @State private var liftFromBottom: CGFloat = 24
    @State private var cornerRadius:  CGFloat = 20
    // Phase 1: drive a real thinking-capability binding so the tuner
    // exercises the same picker path as production. GLM-5 has 3 levels.
    @State private var thinkingEffort: ThinkingEffort = .high
    private let thinkingCap: ThinkingCapability? =
        ThinkingModelScanner.detect(modelId: "glm-5.2-mxfp4")

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            InputBarViewV2(
                text: $text,
                thinkingCapability: thinkingCap,
                thinkingEffort: $thinkingEffort,
                maxCardWidth: maxCardWidth,
                cardHeight: cardHeight,
                topPad: topPad,
                bottomPad: bottomPad,
                horizontalInset: horizontalInset,
                fontSize: fontSize,
                liftFromBottom: liftFromBottom,
                cardCornerRadius: cornerRadius
            )

            VStack(alignment: .leading, spacing: 8) {
                tunerRow("maxCardWidth",    value: $maxCardWidth,    range: 320...1200)
                tunerRow("cardHeight",      value: $cardHeight,      range: 60...260)
                tunerRow("topPad",          value: $topPad,          range: 0...60)
                tunerRow("bottomPad",       value: $bottomPad,       range: 0...40)
                tunerRow("horizontalInset", value: $horizontalInset, range: 4...40)
                tunerRow("fontSize",        value: $fontSize,        range: 10...22)
                tunerRow("liftFromBottom",  value: $liftFromBottom,  range: 0...120)
                tunerRow("cornerRadius",    value: $cornerRadius,    range: 0...32)
            }
            .padding(16)
            .background(Theme.Palette.muted)
        }
        .frame(width: 1400, height: 900)
        .background(Theme.Palette.canvas)
    }

    @ViewBuilder
    private func tunerRow(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.Palette.secondary)
                .frame(width: 130, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.Palette.primary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

#Preview("Tune Input Card") {
    InputBarTuner()
}
#endif
