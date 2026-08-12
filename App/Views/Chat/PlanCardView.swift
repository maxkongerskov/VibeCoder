//
//  PlanCardView.swift
//
//  Ported from DEV PLAN (UI Iteration 2 Batch 8).
//  Inline plan card with animated checklist + progress bar.
//

import SwiftUI
import AgentCore

// Plan, Todo, TodoStatus now live in AgentCore (Plan/Plan.swift).
// PlanCardView consumes those types directly — no local mocks.

// MARK: - View

struct PlanCardView: View {
    let plan: Plan
    /// When set, rows are tappable checkboxes (plan review — S2).
    var onToggleTodo: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(plan.todos) { todo in
                    if let onToggleTodo {
                        Button {
                            onToggleTodo(todo.id)
                        } label: {
                            TodoRow(todo: todo, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .help("Mark reviewed / pending")
                    } else {
                        TodoRow(todo: todo, interactive: false)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.Palette.surface.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: plan.isComplete ? "checkmark.circle.fill" : "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(plan.isComplete ? Theme.Palette.success : Theme.Palette.accent)
                Text(plan.isComplete ? "COMPLETE" : "STEPS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Palette.secondary)
                    .tracking(0.5)
                Spacer()
                progressBar
                Text(progressLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.Palette.tertiary)
            }
            // Plan name / goal — the meaningful title (not "create_plan succeeded").
            if !plan.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(plan.goal)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.Palette.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if plan.todos.isEmpty {
                Text("No steps yet — waiting for the agent to list them.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
            }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if plan.todos.isEmpty {
            EmptyView()
        } else {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Palette.mutedFg.opacity(0.35))
                    .frame(width: 70, height: 4)
                Capsule()
                    .fill(plan.isComplete ? Theme.Palette.success : Theme.Palette.accent)
                    .frame(width: 70 * CGFloat(progressFraction), height: 4)
            }
            .animation(.easeOut(duration: 0.25), value: progressFraction)
        }
    }

    private var progressFraction: Double {
        guard !plan.todos.isEmpty else { return 0 }
        let done = plan.todos.filter { $0.status == .done || $0.status == .skipped }.count
        return Double(done) / Double(plan.todos.count)
    }

    private var progressLabel: String {
        let done = plan.todos.filter { $0.status == .done || $0.status == .skipped }.count
        return "\(done)/\(plan.todos.count)"
    }
}

private struct TodoRow: View {
    let todo: Todo
    var interactive: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon
                .frame(width: 14, height: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.text)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .strikethrough(todo.status == .done || todo.status == .skipped,
                                   color: Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let result = todo.result, !result.isEmpty {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18), value: todo.status)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch todo.status {
        case .pending:
            Image(systemName: interactive ? "circle" : "circle")
                .font(.system(size: 12))
                .foregroundColor(Theme.Palette.tertiary)
        case .inProgress:
            if interactive {
                Image(systemName: "circle.dotted").font(.system(size: 12))
                    .foregroundColor(Theme.Palette.accent)
            } else {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                .foregroundColor(Theme.Palette.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                .foregroundColor(Theme.Palette.error)
        case .skipped:
            Image(systemName: "minus.circle").font(.system(size: 12))
                .foregroundColor(Theme.Palette.tertiary)
        }
    }

    private var textColor: Color {
        switch todo.status {
        case .done, .skipped: return Theme.Palette.secondary
        case .failed:         return Theme.Palette.error
        case .inProgress, .pending: return Theme.Palette.primary
        }
    }
}
