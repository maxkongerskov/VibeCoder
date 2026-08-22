//
//  MessageBubbleViewV2.swift
//
//  Transcript:
//    Assistant — full-width column, left-aligned body, Copy under left edge
//    User      — full-width column, right-aligned pill, Copy under right edge
//
//  Same template, opposite edge. Gap between body and Copy is a hard
//  Color.clear frame (not VStack spacing) so SwiftUI cannot collapse it.
//

import SwiftUI
import AppKit
import AgentCore

struct MessageBubbleViewV2: View {
    let message: ChatMessage
    let attachedToolCalls: [ToolCallUIState]
    /// When set (length > 1 or tools keyed per message), render the agent
    /// turn **chronologically**: each assistant iteration is
    /// reasoning → tools → prose, matching Code / Z-Code timeline — not
    /// one giant Thought block above every tool in the run.
    var assistantTurnMessages: [ChatMessage] = []
    var toolsByMessageID: [UUID: [ToolCallUIState]] = [:]
    var isStreaming: Bool = false
    var isActiveTurn: Bool = false
    var fontSize: CGFloat = Theme.ChatLayout.bodyFontSize
    /// Path → prior full file body (from earlier writes) so rewrite cards show red −.
    var priorFileContents: [String: String] = [:]
    var onKillJob: ((UUID) -> Void)? = nil
    var backgroundJobs: [BackgroundJobSnapshot] = []
    /// Hunk ids already rolled back this session (post-apply Undo).
    var rolledBackHunkIDs: Set<UUID> = []
    /// Post-apply Undo for an edit card that reported `hunk_id=…`.
    var onUndoEdit: ((FileCodeEdit) -> Void)? = nil
    /// Presentation filter (Settings → Advanced). Default on.
    var cleanModelChrome: Bool = true

    @State private var isHovered = false

    /// Hard gap between body and Copy (both roles). Not VStack spacing.
    private static var bodyToCopyGap: CGFloat { Theme.ChatLayout.bodyToCopyGap }
    private static var userTurnBottomGap: CGFloat { Theme.ChatLayout.afterUserTurn }
    /// Cap for wrapping — long prompts wrap and grow taller; never clip.
    /// (Was 420 + fixedSize(h:true), which under-reported height and
    /// let assistant prose paint over the pill.)
    private static let maxUserPillWidth: CGFloat = 560
    private static let userLeadingGutter: CGFloat = 96

    var body: some View {
        switch message.role {
        case .user:      userBubble
        case .assistant: assistantBubble
        case .tool, .system: EmptyView()
        }
    }

    // MARK: - User (right-fixed — mirror of assistant)

