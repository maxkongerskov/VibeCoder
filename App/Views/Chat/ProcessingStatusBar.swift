//
//  ProcessingStatusBar.swift
//
//  Prompt processing status docked *directly above* the text input card
//  (InputBarViewV2 inside MentionAwareComposer).
//
//  Polished .bar treatment (current default):
//  • Activity / "Responding…" label (no terminal brand mark).
//  • Optional plan progress badge (e.g. "3/6").
//  • Iteration + live elapsed timer (e.g. "· iter 3 · 14s").
//  • Subtle breathing cue while thinking, calmer once streaming.
//  • Very low visual weight, uses subtle surface + restrained motion.
//
//  Always appears while a turn is in flight so the user has persistent
//  context right next to the composer (even if scrolled in the transcript).
//
//  Other styles (.pill, .inline) remain available for special cases.
//

import SwiftUI

struct ProcessingStatusBar: View {
    /// Human label from the loop ("Thinking…", "read_file", "Executing plan…").
    let activityLabel: String?

    /// Detailed status line ("Iteration 3…", "tool: foo ✓").
    let statusLine: String

    /// Visual density / prominence. Start with .bar.
    var style: Style = .bar

    /// Match the input card's max width so everything aligns.
    var maxCardWidth: CGFloat = Theme.ChatLayout.maxContentWidth

    /// Optional: pass true once the first content token has arrived.
    /// Switches the sparkle to the gentler "writing" breathing rhythm.
    var isStreaming: Bool = false

    /// When the current turn (or reasoning) started. Used for live elapsed timer.
    var startedAt: Date? = nil

    /// Optional compact plan progress, e.g. "2/5".
    var planProgress: String? = nil

    /// Iteration badges are off by default — they clutter the chat chrome
    /// without helping the user ("iter 3" next to Working for Ns).
    var showIteration: Bool = false

    enum Style {
        case bar      // subtle strip, best default
        case pill     // more noticeable floating pill
        case inline   // almost no background, for minimalists
    }

    @State private var pulse = false
    @State private var elapsedSeconds: Int = 0

    private var effectiveLabel: String {
        if let act = activityLabel, !act.trimmingCharacters(in: .whitespaces).isEmpty {
            // Make streaming feel more precise once tokens are flowing
            if isStreaming && (act.lowercased().contains("think") || act.lowercased().contains("start")) {
                return "Responding…"
            }
            return act
        }
        if isStreaming { return "Responding…" }
        // Fallbacks from statusLine when activity is not set yet
        if statusLine.lowercased().contains("iteration") { return "Working…" }
        return statusLine.isEmpty ? "Processing…" : statusLine
    }

    private var iterationText: String? {
        guard showIteration else { return nil }
        // Very loose parse — statusLine often looks like "Iteration 3…" or "iter 2/30"
        let lower = statusLine.lowercased()
        if let range = lower.range(of: "iteration ") ?? lower.range(of: "iter ") {
            let tail = lower[range.upperBound...]
            if let num = tail.split(whereSeparator: { !$0.isNumber }).first {
                return "iter \(num)"
            }
        }
        // "3/30" style
        if let m = statusLine.firstMatch(of: #/(\d+)\s*\/\s*\d+/#) {
            return "iter \(m.1)"
        }
        return nil
    }

    private var elapsedLabel: String? {
        if let startedAt {
            let secs = max(1, Int(Date().timeIntervalSince(startedAt)))
            return WorkDurationFormat.shortElapsed(seconds: secs, streaming: true)
        }
        if elapsedSeconds > 0 {
            return WorkDurationFormat.shortElapsed(seconds: elapsedSeconds, streaming: true)
        }
        return nil
    }

