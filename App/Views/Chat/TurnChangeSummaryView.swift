//
//  TurnChangeSummaryView.swift
//
//  ZCode turn-end card: "N file(s) changed +a −d" with per-file Review
//  (inline CodeDiffBlock) and header Undo (posts .turnRewindRequested).
//

import SwiftUI
import AgentCore

public extension Notification.Name {
    static let turnRewindRequested = Notification.Name("vibecoder.turnRewindRequested")
}

struct TurnChangeSummaryView: View {
    let summary: TurnChangeSummary
    var conversationID: UUID? = nil
    /// Diff lines keyed by `TurnChangeSummary.pathKey`.
    var reviewLinesByPath: [String: [CodeDiffLine]] = [:]

    @State private var isExpanded = false
    @State private var reviewingKeys: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            if isExpanded {
                Divider().opacity(0.45)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(summary.files) { file in
                        fileRow(file)
                    }
                }
            }
        }
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.Palette.divider, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
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
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))

                    Text(filesChangedLabel)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        Text("+\(summary.totalAdded)")
                            .font(Theme.Typography.mono(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.Palette.diffAdd)
                        Text("−\(summary.totalRemoved)")
                            .font(Theme.Typography.mono(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.Palette.diffRemove)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            undoButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private var undoButton: some View {
        Button(action: postRewind) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .semibold))
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
        .help("Rewind this turn’s file and conversation changes")
        .accessibilityLabel("Undo file changes")
    }

    // MARK: - File rows

    @ViewBuilder
    private func fileRow(_ file: TurnChangeSummary.FileChange) -> some View {
        let key = TurnChangeSummary.pathKey(file.path)
        let lines = lines(for: file)
        let reviewing = reviewingKeys.contains(key)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon(file.status))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor(file.status))
                    .frame(width: 16)

                Text(file.path)
                    .font(Theme.Typography.mono(size: 12))
                    .foregroundStyle(Theme.Palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if file.added > 0 {
                        Text("+\(file.added)")
                            .font(Theme.Typography.mono(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.diffAdd)
                    }
                    if file.removed > 0 {
                        Text("−\(file.removed)")
                            .font(Theme.Typography.mono(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.diffRemove)
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if reviewing {
                            reviewingKeys.remove(key)
                        } else {
                            reviewingKeys.insert(key)
                        }
                    }
                } label: {
                    Text(reviewing ? "Hide" : "Review")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.Palette.accent.opacity(reviewing ? 0.16 : 0.10))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reviewing ? "Hide diff for \(file.path)" : "Review \(file.path)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if reviewing {
                if lines.isEmpty {
                    Text("No diff preview")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else {
                    CodeDiffBlock(lines: lines, maxVisible: 40, animateReveal: false)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Helpers

    private var filesChangedLabel: String {
        let n = summary.fileCount
        return n == 1 ? "1 file changed" : "\(n) files changed"
    }

    private var headerAccessibilityLabel: String {
        "\(filesChangedLabel), plus \(summary.totalAdded), minus \(summary.totalRemoved)"
    }

    private func statusIcon(_ status: TurnChangeSummary.FileChange.Status) -> String {
        switch status {
        case .created: return "plus.circle"
        case .modified: return "pencil"
        case .deleted: return "minus.circle"
        }
    }

    private func statusColor(_ status: TurnChangeSummary.FileChange.Status) -> Color {
        switch status {
        case .created: return Theme.Palette.diffAdd
        case .modified: return Theme.Palette.secondary
        case .deleted: return Theme.Palette.diffRemove
        }
    }

    private func lines(for file: TurnChangeSummary.FileChange) -> [CodeDiffLine] {
        let key = TurnChangeSummary.pathKey(file.path)
        if let exact = reviewLinesByPath[key] { return exact }
        if let exact = reviewLinesByPath[file.path] { return exact }
        for (k, v) in reviewLinesByPath {
            if TurnChangeSummary.pathKey(k) == key { return v }
            if k.hasSuffix("/" + file.path) || file.path.hasSuffix("/" + k) {
                return v
            }
        }
        return []
    }

    private func postRewind() {
        var info: [AnyHashable: Any] = [:]
        if let conversationID {
            info["conversationID"] = conversationID
        }
        NotificationCenter.default.post(
            name: .turnRewindRequested,
            object: conversationID,
            userInfo: info.isEmpty ? nil : info
        )
    }
}
