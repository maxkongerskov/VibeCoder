//
//  ContextBreakdownSheet.swift
//
//  Context usage inspector. Primary UX is a hover card on the composer
//  meter pill (see `ContextBreakdownHoverCard`). The sheet form remains
//  available if a full modal is needed elsewhere.
//

import SwiftUI
import AgentCore

// MARK: - Hover card (composer meter)

/// Compact, non-scrolling breakdown shown while the pointer is over the
/// context meter pill (or this card). Dismisses automatically on leave.
struct ContextBreakdownHoverCard: View {
    let breakdown: ContextUsageBreakdown

    var body: some View {
        InputCardPopupChrome(width: InputCardPopupStyle.menuWidth) {
            ContextBreakdownContent(breakdown: breakdown, compact: true)
        }
    }
}

// MARK: - Modal sheet (optional / legacy)

struct ContextBreakdownSheet: View {
    let breakdown: ContextUsageBreakdown
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Context usage")
                        .font(.system(size: 15, weight: .semibold))
                    Text("What is filling the window")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().opacity(0.4)

            ContextBreakdownContent(breakdown: breakdown, compact: false)
                .padding(20)
        }
        .frame(width: 420, alignment: .leading)
        .background(Theme.Palette.canvas)
    }
}

// MARK: - Shared content (no ScrollView — full content always visible)

private struct ContextBreakdownContent: View {
    let breakdown: ContextUsageBreakdown
    /// Tighter typography / spacing for the hover card.
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            if compact {
                Text("Context usage")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primary)
            }

            usedWindowHeadline
            summaryCards
            categoryList
            footerNote
        }
    }

    /// Primary product signal: used / window · window%.
    private var usedWindowHeadline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(breakdown.meterUsedOverWindowLabel)
                .font(.system(size: compact ? 16 : 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.primary)
            Text(breakdown.meterWindowPercentLabel)
                .font(.system(size: compact ? 12 : 13, weight: .medium, design: .monospaced))
                .foregroundStyle(
                    breakdown.isAtOrPastCompact ? Theme.Palette.warning : Theme.Palette.secondary
                )
            Spacer(minLength: 0)
            Text("of window")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.tertiary)
        }
    }

    private var summaryCards: some View {
        HStack(spacing: compact ? 6 : 10) {
            summaryTile(
                title: "Used",
                value: format(breakdown.totalTokens),
                subtitle: "estimated"
            )
            summaryTile(
                title: "Compact at",
                value: format(breakdown.budgetTokens),
                subtitle: "\(Int(breakdown.compactThresholdPercent))% window"
            )
            summaryTile(
                title: "Window",
                value: format(breakdown.windowTokens),
                subtitle: "effective max"
            )
        }
    }

    private func summaryTile(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            Text(title)
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .foregroundStyle(Theme.Palette.tertiary)
            Text(value)
                .font(.system(size: compact ? 15 : 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.primary)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Palette.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 8 : 12)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var categoryList: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text("Breakdown")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.secondary)

            HStack {
                Text(breakdown.isAtOrPastCompact
                     ? "At compact threshold"
                     : "\(format(breakdown.tokensUntilCompact)) until auto-compact")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
                Spacer(minLength: 4)
                Text("\(Int((min(1, breakdown.budgetFraction) * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
            usageBar(
                fraction: min(1, breakdown.budgetFraction),
                color: barColor(for: breakdown.budgetFraction)
            )

            ForEach(breakdown.categories) { cat in
                categoryRow(cat)
            }

            if breakdown.categories.isEmpty {
                Text("No messages yet — context is empty.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
        }
    }

    private func categoryRow(_ cat: ContextUsageBreakdown.Category) -> some View {
        let frac = breakdown.totalTokens > 0
            ? Double(cat.tokens) / Double(breakdown.totalTokens)
            : 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(cat.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.primary)
                Spacer(minLength: 4)
                Text(format(cat.tokens))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Palette.secondary)
                Text(String(format: "%.0f%%", frac * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .frame(width: 36, alignment: .trailing)
            }
            if !cat.detail.isEmpty {
                Text(cat.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            usageBar(fraction: frac, color: Theme.Palette.accent.opacity(0.75), height: 3)
        }
    }

    private func usageBar(fraction: Double, color: Color, height: CGFloat = 6) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(color)
                    .frame(width: max(height, geo.size.width * max(0, min(1, fraction))))
            }
        }
        .frame(height: height)
    }

    private func barColor(for fraction: Double) -> Color {
        if fraction >= 0.95 { return Theme.Palette.error }
        if fraction >= 0.85 { return .orange }
        if fraction >= 0.60 { return Color.yellow.opacity(0.9) }
        return Theme.Palette.accent
    }

    private var footerNote: some View {
        Text(compact
            ? "Estimates ~4 chars/token. Threshold: Settings → Context."
            : "Estimates use ~4 characters per token. Threshold is set in Settings → Context → Auto-compact. Compaction affects the model prompt only — the transcript you see stays full.")
            .font(.system(size: 10))
            .foregroundStyle(Theme.Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func format(_ n: Int) -> String {
        ContextUsageBreakdown.formatTokenCount(n)
    }
}
