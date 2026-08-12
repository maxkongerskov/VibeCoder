//
//  GoalStatusBanner.swift
//
//  Surfaces goal stall / premature-stop / pause, background jobs (shell +
//  subagents), and transcript notices (context compaction).
//

import SwiftUI
import AgentCore

// MARK: - Goal status

struct GoalStatusBanner: View {
    let statusText: String
    let goalDescription: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Palette.primary)
                    .lineLimit(2)

                if let desc = goalDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(bannerBackground)
    }

    private var statusIcon: String {
        let lower = statusText.lowercased()
        if lower.contains("premature") || lower.contains("still working") {
            return "arrow.triangle.2.circlepath"
        }
        if lower.contains("stall") || lower.contains("no progress") {
            return "exclamationmark.triangle.fill"
        }
        if lower.contains("back") || lower.contains("retr") {
            return "arrow.uturn.backward.circle.fill"
        }
        if lower.contains("user") || lower.contains("paused") {
            return "pause.circle.fill"
        }
        return "info.circle.fill"
    }

    private var iconColor: Color {
        let lower = statusText.lowercased()
        if lower.contains("premature") || lower.contains("still working") {
            return Theme.Palette.accent
        }
        if lower.contains("stall") || lower.contains("no progress") {
            return Theme.Palette.warning
        }
        if lower.contains("back") || lower.contains("retr") {
            return Theme.Palette.warning
        }
        if lower.contains("user") || lower.contains("paused") {
            return Theme.Palette.accent
        }
        return Theme.Palette.tertiary
    }

    private var bannerBackground: Color {
        let lower = statusText.lowercased()
        if lower.contains("stall") || lower.contains("no progress") {
            return Theme.Palette.warning.opacity(0.10)
        }
        if lower.contains("premature") || lower.contains("still working") {
            return Theme.Palette.accent.opacity(0.08)
        }
        return Theme.Palette.subtle.opacity(0.8)
    }
}

// MARK: - Background jobs (shell + subagent)

struct BackgroundJobsBanner: View {
    let jobs: [BackgroundJobSnapshot]
    var onKill: (UUID) -> Void

    private var visible: [BackgroundJobSnapshot] {
        // Subagents are listed *in the transcript* (Z Code style).
        // This banner is only for background *shell* jobs.
        let shell = jobs.filter { $0.kind == .shell }
        let running = shell.filter { $0.status == .running }
        if !running.isEmpty { return running }
        return Array(shell.prefix(4))
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visible, id: \.id) { job in
                    jobRow(job)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.Palette.subtle.opacity(0.75))
        }
    }

    private func jobRow(_ job: BackgroundJobSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kindIcon(job))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor(job.status))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kindLabel(job))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.primary)
                    Text(statusLabel(job.status))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(statusColor(job.status))
                }
                Text(job.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if job.status == .running {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Button {
                    onKill(job.id)
                } label: {
                    Text("Kill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.error)
                }
                .buttonStyle(.plain)
                .help("Terminate this background job")
            }
        }
    }

    private func kindIcon(_ job: BackgroundJobSnapshot) -> String {
        switch job.kind {
        case .shell: return "terminal"
        case .subagent: return "person.2.fill"
        }
    }

    private func kindLabel(_ job: BackgroundJobSnapshot) -> String {
        switch job.kind {
        case .shell: return "Background shell"
        case .subagent: return "Subagent"
        }
    }

    private func statusLabel(_ s: BackgroundJobStatus) -> String {
        switch s {
        case .running: return "Running"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .killed: return "Killed"
        case .timedOut: return "Timed out"
        }
    }

    private func statusColor(_ s: BackgroundJobStatus) -> Color {
        switch s {
        case .running: return Theme.Palette.accent
        case .completed: return Theme.Palette.success
        case .failed, .timedOut: return Theme.Palette.error
        case .killed: return Theme.Palette.warning
        }
    }
}

// MARK: - Transcript notice (compaction)

struct TranscriptNoticeCard: View {
    let notice: TranscriptNotice
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primary)
                Text(notice.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Compaction notices explain what was summarized/elided — keep readable.
                    .lineLimit(notice.kind == .compaction ? 8 : nil)
            }

            Spacer(minLength: 4)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
    }

    private var icon: String {
        switch notice.kind {
        case .compaction: return "rectangle.compress.vertical"
        case .goal: return "flag.fill"
        case .backgroundJob: return "terminal"
        case .userStopped: return "stop.circle"
        case .buildVerify:
            if notice.title.localizedCaseInsensitiveContains("failed") {
                return "xmark.octagon.fill"
            }
            if notice.title.localizedCaseInsensitiveContains("skipped") {
                return "hammer"
            }
            return "checkmark.seal.fill"
        }
    }
}

// MARK: - User stopped generation (under assistant turn)

/// Quiet inline marker under the LLM reply when the user hits Stop.
struct TurnEndedByUserLabel: View {
    let notice: TranscriptNotice
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.secondary)
                if !notice.detail.isEmpty {
                    Text(notice.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
            }

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(notice.title)
    }
}
