//
//  ReasoningBlockView.swift
//
//  Collapsible thinking — BuildCode thought chrome:
//  vertical primary-opacity rail beside body, collapsed tick when closed.
//

import SwiftUI
import AgentCore

struct ReasoningBlockView: View {
    let text: String
    var isStreaming: Bool = false
    var startedAt: Date? = nil
    /// Finished thinking wall-clock from `ChatMessage.thinkingDurationSeconds`.
    /// Preferred over `startedAt` for history so we never show message age.
    var completedDurationSeconds: Int? = nil
    /// When true (tools or answer already present), collapse after streaming ends.
    var preferCollapsed: Bool = false
    var fontSize: CGFloat = Theme.ChatLayout.bodyFontSize

    @State private var isExpanded = true
    @State private var userToggled = false
    @State private var elapsedSeconds: Int = 0

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var elapsedSecondsResolved: Int {
        if isStreaming {
            // Prefer wall clock from turn start so remount does not reset to 0.
            if let startedAt {
                let wall = max(1, Int(Date().timeIntervalSince(startedAt)))
                return max(elapsedSeconds, wall)
            }
            return elapsedSeconds
        }
        // History: prefer stamped duration (accurate "Thought for Ns").
        if let completedDurationSeconds, completedDurationSeconds > 0 {
            return completedDurationSeconds
        }
        // Do NOT use startedAt for finished history — callers sometimes pass
        // message.timestamp which yields hours/days of false "Thought for".
        return elapsedSeconds
    }

    private var durationLabel: String {
        if isStreaming && elapsedSecondsResolved <= 0 {
            return "…"
        }
        if !isStreaming && elapsedSecondsResolved <= 0 {
            // No stamp — avoid fake "a few seconds".
            return ""
        }
        // Z-Code: seconds under 1m, then "1 minute" / "N minutes" only.
        return WorkDurationFormat.shortElapsed(
            seconds: elapsedSecondsResolved,
            streaming: isStreaming
        )
    }

    private var headerLabel: String {
        if isStreaming {
            return streamingHeaderLabel
        }
        if durationLabel.isEmpty {
            return "Thought"
        }
        return "Thought for \(durationLabel)"
    }

    private var streamingHeaderLabel: String {
        if elapsedSecondsResolved > 0 {
            return "Thinking · \(durationLabel)"
        }
        return "Thinking"
    }

    /// Show the reasoning body: always while streaming once we have text;
    /// after that respect expand/collapse.
    private var showBody: Bool {
        if isStreaming {
            return hasContent && (userToggled ? isExpanded : true)
        }
        return isExpanded && hasContent
    }

    var body: some View {
        if hasContent || isStreaming {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    userToggled = true
                    withAnimation(Theme.Motion.quick) {
                        isExpanded.toggle()
                    }
                } label: {
                    // BuildCode thought header metrics
                    HStack(spacing: 7) {
                        Image(systemName: "brain")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.85))
                        if isStreaming {
                            ShimmerText(
                                streamingHeaderLabel,
                                font: .system(size: 13, weight: .medium)
                            )
                        } else {
                            Text(headerLabel)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showBody ? 180 : 0))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showBody, hasContent {
                    // Exact BuildCode thought body: 2pt primary rail + prose
                    HStack(alignment: .top, spacing: 10) {
                        BuildCodeDivider.thoughtRail()
                        Text(text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Tokens append in place — animating count flickers the rail.
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else if isStreaming && !hasContent {
                    // Waiting for think tokens — BuildCode collapsed tick
                    BuildCodeDivider.thoughtTick()
                } else if !showBody, hasContent {
                    // Collapsed with content — same tick affordance
                    BuildCodeDivider.thoughtTick()
                }
            }
            .onAppear {
                syncExpandState(animated: false)
            }
            .onChange(of: isStreaming) { _, streaming in
                if streaming {
                    if !userToggled {
                        withAnimation(Theme.Motion.quick) { isExpanded = true }
                    }
                } else {
                    syncExpandState(animated: true)
                }
            }
            .onChange(of: preferCollapsed) { _, _ in
                syncExpandState(animated: true)
            }
            .onChange(of: hasContent) { _, has in
                if has, isStreaming, !userToggled {
                    withAnimation(Theme.Motion.quick) { isExpanded = true }
                }
            }
            .task(id: isStreaming) {
                guard isStreaming else { return }
                // Do not reset elapsedSeconds — remounts were flashing "Thought for 0".
                while !Task.isCancelled && isStreaming {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    elapsedSeconds += 1
                }
            }
        }
    }

    private func syncExpandState(animated: Bool) {
        guard !userToggled else { return }
        let next: Bool
        if isStreaming {
            next = true
        } else if preferCollapsed {
            next = false
        } else {
            next = hasContent
        }
        if animated {
            withAnimation(Theme.Motion.quick) { isExpanded = next }
        } else {
            isExpanded = next
        }
    }
}
