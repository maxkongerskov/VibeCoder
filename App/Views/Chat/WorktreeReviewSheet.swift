// WorktreeReviewSheet.swift
// AgentOS — NEW DAY
//
// Shows the diff between a git worktree branch and HEAD, with per-file
// expansion. The user can type a commit message then Merge, Discard, or
// continue without touching the worktree (dismiss).
//
// Live path: `WorktreeFileChange.from(worktreePath:)` runs
// WorktreeService.reviewChanges (real `git status` / `git diff`).
// Sample data remains for the debug menu.

import SwiftUI
import AgentCore

// MARK: - Domain model

/// Describes a single file that changed inside the worktree.
struct WorktreeFileChange: Identifiable {
    let id = UUID()

    enum ChangeKind {
        case modified, added, deleted
    }

    let path: String
    let kind: ChangeKind
    let linesAdded: Int
    let linesRemoved: Int
    let diffLines: [WorktreeDiffLine]

    /// Map AgentCore structured review rows → UI model.
    static func from(parserFiles: [WorktreeDiffParser.FileChange]) -> [WorktreeFileChange] {
        parserFiles.map { f in
            let kind: ChangeKind
            switch f.kind {
            case .modified: kind = .modified
            case .added: kind = .added
            case .deleted: kind = .deleted
            }
            let lines = f.diffLines.map { line -> WorktreeDiffLine in
                let k: WorktreeDiffLineKind
                switch line.kind {
                case .context: k = .context
                case .added: k = .added
                case .removed: k = .removed
                }
                return WorktreeDiffLine(kind: k, text: line.text)
            }
            return WorktreeFileChange(
                path: f.path,
                kind: kind,
                linesAdded: f.linesAdded,
                linesRemoved: f.linesRemoved,
                diffLines: lines
            )
        }
    }

    /// Load real git diff for an on-disk worktree path.
    static func from(worktreePath: String) -> [WorktreeFileChange] {
        let parsed = WorktreeService.reviewChanges(worktreePath: worktreePath)
        return from(parserFiles: parsed)
    }
}

enum WorktreeDiffLineKind {
    case context, added, removed
}

struct WorktreeDiffLine: Identifiable {
    let id = UUID()
    let kind: WorktreeDiffLineKind
    let text: String
}

// MARK: - Mock data (debug menu only)

private let mockBranchName = "agentos/a4f2c3"
private let mockDefaultCommitMessage = "Merge agentos/a4f2c3 — 3 files changed"

extension WorktreeReviewSheet {
    /// Exposed sample data for debug menu triggers in RootView.
    static var sampleFiles: [WorktreeFileChange] { mockFileChanges }
}

let mockFileChanges: [WorktreeFileChange] = [
    WorktreeFileChange(
        path: "Sources/AgentCore/Tools/ReadFileTool.swift",
        kind: .modified,
        linesAdded: 12,
        linesRemoved: 3,
        diffLines: [
            WorktreeDiffLine(kind: .context,  text: "    func execute(_ input: ReadFileInput) async throws -> String {"),
            WorktreeDiffLine(kind: .context,  text: "        let url = URL(fileURLWithPath: input.path)"),
            WorktreeDiffLine(kind: .context,  text: "        guard FileManager.default.fileExists(atPath: input.path) else {"),
            WorktreeDiffLine(kind: .removed,  text: "        let data = try Data(contentsOf: url)"),
            WorktreeDiffLine(kind: .added,    text: "        let data = try Data(contentsOf: url, options: .mappedIfSafe)"),
            WorktreeDiffLine(kind: .added,    text: "        let encoding = detectEncoding(data)"),
            WorktreeDiffLine(kind: .added,    text: "        guard encoding != nil else { throw ToolError.unreadableEncoding }"),
            WorktreeDiffLine(kind: .context,  text: "        return String(decoding: data, as: UTF8.self)"),
            WorktreeDiffLine(kind: .context,  text: "    }"),
        ]
    ),
    WorktreeFileChange(
        path: "Sources/AgentCore/Tools/WriteFileTool.swift",
        kind: .modified,
        linesAdded: 5,
        linesRemoved: 1,
        diffLines: [
            WorktreeDiffLine(kind: .context,  text: "    init(registry: ToolRegistry) {"),
            WorktreeDiffLine(kind: .context,  text: "        self.registry = registry"),
            WorktreeDiffLine(kind: .removed,  text: "        self.createIntermediate = false"),
            WorktreeDiffLine(kind: .added,    text: "        self.createIntermediate = true"),
            WorktreeDiffLine(kind: .added,    text: "        self.atomicWrite = true"),
            WorktreeDiffLine(kind: .context,  text: "    }"),
        ]
    ),
    WorktreeFileChange(
        path: "Tests/AgentCoreTests/NewToolsTests.swift",
        kind: .added,
        linesAdded: 48,
        linesRemoved: 0,
        diffLines: [
            WorktreeDiffLine(kind: .added, text: "import XCTest"),
            WorktreeDiffLine(kind: .added, text: "@testable import AgentCore"),
            WorktreeDiffLine(kind: .added, text: ""),
            WorktreeDiffLine(kind: .added, text: "final class NewToolsTests: XCTestCase {"),
            WorktreeDiffLine(kind: .added, text: "    func testReadFileToolMappedSafe() async throws {"),
            WorktreeDiffLine(kind: .added, text: "        let tool = ReadFileTool()"),
            WorktreeDiffLine(kind: .added, text: "        let result = try await tool.execute(.init(path: \"/tmp/test.txt\"))"),
            WorktreeDiffLine(kind: .added, text: "        XCTAssertFalse(result.isEmpty)"),
            WorktreeDiffLine(kind: .added, text: "    }"),
            WorktreeDiffLine(kind: .added, text: "}"),
        ]
    ),
]

