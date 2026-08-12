//
//  ZCodeStatusBar.swift
//
//  ZCode parity: bottom status bar showing model · provider · mode · tokens.
//  Replaces the minimal `statusPill` with a persistent, info-rich bar
//  docked below the transcript (above the composer).
//

import SwiftUI
import AgentCore

struct ZCodeStatusBar: View {
    @ObservedObject var viewModel: ChatViewModel
    @EnvironmentObject private var app: AppViewModel

    var body: some View {
        // Quiet footer: model · mode · context — never iteration counters.
        HStack(spacing: 10) {
            if let model = currentModel, let backend = currentBackend {
                Text("\(model) · \(backend)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
            } else {
                Text("No model")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
            }

            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.tertiary.opacity(0.5))

            Text(app.executionMode.shortLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.secondary)

            if let tokens = contextTokens, let limit = contextLimit, limit > 0 {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary.opacity(0.5))
                // used / window (same contract as composer meter)
                Text("\(formatTokens(tokens)) / \(formatTokens(limit))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .help(contextHelp)
            }

            Spacer(minLength: 8)

            if app.isLoadingModel {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Loading…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.secondary)
                }
            } else if viewModel.isRunning {
                Text(displayStatus(viewModel.statusLine, running: true))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.secondary)
                    .lineLimit(1)
            } else if !viewModel.statusLine.isEmpty,
                      !isIterationOnlyStatus(viewModel.statusLine) {
                Text(ChatViewModel.humanStatus(viewModel.statusLine))
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            if viewModel.pendingInterjectionCount > 0 {
                Text(viewModel.pendingInterjectionCount == 1
                     ? "Steering"
                     : "Steering ×\(viewModel.pendingInterjectionCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.warning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var contextLimit: Int? {
        // Window (not compact budget) — matches composer used/window meter.
        if let w = viewModel.liveContextWindow, w > 0 { return w }
        return viewModel.contextUsageBreakdown.windowTokens > 0
            ? viewModel.contextUsageBreakdown.windowTokens
            : 32_768
    }

    private var contextHelp: String {
        let b = viewModel.contextUsageBreakdown
        return "~\(formatTokens(b.totalTokens)) / \(formatTokens(b.windowTokens)) window · auto-compact at \(formatTokens(b.budgetTokens)) (\(Int(b.compactThresholdPercent))%)"
    }

    // MARK: - Helpers

    private var currentModel: String? {
        // Prefer live selection over stale conversation id.
        if let id = app.selectedModelID,
           let m = app.availableModels.first(where: { $0.id == id }) {
            return ModelPickerButton.prettyModelName(m.id)
        }
        if let id = viewModel.conversation.modelID,
           let m = app.availableModels.first(where: { $0.id == id }) {
            return ModelPickerButton.prettyModelName(m.id)
        }
        return nil
    }

    private var currentBackend: String? {
        let backend = app.executingRole().map { app.backend(for: $0) } ?? app.currentBackend()
        return backend.identifier.shortLabel
    }

    private var contextTokens: Int? {
        let total = viewModel.liveContextTokens
        return total > 0 ? total : nil
    }

    private var modeIcon: String {
        switch app.executionMode.rawValue.lowercased() {
        case "safe":  return "shield"
        case "build": return "hammer"
        case "edit":  return "pencil.line"
        case "plan":  return "list.bullet.indent"
        default:       return "bolt"
        }
    }

    private var statusColor: Color {
        let lower = viewModel.statusLine.lowercased()
        if lower.contains("error") { return Theme.Palette.error }
        if lower.contains("cancel") { return Theme.Palette.tertiary }
        if lower.contains("paused") { return Theme.Palette.warning }
        return Theme.Palette.tertiary
    }

    private func formatTokens(_ tokens: Int) -> String {
        ContextUsageBreakdown.formatTokenCount(tokens)
    }

    private func isIterationOnlyStatus(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("iteration ") || lower.hasPrefix("iter ")
    }

    private func displayStatus(_ line: String, running: Bool) -> String {
        if line.isEmpty { return running ? "Working…" : "" }
        if isIterationOnlyStatus(line) { return "Working…" }
        return line
    }

    private func statusChip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(color)
    }
}