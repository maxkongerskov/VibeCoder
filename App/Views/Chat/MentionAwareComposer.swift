//
//  MentionAwareComposer.swift
//
//  Composer with @-mention autocomplete and removable context chips.
//
//  S1: popup lists files / folders / symbols; sticky pins re-inject each turn.
//
//  Width: the input card tracks the live chat column. Prefer the host’s
//  `maxCardWidth` (ChatView passes `Theme.ChatLayout.contentWidth(pane:)`).
//  Also re-measure the pane on resize so a stale default never pins the card
//  while the transcript grows.
//
//  Keyboard: when the @ popup is open — ↑/↓ move highlight, Enter pin,
//  Esc dismiss.
//

import SwiftUI
import AgentCore

/// Preference key for the composer’s available pane width (full detail
/// column, before gutters). Used to recompute fluid content width on resize.
private struct ComposerPaneWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MentionAwareComposer: View {
    @Binding var text: String
    /// One-shot attachments for the next send only.
    @Binding var attachments: [ContextAttachment]
    /// Session sticky pins (re-injected every turn until removed).
    @Binding var stickyPins: [StickyContextPin]
    var projectRoot: URL?
    var onSend: () -> Void = {}
    var isRunning: Bool = false
    var onCancel: () -> Void = {}

    var promptHistory: [String] = []
    var maxCardWidth: CGFloat = Theme.ChatLayout.maxContentWidth
    var sideGutter: CGFloat = 0

    var contextTokens: Int? = nil
    var contextLimit: Int? = nil
    var contextBreakdown: ContextUsageBreakdown? = nil

    var thinkingCapability: ThinkingCapability? = nil
    @Binding var thinkingEffort: ThinkingEffort

    @StateObject private var mentionSearch = MentionSearchCoordinator()
    @State private var measuredPaneWidth: CGFloat = 0

    private var liveColumnWidth: CGFloat {
        if measuredPaneWidth > 0 {
            return Theme.ChatLayout.contentWidth(paneWidth: measuredPaneWidth)
        }
        return maxCardWidth
    }

    private var hasContextChips: Bool {
        !stickyPins.isEmpty || !attachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if mentionSearch.showPopup, !mentionSearch.candidates.isEmpty {
                mentionPopup
                    .chatFluidColumn(width: liveColumnWidth)
                    .padding(.horizontal, sideGutter)
                    .padding(.bottom, 6)
            }

            VStack(spacing: 5) {
                if hasContextChips {
                    contextChipsRow
                        .chatFluidColumn(width: liveColumnWidth)
                        .padding(.horizontal, sideGutter)
                }

                InputBarViewV2(
                    text: $text,
                    attachments: $attachments,
                    onSend: onSend,
                    isRunning: isRunning,
                    onCancel: onCancel,
                    contextTokens: contextTokens,
                    contextLimit: contextLimit,
                    contextBreakdown: contextBreakdown,
                    thinkingCapability: thinkingCapability,
                    thinkingEffort: $thinkingEffort,
                    maxCardWidth: liveColumnWidth,
                    minSideMargin: sideGutter,
                    fontSize: Theme.ChatLayout.bodyFontSize,
                    promptHistory: promptHistory
                )
            }
            .zIndex(1)
        }
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: ComposerPaneWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(ComposerPaneWidthKey.self) { width in
            if abs(width - measuredPaneWidth) > 0.5 {
                measuredPaneWidth = width
            }
        }
        .task(id: projectRoot?.standardizedFileURL.path) {
            guard let root = projectRoot else { return }
            await mentionSearch.warm(root: root)
        }
        .onChange(of: text) { _, newValue in
            Task { await mentionSearch.refresh(text: newValue, root: projectRoot) }
        }
        .onChange(of: projectRoot) { _, newRoot in
            if let root = newRoot {
                Task { await mentionSearch.invalidate(root: root) }
            }
        }
        .focusable()
        .onKeyPress(.upArrow) {
            guard mentionSearch.showPopup else { return .ignored }
            mentionSearch.selectPrevious()
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard mentionSearch.showPopup else { return .ignored }
            mentionSearch.selectNext()
            return .handled
        }
        .onKeyPress(.return) {
            guard mentionSearch.showPopup,
                  let candidate = mentionSearch.selectedCandidate else { return .ignored }
            selectCandidate(candidate)
            return .handled
        }
        .onKeyPress(.escape) {
            guard mentionSearch.showPopup else { return .ignored }
            mentionSearch.dismiss()
            return .handled
        }
    }

    // MARK: - Chips

    private var contextChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(stickyPins) { pin in
                    stickyPinChip(pin)
                }
                ForEach(attachments) { attachment in
                    oneShotChip(attachment)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func stickyPinChip(_ pin: StickyContextPin) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Palette.accent)
            Image(systemName: pin.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)
            Text(pin.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.primary)
                .lineLimit(1)
            Button {
                stickyPins.removeAll { $0.id == pin.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
            .buttonStyle(.plain)
            .help("Unpin (stops re-injecting each turn)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.Palette.accent.opacity(0.12))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.Palette.accent.opacity(0.35), lineWidth: 0.5))
        .help("Sticky pin — included in every turn until removed")
    }

    private func oneShotChip(_ attachment: ContextAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.secondary)
            Text(attachment.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.primary)
                .lineLimit(1)
            if let size = attachment.byteSize {
                Text(byteLabel(size))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.Palette.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.Palette.divider, lineWidth: 0.5))
        .help("Attached for next send only")
    }

    private func byteLabel(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    // MARK: - Popup

    private var mentionPopup: some View {
        InputCardPopupChrome(includePadding: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("@ context — ↑/↓ Enter pin · Esc dismiss")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ForEach(Array(mentionSearch.candidates.enumerated()), id: \.element.id) { index, candidate in
                    let isSelected = index == mentionSearch.selectedIndex
                    Button {
                        selectCandidate(candidate)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: candidate.systemImage)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Palette.accent)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(candidate.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.Palette.primary)
                                        .lineLimit(1)
                                    kindBadge(candidate.kind)
                                }
                                Text(candidate.subtitle)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "pin")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Palette.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? Theme.Palette.accent.opacity(0.12) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if candidate.id != mentionSearch.candidates.last?.id {
                        Divider().opacity(0.35)
                    }
                }
            }
            .padding(6)
        }
    }

    private func kindBadge(_ kind: MentionCandidateKind) -> some View {
        let label: String
        switch kind {
        case .file: label = "file"
        case .folder: label = "folder"
        case .symbol: label = "symbol"
        }
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.Palette.tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.Palette.muted)
            .clipShape(Capsule())
    }

    /// Selecting an @ hit pins it for the session (re-inject every turn).
    private func selectCandidate(_ candidate: MentionCandidate) {
        let pin = StickyContextPin(candidate: candidate)
        if !stickyPins.contains(where: { $0.dedupeKey == pin.dedupeKey }) {
            stickyPins.append(pin)
        }
        // Also keep one-shot attachment for files/symbols so first send
        // is consistent if pins were empty before (compose merges both).
        if candidate.kind == .file || candidate.kind == .symbol {
            let attachment = ContextAttachment(
                path: candidate.path,
                displayName: candidate.displayName,
                byteSize: candidate.byteSize
            )
            if !attachments.contains(where: { $0.path == attachment.path }) {
                attachments.append(attachment)
            }
        }
        // Only strip an @-token at the start of the string or after whitespace.
        // `max@icloud.com` must not be treated as a mention.
        if let range = text.range(of: #"(?:(?<=^)|(?<=\s))@[^\s\n]*$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        mentionSearch.dismiss()
    }
}
