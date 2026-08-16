//
//  StatusCapsuleView.swift
//
//  Slim collapsible strip: git branch + dirty count + latest-turn
//  file changes + plan todos. Hidden when there is no cwd / not a repo.
//

import SwiftUI
import AgentCore

struct StatusCapsuleView: View {
    let cwd: URL?
    let conversationID: UUID
    let isRunning: Bool
    let changeSummary: TurnChangeSummary
    let todoDone: Int
    let todoTotal: Int

    @State private var isExpanded = false
    @State private var git: GitWorkingCopySummary?

    private var refreshKey: String {
        "\(conversationID.uuidString)|\(cwd?.path ?? "")"
    }

    var body: some View {
        Group {
            if let git {
                capsule(git)
            }
        }
        .task(id: refreshKey) {
            isExpanded = false
            await refreshGit()
        }
        .onChange(of: isRunning) { _, running in
            guard !running else { return }
            Task { await refreshGit() }
        }
    }

    // MARK: - Chrome

    private func capsule(_ git: GitWorkingCopySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow(git)
            if isExpanded {
                expandedRows(git)
                    .padding(.top, 6)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isExpanded ? 8 : 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.canvas)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Palette.divider)
                .frame(height: 0.5)
        }
    }

    private func headerRow(_ git: GitWorkingCopySummary) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)

                Text(collapsedTitle(git))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse status" : "Expand status")
        .accessibilityLabel(collapsedTitle(git))
        .accessibilityHint(isExpanded ? "Collapse git and todo status" : "Expand git and todo status")
    }

    @ViewBuilder
    private func expandedRows(_ git: GitWorkingCopySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !git.branch.isEmpty {
                detailRow(label: "Branch", value: git.branch)
            }
            if git.dirtyCount > 0 {
                detailRow(label: "Dirty", value: "\(git.dirtyCount)")
            }
            if !changeSummary.isEmpty, let value = changesValue {
                detailRow(label: "Changes", value: value)
            }
            if todoTotal > 0 {
                detailRow(label: "Todos", value: "\(max(0, todoDone))/\(todoTotal)")
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }

    // MARK: - Copy

    private func collapsedTitle(_ git: GitWorkingCopySummary) -> String {
        let raw = GitWorkingCopySummary.collapsedLabel(
            branch: git.branch,
            dirtyCount: git.dirtyCount,
            fileCount: changeSummary.fileCount,
            todoDone: todoDone,
            todoTotal: todoTotal
        )
        return raw.isEmpty ? "clean" : raw
    }

    private var changesValue: String? {
        guard !changeSummary.isEmpty else { return nil }
        var parts: [String] = []
        if let files = GitWorkingCopySummary.filesSegment(fileCount: changeSummary.fileCount) {
            parts.append(files)
        }
        if changeSummary.totalAdded > 0 || changeSummary.totalRemoved > 0 {
            parts.append("+\(changeSummary.totalAdded) −\(changeSummary.totalRemoved)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    // MARK: - Probe

    @MainActor
    private func refreshGit() async {
        guard let cwd else {
            git = nil
            return
        }
        let url = cwd
        let captured = await Task.detached(priority: .utility) {
            GitWorkingCopySummary.capture(workingDirectory: url)
        }.value
        if Task.isCancelled { return }
        git = captured
    }
}
