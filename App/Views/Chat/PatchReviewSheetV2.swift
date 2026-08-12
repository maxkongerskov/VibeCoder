// PatchReviewSheetV2.swift
// AgentOS — NEW DAY
//
// File-level Accept / Reject review sheet for unified-diff patches.
// Matches AgentCore `PatchDecision` v1 wire format (accept/reject whole
// files — not individual hunks). Hunks still render as read-only unified
// diffs so the user can scan changes before deciding per file.
//
// Design decisions:
// - Unified inline diff (not side-by-side): the sheet is single-column
//   and 760 pt wide; splitting further would make code lines unreadably
//   narrow on a 13" MBP.
// - Tinted full-width row backgrounds for added/removed lines — the
//   classic unified-diff convention; faster to scan than column markers.
// - Syntax highlighting deferred to v1.1 (needs Tree-sitter or SourceKit).
// - Each file section is a disclosure group so long patches can be
//   collapsed without losing the global accept/reject state.
// - Decisions are per *file* only. Per-hunk buttons were removed because
//   they lied about apply granularity (AgentCore applies whole files).

import SwiftUI
import Foundation
import AgentCore

// MARK: - Domain types

/// Per-file accept/reject decision — mirrors AgentCore file-level wire format.
enum FilePatchDecision: Equatable {
    case pending, accepted, rejected
}

/// Legacy alias kept so older call sites / tests that still say "hunk" compile
/// until fully migrated. Prefer `FilePatchDecision`.
typealias HunkDecision = FilePatchDecision

enum DiffLineKind {
    case context, added, removed
}

struct DiffLine: Identifiable {
    let id = UUID()
    let kind: DiffLineKind
    let text: String
}

struct PatchHunk: Identifiable {
    let id: String
    let header: String          // e.g. "@@ -42,7 +42,7 @@"
    let lines: [DiffLine]
}

struct FilePatch: Identifiable {
    let id = UUID()
    let path: String
    let hunks: [PatchHunk]
}

// MARK: - Apply mapping (pure — unit-tested)

/// Maps UI file decisions → AgentCore `PatchDecision`.
enum PatchReviewApplyMapping {
    /// - Parameters:
    ///   - decisions: path → accept/reject/pending
    ///   - pathToPreviewID: path → `PatchPreview.id`
    ///   - previewCount: total files in the batch (for acceptAll vs partial)
    static func toPatchDecision(
        decisions: [String: FilePatchDecision],
        pathToPreviewID: [String: UUID],
        previewCount: Int
    ) -> PatchDecision {
        var acceptedIDs = Set<UUID>()
        for (path, decision) in decisions {
            guard decision == .accepted, let id = pathToPreviewID[path] else { continue }
            acceptedIDs.insert(id)
        }
        if acceptedIDs.isEmpty { return .rejectAll }
        if acceptedIDs.count == previewCount { return .acceptAll }
        return .partial(acceptedFileIDs: acceptedIDs)
    }
}

// MARK: - Mock data

private let mockPatches: [FilePatch] = [
    FilePatch(
        path: "Sources/AgentCore/Tools/ReadFileTool.swift",
        hunks: [
            PatchHunk(
                id: "read-1",
                header: "@@ -42,7 +42,7 @@",
                lines: [
                    DiffLine(kind: .context,  text: "    func execute(_ input: ReadFileInput) async throws -> String {"),
                    DiffLine(kind: .context,  text: "        let url = URL(fileURLWithPath: input.path)"),
                    DiffLine(kind: .context,  text: "        guard FileManager.default.fileExists(atPath: input.path) else {"),
                    DiffLine(kind: .context,  text: "            throw ToolError.fileNotFound(input.path)"),
                    DiffLine(kind: .context,  text: "        }"),
                    DiffLine(kind: .removed,  text: "        let data = try Data(contentsOf: url)"),
                    DiffLine(kind: .added,    text: "        let data = try Data(contentsOf: url, options: .mappedIfSafe)"),
                    DiffLine(kind: .context,  text: "        return String(decoding: data, as: UTF8.self)"),
                    DiffLine(kind: .context,  text: "    }"),
                ]
            )
        ]
    ),
    FilePatch(
        path: "Sources/AgentCore/Tools/WriteFileTool.swift",
        hunks: [
            PatchHunk(
                id: "write-1",
                header: "@@ -18,6 +18,7 @@",
                lines: [
                    DiffLine(kind: .context,  text: "    init(registry: ToolRegistry) {"),
                    DiffLine(kind: .context,  text: "        self.registry = registry"),
                    DiffLine(kind: .removed,  text: "        self.createIntermediate = false"),
                    DiffLine(kind: .added,    text: "        self.createIntermediate = true"),
                    DiffLine(kind: .added,    text: "        self.atomicWrite = true"),
                    DiffLine(kind: .context,  text: "    }"),
                    DiffLine(kind: .context,  text: ""),
                ]
            ),
            PatchHunk(
                id: "write-2",
                header: "@@ -61,8 +62,10 @@",
                lines: [
                    DiffLine(kind: .context,  text: "    func execute(_ input: WriteFileInput) async throws {"),
                    DiffLine(kind: .context,  text: "        let url = URL(fileURLWithPath: input.path)"),
                    DiffLine(kind: .removed,  text: "        try data.write(to: url)"),
                    DiffLine(kind: .added,    text: "        if atomicWrite {"),
                    DiffLine(kind: .added,    text: "            try data.write(to: url, options: .atomic)"),
                    DiffLine(kind: .added,    text: "        } else {"),
                    DiffLine(kind: .added,    text: "            try data.write(to: url)"),
                    DiffLine(kind: .added,    text: "        }"),
                    DiffLine(kind: .context,  text: "        Logger.shared.log(\"Wrote \\(data.count) bytes to \\(input.path)\")"),
                    DiffLine(kind: .context,  text: "    }"),
                ]
            )
        ]
    ),
    FilePatch(
        path: "Sources/AgentCore/Patch/UnifiedDiff.swift",
        hunks: [
            PatchHunk(
                id: "diff-1",
                header: "@@ -104,6 +104,8 @@",
                lines: [
                    DiffLine(kind: .context,  text: "    static func parse(_ text: String) -> [FilePatch] {"),
                    DiffLine(kind: .context,  text: "        var patches: [FilePatch] = []"),
                    DiffLine(kind: .context,  text: "        var current: FilePatch? = nil"),
                    DiffLine(kind: .removed,  text: "        for line in text.components(separatedBy: .newlines) {"),
                    DiffLine(kind: .added,    text: "        let lines = text.components(separatedBy: .newlines)"),
                    DiffLine(kind: .added,    text: "        for line in lines {"),
                    DiffLine(kind: .context,  text: "            if line.hasPrefix(\"diff --git\") {"),
                    DiffLine(kind: .context,  text: "                if let p = current { patches.append(p) }"),
                    DiffLine(kind: .context,  text: "                current = FilePatch()"),
                ]
            )
        ]
    )
]

