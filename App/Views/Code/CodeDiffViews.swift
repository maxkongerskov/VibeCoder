//
//  CodeDiffViews.swift
//
//  Quiet Pulse code diffs: staggered line reveal, soft +/- tints,
//  step-rail activity rows, focused edit cards.
//

import SwiftUI

// MARK: - Diff block

struct CodeDiffBlock: View {
    let lines: [CodeDiffLine]
    var maxVisible: Int = 24
    /// Kept for API compat; staggered reveal is off — it re-fired on every
    /// tool output update and made the code pane flicker hard.
    var animateReveal: Bool = false

    @State private var expanded = false

    private var visible: [CodeDiffLine] {
        expanded ? lines : Array(lines.prefix(maxVisible))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Index-based ids: content hash identities thrash when lines update.
            ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                CodeDiffLineRow(line: line)
            }
            if lines.count > maxVisible {
                Button(expanded ? "Show less" : "Show \(lines.count - maxVisible) more lines") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .background(Theme.Palette.canvas.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
    }
}

private struct CodeDiffLineRow: View {
    let line: CodeDiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Leading accent bar (mockup: clear add/del bands)
            Rectangle()
                .fill(accentBar)
                .frame(width: 3)

            Text(prefix)
                .font(Theme.Typography.mono(size: 11, weight: .bold))
                .foregroundStyle(prefixColor)
                .frame(width: 16, alignment: .center)
                .padding(.leading, 6)

            Text(text)
                .font(Theme.Typography.mono(size: 11))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 2)
        .background(rowBackground)
    }

    private var prefix: String {
        switch line {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private var text: String {
        switch line {
        case .added(let s), .removed(let s), .context(let s): return s
        }
    }

    private var prefixColor: Color {
        switch line {
        case .added: return Theme.Palette.diffAdd
        case .removed: return Theme.Palette.diffRemove
        case .context: return Theme.Palette.tertiary
        }
    }

    private var textColor: Color {
        switch line {
        case .added: return Theme.Palette.diffAddText
        case .removed: return Theme.Palette.diffRemoveText
        case .context: return Theme.Palette.secondary
        }
    }

    private var rowBackground: Color {
        switch line {
        case .added: return Theme.Palette.diffAddBg
        case .removed: return Theme.Palette.diffRemoveBg
        case .context: return .clear
        }
    }

    private var accentBar: Color {
        switch line {
        case .added: return Theme.Palette.diffAdd.opacity(0.85)
        case .removed: return Theme.Palette.diffRemove.opacity(0.85)
        case .context: return .clear
        }
    }
}

// MARK: - File edit card

struct FileEditCard: View {
    let edit: FileCodeEdit
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil

    @State private var expanded = true

    var body: some View {
        Button {
            onSelect?()
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .disabled(onSelect == nil)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Edit")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.activityVerb)
                    .frame(minWidth: 36, alignment: .leading)

                Text(shortPath)
                    .font(Theme.Typography.mono(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.info)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    Text("\(addCount)+")
                        .font(Theme.Typography.mono(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.diffAdd)
                    Text("\(removeCount)−")
                        .font(Theme.Typography.mono(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.diffRemove)
                }

                statusBadge

                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expanded {
                CodeDiffBlock(lines: edit.lines, animateReveal: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            isSelected
                ? Theme.Palette.accent.opacity(0.10)
                : Theme.Palette.surface.opacity(0.65)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected
                        ? Theme.Palette.accent.opacity(0.45)
                        : Theme.Palette.divider,
                    lineWidth: isSelected ? 1.25 : 0.5
                )
        )
        .shadow(
            color: isSelected ? Theme.Palette.accent.opacity(0.12) : .clear,
            radius: isSelected ? 8 : 0
        )
        .animation(.easeOut(duration: 0.22), value: isSelected)
    }

    private var shortPath: String {
        let parts = edit.path.split(separator: "/")
        if parts.count > 2 {
            return parts.suffix(2).joined(separator: "/")
        }
        return edit.path
    }

    private var addCount: Int {
        edit.lines.filter { if case .added = $0 { return true }; return false }.count
    }

    private var removeCount: Int {
        edit.lines.filter { if case .removed = $0 { return true }; return false }.count
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch edit.status {
        case .pending:
            Text("queued")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Palette.tertiary)
        case .running:
            Text("running")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Palette.info)
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Palette.secondary)
        case .failure:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Palette.error)
        }
    }
}

// MARK: - Activity row (step-style)

struct CodeActivityRow: View {
    let state: ToolCallUIState
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil

    var body: some View {
        Button {
            onSelect?()
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .disabled(onSelect == nil)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Text(verb)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    state.status == .running
                        ? Theme.Palette.activityVerb
                        : Theme.Palette.secondary
                )
                .frame(minWidth: 42, alignment: .leading)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.Palette.info.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Settled status as glyph (step rail already shows the tool symbol).
            if state.status == .success {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Palette.secondary)
            } else if state.status == .failure {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Palette.error)
            } else {
                Text(statusWord)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? Theme.Palette.accent.opacity(0.10)
                : (state.status == .running
                    ? Theme.Palette.info.opacity(0.06)
                    : Theme.Palette.surface.opacity(0.35))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected
                        ? Theme.Palette.accent.opacity(0.4)
                        : (state.status == .running
                            ? Theme.Palette.info.opacity(0.22)
                            : Color.clear),
                    lineWidth: 1
                )
        )
        .animation(.easeOut(duration: 0.2), value: state.status)
        .animation(.easeOut(duration: 0.2), value: isSelected)
    }

    private var verb: String {
        switch state.toolName {
        case "BuildProject", "build_xcode", "swift_check", "xcode_build": return "Build"
        case "RunAllTests", "RunSomeTests": return "Test"
        case "grep_code", "XcodeGrep", "code_search": return "Search"
        case "glob_files", "XcodeGlob": return "Find"
        case "read_file", "read_file_range", "XcodeRead": return "Read"
        case "list_directory", "XcodeLS": return "List"
        case "run_shell": return "Shell"
        case "GetBuildLog": return "Log"
        case "create_plan", "update_todo", "revise_plan": return "Plan"
        case "task": return "Task"
        case "write_file": return "Write"
        case "edit_file", "apply_patch": return "Edit"
        default:
            return String(state.toolName.prefix(8)).replacingOccurrences(of: "_", with: " ")
        }
    }

    private var label: String {
        state.toolName.replacingOccurrences(of: "_", with: " ")
    }

    private var subtitle: String? {
        ToolSummary.subtitle(toolName: state.toolName, input: state.input)
    }

    private var statusWord: String {
        switch state.status {
        case .pending: return "queued"
        case .running: return "running"
        case .success: return "done"
        case .failure: return "failed"
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .pending: return Theme.Palette.tertiary
        case .running: return Theme.Palette.info
        case .success: return Theme.Palette.success
        case .failure: return Theme.Palette.error
        }
    }
}
