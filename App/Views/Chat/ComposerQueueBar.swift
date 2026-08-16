//
//  ComposerQueueBar.swift
//
//  Visible follow-up queue above the composer field (ZCode: Queued messages).
//

import SwiftUI

struct ComposerQueueBar: View {
    @EnvironmentObject private var app: AppViewModel

    var body: some View {
        if let id = app.selectedConversationID {
            ComposerQueueBarContent(viewModel: app.chatViewModel(for: id))
        }
    }
}

private struct ComposerQueueBarContent: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        if !viewModel.composerQueue.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Queued messages (\(viewModel.composerQueue.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.secondary)

                if viewModel.queuePaused {
                    pausedBanner
                }

                ForEach(Array(viewModel.composerQueue.enumerated()), id: \.element.id) { index, item in
                    queueRow(item, index: index)
                    if index < viewModel.composerQueue.count - 1 {
                        Divider().overlay(Theme.Palette.divider)
                    }
                }
            }
            .padding(.bottom, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Queued messages (\(viewModel.composerQueue.count))")
        }
    }

    private var pausedBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("The queue was paused because you stopped.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Continue") {
                viewModel.continuePausedQueue()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.Palette.accent)
            .help("Send the next queued message")
            .accessibilityLabel("Continue queue")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.Palette.accent.opacity(0.10))
        )
    }

    private func queueRow(_ item: ComposerQueueItem, index: Int) -> some View {
        let isCompact = ComposerQueueStore.isCompactSlash(item.text)
        let lastIndex = viewModel.composerQueue.count - 1
        return HStack(alignment: .center, spacing: 6) {
            VStack(spacing: 0) {
                reorderButton(
                    systemName: "chevron.up",
                    disabled: index == 0,
                    help: "Move up"
                ) {
                    viewModel.moveQueuedItemUp(id: item.id)
                }
                reorderButton(
                    systemName: "chevron.down",
                    disabled: index == lastIndex,
                    help: "Move down"
                ) {
                    viewModel.moveQueuedItemDown(id: item.id)
                }
            }

            Text(item.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.Palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.text)

            HStack(spacing: 8) {
                if viewModel.isRunning && !isCompact {
                    actionButton("Steer") {
                        viewModel.steerQueuedItem(id: item.id)
                    }
                    .help("Inject now on the next agent step")
                }
                actionButton("Run now") {
                    viewModel.runQueuedItemNow(id: item.id)
                }
                .help(isCompact
                      ? "Compress history now"
                      : "Send this follow-up next")
                actionButton("Remove", tint: Theme.Palette.tertiary) {
                    viewModel.removeQueuedItem(id: item.id)
                }
                .help("Remove from queue")
            }
        }
        .padding(.vertical, 2)
    }

    private func reorderButton(
        systemName: String,
        disabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(disabled ? Theme.Palette.tertiary : Theme.Palette.secondary)
                .frame(width: 16, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func actionButton(
        _ title: String,
        tint: Color = Theme.Palette.accent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
