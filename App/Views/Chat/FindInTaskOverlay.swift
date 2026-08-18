//
//  FindInTaskOverlay.swift
//  Wave U2 — compact Find in task bar (messages scope).
//

import SwiftUI

extension Notification.Name {
    /// View → Find in Task (⌘F) and the command-palette `find-in-task` item.
    static let findInTaskRequested = Notification.Name("agentos.findInTask")
}

struct FindInTaskOverlay: View {
    @Binding var query: String
    @Binding var scope: FindInTaskScope
    let currentIndex: Int
    let matchCount: Int
    /// Bumped by ChatView when ⌘F fires while the bar is already open.
    var focusNonce: Int = 0
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClear: () -> Void
    let onClose: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.secondary)
                .accessibilityHidden(true)

            TextField("Find in task", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Typography.ui)
                .foregroundStyle(Theme.Palette.primary)
                .focused($fieldFocused)
                .onSubmit { onNext() }
                .onKeyPress(.upArrow) {
                    onPrevious()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    onNext()
                    return .handled
                }
                .accessibilityLabel("Find in task")

            if !query.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear search")
            }

            scopePicker

            Text(FindInTaskSearch.countLabel(currentIndex: currentIndex, count: matchCount))
                .font(Theme.Typography.mono(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.tertiary)
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
                .accessibilityLabel(FindInTaskSearch.countLabel(currentIndex: currentIndex, count: matchCount))

            findChromeButton(
                systemName: "chevron.up",
                help: "Previous match",
                enabled: matchCount > 0,
                action: onPrevious
            )
            .keyboardShortcut("g", modifiers: [.command, .shift])

            findChromeButton(
                systemName: "chevron.down",
                help: "Next match",
                enabled: matchCount > 0,
                action: onNext
            )
            .keyboardShortcut("g", modifiers: [.command])

            Button("Done", action: onClose)
                .buttonStyle(.plain)
                .font(Theme.Typography.captionEmph)
                .foregroundStyle(Theme.Palette.secondary)
                .help("Close")
                .accessibilityLabel("Close find")
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, 8)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .onAppear { fieldFocused = true }
        .onChange(of: focusNonce) { _, _ in
            fieldFocused = true
        }
        .onExitCommand { onClose() }
        .accessibilityElement(children: .contain)
    }

    private var scopePicker: some View {
        HStack(spacing: 2) {
            ForEach(FindInTaskScope.allCases, id: \.self) { option in
                Button {
                    scope = option
                } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: scope == option ? .semibold : .regular))
                        .foregroundStyle(scope == option ? Theme.Palette.primary : Theme.Palette.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(scope == option ? Theme.Palette.hover : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(scope == option ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find scope")
    }

    private func findChromeButton(
        systemName: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Theme.Palette.secondary : Theme.Palette.tertiary.opacity(0.45))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Current-match chrome (wrap bubbles in ChatView; do not edit MessageBubbleViewV2)

extension View {
    /// Accent wash + stroke when this block is the active Find in task hit.
    func findInTaskCurrentMatch(_ isCurrent: Bool) -> some View {
        modifier(FindInTaskCurrentMatchModifier(isCurrent: isCurrent))
    }
}

private struct FindInTaskCurrentMatchModifier: ViewModifier {
    let isCurrent: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
                    .fill(isCurrent ? Theme.Palette.accent.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
                    .stroke(isCurrent ? Theme.Palette.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
    }
}
