//
//  QuestionCardView.swift
//
//  Renders when the agent calls `ask_user` — appears above the input bar,
//  presents the question with optional pre-set answer chips, and always
//  includes a free-text field (matching claude.ai's clarification card
//  pattern). Submitting any answer resumes the suspended agent loop.
//
//  Layout:
//    ┌─────────────────────────────────────────────────┐
//    │  Question text                                  │
//    │                                                 │
//    │  [Option A]  [Option B]  [Option C]             │  ← chips (if options provided)
//    │                                                 │
//    │  ┌───────────────────────────────────────────┐  │
//    │  │  Or type your own answer…              ↵  │  │  ← free-text
//    │  └───────────────────────────────────────────┘  │
//    └─────────────────────────────────────────────────┘
//

import SwiftUI
import AgentCore

struct QuestionCardView: View {
    let question: AgentQuestion
    /// Additional questions waiting behind this one (FIFO). 0 when alone.
    var queuedCount: Int = 0
    /// Called with the user's answer (empty string = dismissed).
    let onAnswer: (String) -> Void

    @State private var customText: String = ""
    @State private var selectedOption: String? = nil
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            if queuedCount > 0 {
                Text(queuedCount == 1
                     ? "1 more question waiting"
                     : "\(queuedCount) more questions waiting")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.Palette.tertiary)
            }

            // Question text
            Text(question.question)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.Palette.primary)
                .fixedSize(horizontal: false, vertical: true)

            // Option chips — only if the model provided them
            if !question.options.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(question.options, id: \.self) { option in
                        OptionChip(
                            label: option,
                            isSelected: selectedOption == option,
                            action: {
                                selectedOption = option
                                customText = ""
                                submit(option)
                            }
                        )
                    }
                }
            }

            // Free-text field — always present
            HStack(spacing: 8) {
                TextField(
                    question.options.isEmpty
                        ? "Type your answer…"
                        : "Or type a custom answer…",
                    text: $customText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundColor(Theme.Palette.primary)
                .focused($textFieldFocused)
                .onSubmit { if !customText.trimmingCharacters(in: .whitespaces).isEmpty { submit(customText) } }

                if !customText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: { submit(customText) }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        textFieldFocused
                            ? Theme.Palette.accent.opacity(0.6)
                            : Theme.Palette.divider,
                        lineWidth: 0.75
                    )
            )
            .animation(.easeOut(duration: 0.15), value: customText.isEmpty)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.Palette.accent.opacity(0.25), lineWidth: 1)
        )
        .onAppear { textFieldFocused = true }
    }

    private func submit(_ answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespaces)
        onAnswer(trimmed)
    }
}

// MARK: - Option chip

private struct OptionChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(isSelected ? .white : Theme.Palette.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected
                              ? Theme.Palette.accent
                              : (hovering
                                 ? Theme.Palette.accent.opacity(0.12)
                                 : Theme.Palette.surface))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            isSelected
                                ? Theme.Palette.accent
                                : Theme.Palette.divider,
                            lineWidth: 0.75
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

// MARK: - FlowLayout (wrapping HStack for chips)
//
// SwiftUI doesn't have a built-in flow/wrap layout. This minimal version
// measures each child and wraps to the next line when width is exceeded.
// Simple: single-pass, left-to-right, top-to-bottom.

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        _ = width
    }
}