    var body: some View {
        Group {
            switch style {
            case .bar: barStyle
            case .pill: pillStyle
            case .inline: inlineStyle
            }
        }
        .frame(maxWidth: maxCardWidth)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: effectiveLabel)
        .animation(.easeOut(duration: 0.2), value: statusLine)
    }

    // MARK: - Style 1: Docked subtle bar (recommended)

    private var barStyle: some View {
        HStack(spacing: 8) {
            // Plan progress (compact, only when relevant)
            if let progress = planProgress {
                Text(progress)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Palette.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.Palette.accent.opacity(0.10))
                    )
            }

            // Primary activity / status label
            Text(effectiveLabel)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.Palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            // Iteration + elapsed metadata, kept tight and secondary
            HStack(spacing: 4) {
                if let iter = iterationText {
                    Text("· \(iter)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                if let elapsed = elapsedLabel {
                    Text("· \(elapsed)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
            }

            Spacer(minLength: 6)

            // Quiet right-side "alive" cue while waiting (no terminal mark).
            if !isStreaming {
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(Theme.Palette.accent.opacity(pulse ? 0.45 : 0.18))
                    .frame(width: 22, height: 1.5)
                    .animation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true),
                               value: pulse)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.subtle.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.Palette.divider.opacity(0.45), lineWidth: 0.5)
        )
        .onAppear { pulse = true }
        .task(id: startedAt) {
            // Reset and drive a live elapsed counter when we have a start date
            elapsedSeconds = 0
            guard startedAt != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                elapsedSeconds += 1
            }
        }
    }

    // MARK: - Style 2: Prominent floating pill

    private var pillStyle: some View {
        HStack(spacing: 8) {
            Text(effectiveLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.primary)

            if let iter = iterationText {
                Text(iter)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Palette.muted))
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Theme.Palette.surface)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
        )
        .overlay(
            Capsule()
                .stroke(Theme.Palette.accent.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Style 3: Ultra-light inline row

    private var inlineStyle: some View {
        HStack(spacing: 8) {
            Text(effectiveLabel)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.Palette.tertiary)
                .lineLimit(1)

            if let iter = iterationText {
                Text("· \(iter)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Palette.mutedFg)
            }

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

// MARK: - Live preview / tuner (like InputBarTuner)

#if DEBUG
struct ProcessingStatusBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 40) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Style: .bar (recommended) — early")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProcessingStatusBar(
                    activityLabel: "Thinking…",
                    statusLine: "Iteration 2…",
                    style: .bar,
                    maxCardWidth: 780,
                    isStreaming: false,
                    startedAt: Date().addingTimeInterval(-7)
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Style: .bar — with plan + tool")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProcessingStatusBar(
                    activityLabel: "read_file",
                    statusLine: "Iteration 4…",
                    style: .bar,
                    maxCardWidth: 780,
                    isStreaming: false,
                    startedAt: Date().addingTimeInterval(-23),
                    planProgress: "2/5"
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Style: .bar — streaming response")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProcessingStatusBar(
                    activityLabel: "Thinking…",
                    statusLine: "Iteration 4…",
                    style: .bar,
                    maxCardWidth: 780,
                    isStreaming: true,
                    startedAt: Date().addingTimeInterval(-31)
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Style: .pill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProcessingStatusBar(
                    activityLabel: "Executing plan…",
                    statusLine: "Iteration 1…",
                    style: .pill,
                    maxCardWidth: 780
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Style: .inline (minimal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProcessingStatusBar(
                    activityLabel: "web_search",
                    statusLine: "Iteration 3…",
                    style: .inline,
                    maxCardWidth: 780
                )
            }

            // How it sits above the real input card (polished bar)
            VStack(spacing: 5) {
                Text("Integrated above InputBarViewV2 (with plan + elapsed)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ProcessingStatusBar(
                    activityLabel: "Executing plan…",
                    statusLine: "Iteration 3…",
                    style: .bar,
                    maxCardWidth: 780,
                    isStreaming: false,
                    startedAt: Date().addingTimeInterval(-14),
                    planProgress: "3/6"
                )

                InputBarViewV2(text: .constant(""), isRunning: true,
                            thinkingEffort: .constant(.off))
                    .frame(width: 780)
            }
        }
        .padding(20)
        .background(Theme.Palette.canvas)
        .frame(width: 860)
        .previewLayout(.sizeThatFits)
    }
}
#endif