// MARK: - Main sheet view

struct PatchReviewSheetV2: View {

    /// Injected patches to render. Defaults to `mockPatches` so the
    /// preview / debug-menu entry-point in RootView keeps working.
    var patches: [FilePatch] = mockPatches

    /// Called with per-file decisions (keyed by path) when the user taps
    /// "Apply selected". Host maps these into AgentCore `PatchDecision`.
    var onApply: (([String: FilePatchDecision]) -> Void)?

    /// Called when the sheet is dismissed without applying. Host
    /// should treat this as `PatchDecision.rejectAll` so the suspended
    /// `apply_patch` resumes with a clean error.
    var onCancel: () -> Void = {}

    /// Optional: remember durable folder access (Always allow folder) then apply.
    var onAlwaysAllowFolder: (([String: FilePatchDecision]) -> Void)? = nil

    /// path → decision
    @State private var decisions: [String: FilePatchDecision] = [:]
    @State private var expandedFiles: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss

    // Derived counts (file-level)
    private var totalFiles: Int { patches.count }
    private var decidedCount: Int {
        patches.filter { decisions[$0.path] != nil && decisions[$0.path] != .pending }.count
    }
    private var acceptedCount: Int {
        patches.filter { decisions[$0.path] == .accepted }.count
    }
    private var allPaths: [String] { patches.map(\.path) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            statusStrip
            Divider()
                .background(Theme.Palette.divider)
            fileList
            Divider()
                .background(Theme.Palette.divider)
            bottomBar
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(Theme.Palette.canvas)
        .onAppear {
            for path in allPaths where decisions[path] == nil {
                decisions[path] = .pending
            }
            expandedFiles = Set(patches.map(\.id))
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
            Text("Review patch")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.primary)
            Spacer()
            Button("Reject all") {
                withAnimation(Theme.Motion.gentle) {
                    for path in allPaths { decisions[path] = .rejected }
                }
            }
            .buttonStyle(DestructiveButtonStyle())
            Button("Accept all") {
                withAnimation(Theme.Motion.gentle) {
                    for path in allPaths { decisions[path] = .accepted }
                }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, Theme.Spacing.ml)
        .padding(.vertical, Theme.Spacing.m)
    }

    // MARK: - Status strip

