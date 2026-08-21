//
//  ChatTitleDropdown.swift
//
//  Popover content for the chat title menu. The caller provides the
//  trigger button and attaches this view via `.popover(isPresented:
//  arrowEdge: .bottom)`. Frame and background are set by the caller.
//
//  Pattern matches DEV PLAN's titleDropdown / DropdownRow family.
//  Helper structs use the `Title` prefix to avoid collisions with any
//  identically-named types in other files.
//

import SwiftUI

enum WorktreeChromeCopy {
    static let isolate = "Isolate work in git worktree"
    static let review = "Review worktree…"
    static let editMain = "Edit main tree…"

    enum IsolatedAction: Equatable {
        case review
        /// Persist `worktreeOptOut` — do not open review / do not discard disk tree.
        case editMain
    }

    static func isolatedActions() -> [IsolatedAction] { [.review, .editMain] }
}

// MARK: - Public dropdown view

struct ChatTitleDropdown: View {
    var onRename: () -> Void
    var onDuplicate: () -> Void
    var onExportMarkdown: () -> Void
    var onCopyMarkdown: () -> Void
    var onEnableWorktree: () -> Void
    var onReviewWorktree: () -> Void
    /// Persist opt-out (edit main checkout). Must not discard the disk worktree.
    var onDisableWorktree: () -> Void
    var worktreeOn: Bool
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {

            // ── Standard actions ─────────────────────────────────────
            TitleDropdownRow(icon: "pencil", label: "Rename",
                             action: onRename)
            TitleDropdownRow(icon: "doc.on.doc", label: "Duplicate",
                             action: onDuplicate)
            TitleDropdownRow(icon: "square.and.arrow.up",
                             label: "Export as Markdown",
                             action: onExportMarkdown)
            TitleDropdownRow(icon: "doc.on.clipboard",
                             label: "Copy as Markdown",
                             action: onCopyMarkdown)

            TitleDropdownDivider()

            // ── Worktree: isolate vs edit-main, review/merge never hidden ──
            if worktreeOn {
                TitleDropdownRow(
                    icon: "doc.text.magnifyingglass",
                    label: WorktreeChromeCopy.review,
                    action: onReviewWorktree
                )
                TitleDropdownRow(
                    icon: "arrow.uturn.backward",
                    label: WorktreeChromeCopy.editMain,
                    action: onDisableWorktree
                )
            } else {
                TitleDropdownRow(
                    icon: "arrow.triangle.branch",
                    label: WorktreeChromeCopy.isolate,
                    action: onEnableWorktree
                )
            }

            TitleDropdownDivider()

            // ── Destructive ──────────────────────────────────────────
            TitleDropdownRow(icon: "trash", label: "Delete",
                             destructive: true, action: onDelete)
        }
        .padding(.vertical, Theme.Spacing.s)
        .frame(width: 260)
        .background(Theme.Palette.subtle)
    }
}

// MARK: - TitleDropdownRow

private struct TitleDropdownRow: View {
    let icon: String
    let label: String
    var destructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 16, alignment: .center)
                Text(label)
                    .font(.system(size: 13, weight: .regular))
                Spacer()
            }
            .foregroundColor(
                destructive ? Theme.Palette.error : Theme.Palette.primary
            )
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 6)
            .background(
                isHovered ? Theme.Palette.hover : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - TitleDropdownDivider

private struct TitleDropdownDivider: View {
    var body: some View {
        Divider()
            .background(Theme.Palette.divider)
            .padding(.vertical, 3)
    }
}

// MARK: - Preview

#Preview("ChatTitleDropdown") {
    ChatTitleDropdown(
        onRename:         { print("rename") },
        onDuplicate:      { print("duplicate") },
        onExportMarkdown: { print("export") },
        onCopyMarkdown:   { print("copy") },
        onEnableWorktree: { print("enable worktree") },
        onReviewWorktree: { print("review worktree") },
        onDisableWorktree: { print("disable worktree") },
        worktreeOn:       true,
        onDelete:         { print("delete") }
    )
    .padding(8)
    .background(Theme.Palette.subtle)
}
