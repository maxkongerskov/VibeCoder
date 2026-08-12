//
//  InlineEditCardView.swift
//
//  Z Code–style expandable file-edit card for the Chat transcript.
//  Collapsed by default: path · status · +N −M · chevron.
//  Expanded: green/red diff lines (reuses CodeDiffBlock).
//
//  Post-apply Undo: when the tool result includes hunk_id=… and the
//  edit succeeded, an Undo button calls HunkTracker.reject via the host.
//

import SwiftUI
import AgentCore

/// One file edit shown inline in Chat (not the right rail).
struct InlineEditCardView: View {
    let edit: FileCodeEdit
    /// When true, card starts expanded (e.g. still running).
    var preferExpanded: Bool = false
    /// True after a successful session-local undo (hides Undo / shows Undone).
    var isUndone: Bool = false
    /// Invoked when the user taps Undo (host runs HunkTracker.reject).
    var onUndo: (() -> Void)? = nil

    @State private var isOpen: Bool = false
    @State private var undoBusy: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isOpen.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            )
                            .rotationEffect(.degrees(isOpen ? 0 : -90))

                        if edit.status == .failure {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.Palette.error)
                                .frame(width: 16)
                        }

                        Text(edit.shortPath)
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.Palette.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 8)

                        Text(isUndone ? "Undone" : edit.statusLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(
                                edit.status == .failure
                                    ? Theme.Palette.error
                                    : Theme.Palette.tertiary
                            )

                        HStack(spacing: 8) {
                            if edit.addedCount > 0, !isUndone {
                                Text("+\(edit.addedCount)")
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.diffAdd)
                            }
                            if edit.removedCount > 0, !isUndone {
                                Text("−\(edit.removedCount)")
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.diffRemove)
                            }
                            if edit.addedCount == 0, edit.removedCount == 0, edit.status == .running {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showUndoControl {
                    undoButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)

            if isOpen, !edit.lines.isEmpty {
                Divider().opacity(0.45)
                CodeDiffBlock(lines: edit.lines, maxVisible: 40, animateReveal: false)
                    .padding(8)
                    .opacity(isUndone ? 0.45 : 1)
            }
        }
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.Palette.divider, lineWidth: 0.5)
        )
        .onAppear {
            if preferExpanded || edit.status == .running || edit.removedCount > 0 {
                isOpen = true
            }
        }
        .onChange(of: edit.status) { _, new in
            if new == .running { isOpen = true }
        }
        .onChange(of: edit.removedCount) { _, n in
            if n > 0 { isOpen = true }
        }
    }

    private var showUndoControl: Bool {
        edit.canUndo && onUndo != nil
    }

    @ViewBuilder
    private var undoButton: some View {
        if isUndone {
            Text("Undone")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
        } else {
            Button {
                guard !undoBusy else { return }
                undoBusy = true
                onUndo?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    undoBusy = false
                }
            } label: {
                HStack(spacing: 4) {
                    if undoBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text("Undo")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.Palette.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.Palette.accent.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .disabled(undoBusy)
            .help("Restore this file to its pre-edit contents")
            .accessibilityLabel("Undo file edit")
        }
    }
}

// MARK: - Partition helpers for Chat bubbles

enum ChatToolPartition {
    /// Split tool states into inline edit cards vs normal activity lines.
    /// `seedContents` is path → full file body from earlier turns; updated
    /// as we walk `states` so a later write_file on the same path shows red −.
    static func split(
        _ states: [ToolCallUIState],
        seedContents: [String: String] = [:]
    ) -> (
        edits: [FileCodeEdit],
        activity: [ToolCallUIState]
    ) {
        var edits: [FileCodeEdit] = []
        var activity: [ToolCallUIState] = []
        var contents = seedContents

        for state in states {
            guard CodeSessionBuilder.isEditTool(state.toolName) else {
                activity.append(state)
                continue
            }

            let rawPath = CodeSessionBuilder.path(from: state)
            let previous = rawPath.flatMap {
                CodeSessionBuilder.lookupContent(contents, path: $0)
            }

            if let edit = CodeSessionBuilder.fileEdit(from: state, previousContent: previous) {
                edits.append(edit)
                if let rawPath {
                    let key = CodeSessionBuilder.normalizePath(rawPath)
                    if let after = CodeSessionBuilder.contentAfterEdit(previous: previous, state: state) {
                        contents[key] = after
                    } else if let written = CodeSessionBuilder.writtenContent(from: state) {
                        contents[key] = written
                    }
                }
            } else {
                activity.append(state)
            }
        }
        return (edits, activity)
    }
}