    private var statusStrip: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("\(totalFiles) file\(totalFiles == 1 ? "" : "s")")
                .foregroundStyle(Theme.Palette.secondary)
            Text("·")
                .foregroundStyle(Theme.Palette.tertiary)
            let hunkTotal = patches.reduce(0) { $0 + $1.hunks.count }
            Text("\(hunkTotal) hunk\(hunkTotal == 1 ? "" : "s") (read-only)")
                .foregroundStyle(Theme.Palette.secondary)
            Text("·")
                .foregroundStyle(Theme.Palette.tertiary)
            Text("\(decidedCount) of \(totalFiles) files decided")
                .foregroundStyle(decidedCount == totalFiles ? Theme.Palette.success : Theme.Palette.secondary)
                .animation(Theme.Motion.quick, value: decidedCount)
            Spacer()
            Text("Accept or reject each file — changes apply per file")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.tertiary)
        }
        .font(.system(size: 12, weight: .regular))
        .padding(.horizontal, Theme.Spacing.ml)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Palette.muted)
    }

    // MARK: - File list

    private var fileList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(patches) { patch in
                    fileSection(patch)
                }
            }
            .padding(.bottom, Theme.Spacing.ml)
        }
    }

    @ViewBuilder
    private func fileSection(_ patch: FilePatch) -> some View {
        let isExpanded = expandedFiles.contains(patch.id)
        let decision = decisions[patch.path] ?? .pending
        let hunkCount = patch.hunks.count

        Section {
            if isExpanded {
                VStack(spacing: Theme.Spacing.ml) {
                    ForEach(patch.hunks) { hunk in
                        hunkView(hunk, fileDecision: decision)
                            .padding(.horizontal, Theme.Spacing.ml)
                    }
                }
                .padding(.top, Theme.Spacing.m)
                .padding(.bottom, Theme.Spacing.ml)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } header: {
            fileSectionHeader(
                patch: patch,
                hunkCount: hunkCount,
                decision: decision,
                isExpanded: isExpanded
            )
        }
    }

    private func fileSectionHeader(
        patch: FilePatch,
        hunkCount: Int,
        decision: FilePatchDecision,
        isExpanded: Bool
    ) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                withAnimation(Theme.Motion.gentle) {
                    if isExpanded {
                        expandedFiles.remove(patch.id)
                    } else {
                        expandedFiles.insert(patch.id)
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .frame(width: 12)
                    Image(systemName: "doc.text")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Theme.Palette.accent)
                    Text(patch.path)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.Palette.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if decision != .pending {
                        decisionBadge(decision)
                    }
                    Text(hunkCount == 1 ? "1 hunk" : "\(hunkCount) hunks")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .padding(.horizontal, Theme.Spacing.s)
                        .padding(.vertical, 3)
                        .background(Theme.Palette.subtle)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Per-file actions (wire format)
            Button("Reject") {
                withAnimation(Theme.Motion.gentle) {
                    decisions[patch.path] = decisions[patch.path] == .rejected ? .pending : .rejected
                }
            }
            .buttonStyle(DestructiveButtonStyle())
            Button(decision == .accepted ? "Accepted" : "Accept") {
                withAnimation(Theme.Motion.gentle) {
                    decisions[patch.path] = decisions[patch.path] == .accepted ? .pending : .accepted
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, Theme.Spacing.ml)
        .padding(.vertical, Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.muted)
        .overlay(alignment: .bottom) {
            Divider().background(Theme.Palette.divider)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(borderColor(for: decision))
                .frame(width: 3)
        }
    }

    // MARK: - Hunk view (read-only — no accept/reject controls)

    private func hunkView(_ hunk: PatchHunk, fileDecision: FilePatchDecision) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(hunk.header)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Palette.accent)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Palette.accentSubtle)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunk.lines) { line in
                    diffLineRow(line)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(borderColor(for: fileDecision).opacity(fileDecision == .pending ? 1 : 0.55), lineWidth: 1)
        )
        .animation(Theme.Motion.gentle, value: fileDecision)
    }

    private func diffLineRow(_ line: DiffLine) -> some View {
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
                .padding(.vertical, 2)
            Text(line.text)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(line.kind == .context ? Theme.Palette.primary : fg)
                .textSelection(.enabled)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.s)
        .background(bg)
    }

    private func decisionBadge(_ decision: FilePatchDecision) -> some View {
        let (label, color): (String, Color) = decision == .accepted
            ? ("Accepted", Theme.Palette.success)
            : ("Rejected", Theme.Palette.error)

        return HStack(spacing: 4) {
            Image(systemName: decision == .accepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, 2)
        .background(color.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
    }

    private func borderColor(for decision: FilePatchDecision) -> Color {
        switch decision {
        case .accepted: return Theme.Palette.success.opacity(0.40)
        case .rejected: return Theme.Palette.error.opacity(0.35)
        case .pending:  return Theme.Palette.divider
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .buttonStyle(PlainTextButtonStyle())
            Spacer()
            if acceptedCount > 0 {
                Text("\(acceptedCount) file\(acceptedCount == 1 ? "" : "s") will be applied")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .transition(.opacity)
            }
            // Durable folder grant — stops repeat popups for this tree.
            if acceptedCount > 0, onAlwaysAllowFolder != nil {
                Button("Always allow folder") {
                    onAlwaysAllowFolder?(decisions)
                    onApply?(decisions)
                    dismiss()
                }
                .buttonStyle(PlainTextButtonStyle())
                .help("Remember access for this folder and subfolders; skip future Ask prompts for it")
            }
            Button("Apply selected") {
                onApply?(decisions)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(acceptedCount == 0)
        }
        .padding(.horizontal, Theme.Spacing.ml)
        .padding(.vertical, Theme.Spacing.m)
        .animation(Theme.Motion.quick, value: acceptedCount)
    }
}
