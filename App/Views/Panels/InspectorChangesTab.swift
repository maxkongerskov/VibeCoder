//
//  InspectorChangesTab.swift
//
//  Conversation file-changes via TurnChangeSummary. Expand for CodeDiffBlock
//  when hunks can be rebuilt from the transcript.
//

import SwiftUI
import AppKit
import AgentCore

struct InspectorChangesTab: View {
    let conversation: Conversation?
    let projectRoot: URL?

    @State private var expandedIDs: Set<String> = []

    private var files: [InspectorFileChange] {
        InspectorChangeAggregator.files(in: conversation)
    }

    private var reviewLines: [String: [CodeDiffLine]] {
        InspectorChangeAggregator.diffLines(in: conversation)
    }

    var body: some View {
        if files.isEmpty {
            Text(InspectorChangeAggregator.emptyMessage)
                .font(Theme.Typography.ui)
                .foregroundStyle(Theme.Palette.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
                .accessibilityIdentifier("inspector-changes-empty")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(files) { file in
                        changeRow(file)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func changeRow(_ file: InspectorFileChange) -> some View {
        let lines = InspectorChangeAggregator.lines(for: file, in: reviewLines)
        let open = expandedIDs.contains(file.id)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                if open {
                    expandedIDs.remove(file.id)
                } else {
                    expandedIDs.insert(file.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .frame(width: 10)
                    Image(systemName: statusIcon(file.status))
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor(file.status))
                        .frame(width: 14)
                    Text(file.shortPath)
                        .font(Theme.Typography.mono(size: 11.5))
                        .foregroundStyle(Theme.Palette.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
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
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(file.path)
            .contextMenu {
                Button("Reveal in Finder") { reveal(file) }
                Button("Copy Path") { copyPath(file) }
            }
            .accessibilityLabel("\(file.path), plus \(file.added), minus \(file.removed)")

            if open {
                if lines.isEmpty {
                    Button("Open in Finder") { reveal(file) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(.leading, 30)
                        .padding(.bottom, 6)
                        .padding(.top, 2)
                } else {
                    CodeDiffBlock(lines: lines, maxVisible: 16, animateReveal: false)
                        .padding(.leading, 8)
                        .padding(.trailing, 2)
                        .padding(.bottom, 6)
                }
            }
        }
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

    private func reveal(_ file: InspectorFileChange) {
        let url = InspectorChangeAggregator.fileURL(for: file.path, projectRoot: projectRoot)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyPath(_ file: InspectorFileChange) {
        let url = InspectorChangeAggregator.fileURL(for: file.path, projectRoot: projectRoot)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}