    private var userBubble: some View {
        // Full-width column. Everything pins to trailing (right).
        // Height always matches the full wrapped text so the next block
        // (assistant) cannot overlap, no matter how long the prompt is.
        VStack(alignment: .trailing, spacing: 0) {

            // 1) Speech pill — right edge, wraps at max width, start of
            //    text always at the top of the pill (never mid-clip).
            HStack(spacing: 0) {
                Spacer(minLength: Self.userLeadingGutter)
                UserSpeechPill(
                    text: message.content,
                    fontSize: fontSize,
                    maxWidth: Self.maxUserPillWidth
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            // 2) Hard vertical gap — cannot collapse (unlike VStack spacing).
            Color.clear
                .frame(height: Self.bodyToCopyGap)
                .frame(maxWidth: .infinity)

            // 3) Copy — same right edge as the column / pill.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                CopyChip(text: message.content)
                    .opacity(isHovered ? 1.0 : 0.7)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.bottom, Self.userTurnBottomGap)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }

    // MARK: - Assistant (left-fixed)

    private var assistantBubble: some View {
        // Prefer chronological multi-iteration layout when ChatView supplies
        // the full assistant run (think → tool → think → tool → answer).
        let useChronological = !assistantTurnMessages.isEmpty
            && (assistantTurnMessages.count > 1
                || toolsByMessageID.keys.count > 1
                || !toolsByMessageID.isEmpty)

        return VStack(alignment: .leading, spacing: 16) {
            // ZCode / BuildCode: one "Worked for …" header for the whole turn.
            if let secs = workDurationForHeader, secs > 0, !isStreaming {
                WorkingHeader(seconds: secs, isLive: false)
            }

            if useChronological {
                chronologicalTurnBody
            } else {
                legacySingleBlobBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.ChatLayout.beforeAssistant)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }

    /// Prefer max duration stamped on any message in the run (live turn
    /// usually stamps the last assistant message).
    private var workDurationForHeader: Int? {
        if !assistantTurnMessages.isEmpty {
            return assistantTurnMessages.compactMap(\.workDurationSeconds).max()
                ?? message.workDurationSeconds
        }
        return message.workDurationSeconds
    }

    // MARK: Chronological (Z-Code / CodeSessionBuilder parity)

    @ViewBuilder
    private var chronologicalTurnBody: some View {
        let run = assistantTurnMessages.isEmpty ? [message] : assistantTurnMessages
        let lastID = run.last?.id

        ForEach(Array(run.enumerated()), id: \.element.id) { _, msg in
            let split = splitContent(msg)
            let tools = toolsByMessageID[msg.id]
                ?? (msg.id == message.id ? attachedToolCalls : [])
            let hasTools = !tools.isEmpty
            let hasAnswer = !split.answer.isEmpty
            // Collapse intermediate thoughts once tools/answer exist for that step.
            let collapseThought = hasTools || hasAnswer || msg.id != lastID

            if let reasoning = split.reasoning, !reasoning.isEmpty {
                ReasoningBlockView(
                    text: reasoning,
                    isStreaming: false,
                    completedDurationSeconds: msg.thinkingDurationSeconds,
                    preferCollapsed: collapseThought,
                    fontSize: fontSize
                )
            }

            if hasTools {
                toolStack(tools)
            }

            // Intermediate "I'll do X" prose stays inline; final answer
            // gets the Copy chip (last non-empty body in the run).
            if hasAnswer {
                let finalAnswerID = run.last(where: {
                    !splitContent($0).answer.isEmpty
                })?.id
                let isFinalAnswer = msg.id == finalAnswerID
                answerBlock(text: split.answer, showCopy: isFinalAnswer && !isStreaming)
            }
        }
    }

    // MARK: Legacy single-message blob (compat)

    @ViewBuilder
    private var legacySingleBlobBody: some View {
        let split = splitContent(message)
        let hasAnswer = !split.answer.isEmpty
        let hasTools = !attachedToolCalls.isEmpty

        if let reasoning = split.reasoning, !reasoning.isEmpty {
            ReasoningBlockView(
                text: reasoning,
                isStreaming: false,
                completedDurationSeconds: message.thinkingDurationSeconds,
                preferCollapsed: hasTools || hasAnswer,
                fontSize: fontSize
            )
        }

        if hasTools {
            toolStack(attachedToolCalls)
        }

        if hasAnswer {
            answerBlock(text: split.answer, showCopy: !isStreaming)
        }
    }

    private struct ContentSplit {
        let reasoning: String?
        let answer: String
    }

    private func splitContent(_ message: ChatMessage) -> ContentSplit {
        let chrome = ModelChrome.present(message.content, enabled: cleanModelChrome)
        let reasoning: String? = {
            if let r = message.reasoningContent, !r.isEmpty { return r }
            return chrome.thinking
        }()
        // Dedicated reasoning channel already holds thought — body is answer only
        // after chrome strip (or raw body when cleanModelChrome is off).
        let answer: String = {
            if message.reasoningContent?.isEmpty == false {
                return ModelChrome.displayBody(message.content, enabled: cleanModelChrome)
            }
            return chrome.body
        }()
        return ContentSplit(reasoning: reasoning, answer: answer)
    }

    @ViewBuilder
    private func toolStack(_ tools: [ToolCallUIState]) -> some View {
        let parts = ChatToolPartition.split(
            tools,
            seedContents: priorFileContents
        )
        if !parts.activity.isEmpty {
            ZCodeActivityStack(
                states: parts.activity,
                isStreaming: isStreaming || isActiveTurn,
                onKillJob: onKillJob,
                backgroundJobs: backgroundJobs
            )
        }
        ForEach(parts.edits) { edit in
            InlineEditCardView(
                edit: edit,
                preferExpanded: edit.status == .running || edit.removedCount > 0,
                isUndone: !edit.hunkIDs.isEmpty
                    && edit.hunkIDs.allSatisfy { rolledBackHunkIDs.contains($0) },
                onUndo: edit.canUndo ? { onUndoEdit?(edit) } : nil
            )
        }
    }

    @ViewBuilder
    private func answerBlock(text: String, showCopy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownTextView(text: text,
                             isStreaming: isStreaming,
                             fontSize: fontSize)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showCopy {
                Color.clear
                    .frame(height: Self.bodyToCopyGap)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 0) {
                    CopyChip(text: text)
                        .opacity(isHovered ? 1.0 : 0.7)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - User speech pill (wrap + full height)

/// Right-aligned user prompt bubble.
///
/// Uses a custom `Layout` so long prompts wrap at `maxWidth` and report
/// their **true** height. The previous `.fixedSize(horizontal: true,
/// vertical: true)` path measured unwrapped ideal size, clipped the
/// text, and left the assistant row sitting on top of the overflow.
private struct UserSpeechPill: View {
    let text: String
    let fontSize: CGFloat
    let maxWidth: CGFloat

    var body: some View {
        WrappingBubbleLayout(maxWidth: maxWidth) {
            Text(text)
                .font(Theme.Typography.body(size: fontSize))
                .foregroundStyle(Theme.Palette.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 16,
                        bottomLeadingRadius: 16,
                        bottomTrailingRadius: 16,
                        topTrailingRadius: 4,
                        style: .continuous
                    )
                    .fill(Theme.Palette.bubbleUser)
                )
                .textSelection(.enabled)
        }
        // Keep the pill on the trailing edge of its slot.
        .frame(maxWidth: maxWidth, alignment: .trailing)
    }
}

/// Single-child layout: propose up to `maxWidth`, size to the child's
/// wrapped fit. Short prompts hug; long prompts wrap and grow downward.
private struct WrappingBubbleLayout: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let limit = maxWidth > 0 ? maxWidth : (proposal.width ?? 0)
        let widthCap = min(limit, proposal.width ?? limit)
        guard widthCap > 0 else {
            return child.sizeThatFits(proposal)
        }
        let fitted = child.sizeThatFits(
            ProposedViewSize(width: widthCap, height: proposal.height)
        )
        // Hug short content; never exceed the wrap cap.
        let width = min(max(fitted.width, 0), widthCap)
        return CGSize(width: width, height: max(fitted.height, 0))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let child = subviews.first else { return }
        child.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

// MARK: - Copy chip

private struct CopyChip: View {
    let text: String
    @State private var didCopy = false
    @State private var hovering = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                Text(didCopy ? "Copied" : "Copy")
                    .font(.system(size: 11))
            }
            .foregroundStyle(didCopy ? Theme.Palette.success : Theme.Palette.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color(NSColor.quaternaryLabelColor).opacity(hovering ? 0.55 : 0.28))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.15)) { didCopy = false }
            }
        }
    }
}
