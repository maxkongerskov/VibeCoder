//
//  StickyPlannerView.swift
//
//  Floating plan / todo panel for Chat. Expandable while work is open;
//  dismissible with ✕ (does not delete the plan — just hides the chrome).
//

import SwiftUI
import AgentCore

struct StickyPlannerView: View {
    let plan: Plan
    /// Panel width — derived from `Theme.ChatLayout.contentWidth(pane:)` so
    /// the card tracks the fluid chat column (never wider than the transcript).
    var panelWidth: CGFloat = 320
    /// User closed the panel with ✕.
    var onDismiss: () -> Void = {}
    /// S2: show Approve / Stay when Plan mode awaits user go-ahead.
    var showApprovalActions: Bool = false
    var onApprove: () -> Void = {}
    var onRejectStay: () -> Void = {}
    /// Optional interactive checklist toggles (writes PlanStore via VM).
    var onToggleTodo: ((String) -> Void)? = nil

    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse plan" : "Expand plan")

                Image(systemName: plan.isComplete ? "checkmark.circle.fill" : "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(plan.isComplete ? Theme.Palette.success : Theme.Palette.accent)

                if expanded {
                    // Plan *name* (goal) — never a fake "created a plan" achievement.
                    Text(headerTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if !plan.todos.isEmpty {
                        let done = plan.todos.filter { $0.status == .done || $0.status == .skipped }.count
                        Text("\(done)/\(plan.todos.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.Palette.tertiary)
                        if !plan.isComplete {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                } else {
                    compactSummary
                    Spacer(minLength: 4)
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help("Hide plan")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expanded {
                Divider().opacity(0.4)
                PlanCardView(plan: plan, onToggleTodo: onToggleTodo)
                    .padding(12)

                if showApprovalActions {
                    Divider().opacity(0.4)
                    planApprovalBar
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            }
        }
        .frame(width: panelWidth, alignment: .leading)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.Palette.divider, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .onChange(of: plan.isComplete) { _, complete in
            // When finished, collapse so it stays quiet until dismissed.
            if complete {
                withAnimation(.easeInOut(duration: 0.18)) { expanded = false }
            }
        }
    }

    /// Title bar: goal / plan name, with a quiet complete badge when finished.
    private var headerTitle: String {
        let name = plan.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? "Plan" : name
        if plan.isComplete { return "\(base) · Done" }
        return base
    }

    private var compactSummary: some View {
        let done = plan.todos.filter { $0.status == .done || $0.status == .skipped }.count
        let label: String = {
            if plan.todos.isEmpty {
                return plan.goal.isEmpty ? "Plan" : plan.goal
            }
            if plan.isComplete {
                return "Done · \(plan.todos.count) steps · \(plan.goal)"
            }
            if let cur = plan.todos.first(where: { $0.status == .inProgress }) {
                return "\(done + 1)/\(plan.todos.count) — \(cur.text)"
            }
            return "\(done)/\(plan.todos.count) · \(plan.goal)"
        }()
        return Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.Palette.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Approve → build mode + agent run; Stay → remain in Plan mode (S2).
    private var planApprovalBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review checklist, then Approve to implement (Ask mode) or Stay in Plan.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: onRejectStay) {
                    Text("Stay in Plan")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .help("Keep Plan mode — agent stays read-only")

                Button(action: onApprove) {
                    Text("Approve & Run")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
                .help("Switch to Ask mode and continue the agent on this plan")
            }
        }
    }
}

// MARK: - Stable identity for dismiss / re-show

extension Plan {
    /// Fingerprint so a new plan reappears after the user dismissed an old one.
    var panelIdentity: String {
        let todoKey = todos.map { "\($0.id):\($0.status.rawValue)" }.joined(separator: ",")
        return "\(goal)|\(todoKey)"
    }
}
