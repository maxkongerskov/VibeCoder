//
//  InspectorFilesTab.swift
//
//  Workspace file tree. Click a file to Reveal in Finder.
//

import SwiftUI
import AppKit
import AgentCore

struct InspectorFilesTab: View {
    let projectRoot: URL?

    @State private var nodes: [FileTreeNode] = []
    @State private var expandedIDs: Set<String> = []
    @State private var selectedID: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let empty = InspectorFilesModel.emptyMessage(projectRoot: projectRoot) {
                emptyState(empty)
            } else if isLoading && nodes.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if nodes.isEmpty {
                emptyState("No files in this folder.")
            } else {
                fileList
            }
        }
        .task(id: projectRoot?.path) {
            await reload()
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(nodes) { node in
                    InspectorFileNodeRow(
                        node: node,
                        projectRoot: projectRoot,
                        depth: 0,
                        expandedIDs: $expandedIDs,
                        selectedID: $selectedID
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(Theme.Typography.ui)
            .foregroundStyle(Theme.Palette.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .accessibilityIdentifier("inspector-files-empty")
    }

    private func reload() async {
        guard let projectRoot else {
            nodes = []
            isLoading = false
            return
        }
        isLoading = true
        let files = await ProjectFileIndex.listAllFilesAsync(root: projectRoot)
        nodes = InspectorFilesModel.tree(from: files)
        isLoading = false
    }
}

private struct InspectorFileNodeRow: View {
    let node: FileTreeNode
    let projectRoot: URL?
    let depth: Int
    @Binding var expandedIDs: Set<String>
    @Binding var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            rowButton
            if node.isDirectory, expandedIDs.contains(node.id) {
                ForEach(node.children) { child in
                    InspectorFileNodeRow(
                        node: child,
                        projectRoot: projectRoot,
                        depth: depth + 1,
                        expandedIDs: $expandedIDs,
                        selectedID: $selectedID
                    )
                }
            }
        }
    }

    private var isSelected: Bool { selectedID == node.id && !node.isDirectory }

    private var rowButton: some View {
        Button(action: activate) {
            HStack(spacing: 6) {
                if node.isDirectory {
                    Image(systemName: expandedIDs.contains(node.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10, height: 10)
                }
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.secondary)
                    .frame(width: 14)
                Text(node.name)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Theme.Palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Theme.Palette.accentSubtle : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") { reveal() }
            Button("Copy Path") { copyPath() }
        }
        .help(InspectorFilesModel.relativePath(for: node))
        .accessibilityLabel(node.name)
    }

    private var iconName: String {
        if node.isDirectory {
            return expandedIDs.contains(node.id) ? "folder.fill" : "folder"
        }
        return "doc"
    }

    private func activate() {
        if node.isDirectory {
            if expandedIDs.contains(node.id) {
                expandedIDs.remove(node.id)
            } else {
                expandedIDs.insert(node.id)
            }
        } else {
            selectedID = node.id
            reveal()
        }
    }

    private func reveal() {
        guard let url = resolvedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyPath() {
        let text = resolvedURL?.path ?? InspectorFilesModel.relativePath(for: node)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var resolvedURL: URL? {
        guard let projectRoot else { return nil }
        return InspectorFilesModel.fileURL(for: node, root: projectRoot)
    }
}