// MARK: - Main sheet

struct WorktreeReviewSheet: View {

    // MARK: Props

    var branchName: String
    var files: [WorktreeFileChange]
    var onDismiss: () -> Void
    var onMerge: (String) -> Void   // parameter: commit message
    var onDiscard: () -> Void

    // MARK: State

    @State private var expandedFiles: Set<UUID> = []
    @State private var commitMessage: String = ""
    @State private var showMergeConfirm: Bool = false
    @State private var showDiscardConfirm: Bool = false

    @Environment(\.dismiss) private var dismiss

    // MARK: Derived

    private var totalAdded: Int   { files.reduce(0) { $0 + $1.linesAdded } }
    private var totalRemoved: Int { files.reduce(0) { $0 + $1.linesRemoved } }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            statsStrip
            Divider()
                .background(Theme.Palette.divider)
            fileList
            Divider()
                .background(Theme.Palette.divider)
            bottomBar
        }
        .frame(width: 720, height: 600)
        .background(Theme.Palette.canvas)
        .onAppear {
            commitMessage = defaultCommitMessage()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Worktree review")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primary)
                Text(branchName)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
            Spacer()
            Button {
                withAnimation(Theme.Motion.gentle) {
                    if expandedFiles.count == files.count {
                        expandedFiles.removeAll()
                    } else {
                        expandedFiles = Set(files.map(\.id))
                    }
                }
            } label: {
                Text(expandedFiles.count == files.count ? "Collapse all" : "Expand all")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.ml)
        .padding(.vertical, Theme.Spacing.m)
        .background(Theme.Palette.surface)
    }

    // MARK: - Stats strip

    private var statsStrip: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("\(files.count) file\(files.count == 1 ? "" : "s") changed")
                .foregroundStyle(Theme.Palette.secondary)
            separator
            statBadge("+\(totalAdded)", color: Theme.Palette.success)
            statBadge("-\(totalRemoved)", color: Theme.Palette.error)
            Spacer()
        }
        .font(.system(size: 12, weight: .regular))
        .padding(.horizontal, Theme.Spacing.ml)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Palette.muted)  // sidebar-tone strip — NOT text color
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(Theme.Palette.tertiary)
    }

    private func statBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
    }

    // MARK: - File list

    private var fileList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(files) { file in
                    fileSection(file)
                }
            }
            .padding(.bottom, Theme.Spacing.ml)
        }
    }

    @ViewBuilder
    private func fileSection(_ file: WorktreeFileChange) -> some View {
        let isExpanded = expandedFiles.contains(file.id)

        Section {
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(file.diffLines) { line in
                        diffLineRow(line)
                    }
                }
                .padding(.bottom, Theme.Spacing.s)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } header: {
            fileSectionHeader(file: file, isExpanded: isExpanded)
        }
    }

    private func fileSectionHeader(file: WorktreeFileChange, isExpanded: Bool) -> some View {
        Button {
            withAnimation(Theme.Motion.gentle) {
                if isExpanded {
                    expandedFiles.remove(file.id)
                } else {
                    expandedFiles.insert(file.id)
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .frame(width: 12)
                kindIcon(file.kind)
                Text(file.path)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.m)
                kindPill(file.kind)
                if file.linesAdded > 0 {
                    Text("+\(file.linesAdded)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Palette.success)
                }
                if file.linesRemoved > 0 {
                    Text("-\(file.linesRemoved)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Palette.error)
                }
            }
            .padding(.horizontal, Theme.Spacing.ml)
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.muted)  // sidebar-tone header — NOT text color
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Divider().background(Theme.Palette.divider)
        }
    }

    @ViewBuilder
    private func kindIcon(_ kind: WorktreeFileChange.ChangeKind) -> some View {
        switch kind {
        case .added:
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.success)
        case .deleted:
            Image(systemName: "doc.badge.minus")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.error)
        case .modified:
            Image(systemName: "doc.text")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
        }
    }

    @ViewBuilder
    private func kindPill(_ kind: WorktreeFileChange.ChangeKind) -> some View {
        let (label, color): (String, Color) = {
            switch kind {
            case .added:    return ("new", Theme.Palette.success)
            case .deleted:  return ("deleted", Theme.Palette.error)
            case .modified: return ("modified", Theme.Palette.accent)
            }
        }()
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
    }

    // MARK: - Diff line

    private func diffLineRow(_ line: WorktreeDiffLine) -> some View {
        let (bg, fg, prefix): (Color, Color, String) = {
            switch line.kind {
            case .added:
                return (Theme.Palette.success.opacity(0.10), Theme.Palette.success, "+")
            case .removed:
                return (Theme.Palette.error.opacity(0.10), Theme.Palette.error, "-")
            case .context:
                return (.clear, Theme.Palette.secondary, " ")
            }
        }()

        return HStack(alignment: .top, spacing: 0) {
            Text(prefix)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(fg)
                .frame(width: 20)
                .padding(.vertical, 1)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(line.kind == .context ? Theme.Palette.primary : fg)
                .textSelection(.enabled)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.s)
        .background(bg)
    }

    // MARK: - Bottom bar (commit message + actions)

    private var bottomBar: some View {
        VStack(spacing: 0) {
            // Commit message row
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.tertiary)
                TextField("Commit message…", text: $commitMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.Palette.primary)
            }
            .padding(.horizontal, Theme.Spacing.ml)
            .padding(.vertical, Theme.Spacing.s)
            .background(Theme.Palette.subtle)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button)
                    .stroke(Theme.Palette.divider, lineWidth: 1)
            )
            .padding(.horizontal, Theme.Spacing.ml)
            .padding(.top, Theme.Spacing.m)

            // Action buttons
            HStack(spacing: Theme.Spacing.m) {
                // Dismiss without action
                Button("Continue") {
                    onDismiss()
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Palette.secondary)

                Spacer()

                // Discard branch
                Button {
                    showDiscardConfirm = true
                } label: {
                    Label("Discard", systemImage: "trash")
                        .font(.system(size: 13, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.error)
                .confirmationDialog(
                    "Discard worktree branch \"\(branchName)\"?",
                    isPresented: $showDiscardConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Discard branch", role: .destructive) {
                        onDiscard()
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All uncommitted changes in the worktree will be permanently removed.")
                }

                // Merge into main
                Button {
                    showMergeConfirm = true
                } label: {
                    Label("Merge into main", systemImage: "arrow.merge")
                        .font(.system(size: 13, weight: .semibold))
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                .confirmationDialog(
                    "Merge \"\(branchName)\" into main?",
                    isPresented: $showMergeConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Merge") {
                        onMerge(commitMessage.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will merge the worktree branch and remove the worktree directory.")
                }
            }
            .padding(.horizontal, Theme.Spacing.ml)
            .padding(.vertical, Theme.Spacing.m)
        }
        .background(Theme.Palette.surface)
    }

    // MARK: - Helpers

    private func defaultCommitMessage() -> String {
        let addedCount = files.filter { $0.kind == .added }.count
        let modifiedCount = files.filter { $0.kind == .modified }.count
        let deletedCount = files.filter { $0.kind == .deleted }.count
        var parts: [String] = []
        if modifiedCount > 0 { parts.append("\(modifiedCount) modified") }
        if addedCount > 0    { parts.append("\(addedCount) added") }
        if deletedCount > 0  { parts.append("\(deletedCount) deleted") }
        let summary = parts.isEmpty ? "\(files.count) files changed" : parts.joined(separator: ", ")
        return "Merge \(branchName) — \(summary)"
    }
}

// MARK: - Preview

#Preview("WorktreeReviewSheet") {
    WorktreeReviewSheet(
        branchName: mockBranchName,
        files: mockFileChanges,
        onDismiss: { print("dismiss") },
        onMerge:   { msg in print("merge: \(msg)") },
        onDiscard: { print("discard") }
    )
}
