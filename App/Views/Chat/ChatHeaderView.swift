//
//  ChatHeaderView.swift
//
//  Ported from DEV PLAN (UI Iteration 2 Batch 4).
//  Title menu · capability chips · armed-mode glow pills · touchid
//  permissions button · context usage indicator.
//
//  Adapted for NEW DAY: takes simple props instead of ChatViewModel +
//  4 environment objects. Mock state surfaces every visual moment so
//  the user sees the polish without backends behind it.
//

import SwiftUI
import AppKit
import AgentCore

struct ChatHeaderView: View {
    let title: String
    let projectName: String?
    /// Capabilities to render as chips (tool/reason/vision).
    let capabilities: [ModelCapability]
    let worktreeActive: Bool
    /// Settings opt-in. When true, chrome must say Cloud (not local).
    var cloudBotsEnabled: Bool = false
    /// Settings opt-in. When true, chrome must say This Mac (not cloud).
    var computerUseEnabled: Bool = false
    /// Context usage values. Pass nil to hide the chip.
    let contextTokens: Int?
    let contextLimit: Int?

    // ── Title menu actions ──────────────────────────────────────
    // All default to no-ops so the mock chat path keeps working. The
    // real ChatView passes implementations that touch the active
    // conversation / AppViewModel.
    var onRename: (String) -> Void = { _ in }
    var onDuplicate: () -> Void = {}
    var onExportMarkdown: () -> Void = {}
    var onCopyMarkdown: () -> Void = {}
    var worktreeBranch: String? = nil
    var onEnableWorktree: () -> Void = {}
    var onReviewWorktree: () -> Void = {}
    var onDisableWorktree: () -> Void = {}
    var onDelete: () -> Void = {}
    /// Real ChatView passes a closure that writes to `app.safeModeOn`,
    /// which gates whether `apply_patch` surfaces the PatchReviewSheet.
    /// MockChatView leaves it as the default no-op.
    var onSafeModeChanged: (Bool) -> Void = { _ in }

    /// Real ChatView passes a closure that writes to `app.headlessModeOn`,
    /// which makes the next turn run unattended (conservative prologue,
    /// end-of-turn summary, sleep assertion, completion notification).
    var onHeadlessModeChanged: (Bool) -> Void = { _ in }

    /// Safe Mode allow-lists. Real ChatView passes bindings into
    /// `AppViewModel.safeMode*` so edits land in `SafeModeConfig` and
    /// reach `ToolRegistry.checkPermission` on the next agent turn.
    /// MockChatView leaves these as default `.constant([])` bindings —
    /// the sheet still renders, edits are lost on close (acceptable
    /// for the demo path).
    var safeModeAllowedPaths: Binding<[String]> = .constant([])
    var safeModeAllowedShellPrefixes: Binding<[String]> = .constant([])

    /// ZCode-class chrome: title + worktree/permissions only.
    /// Hides capability chips and header context meter (composer owns context).
    var slimChrome: Bool = true

    /// Armed-mode toggles. Start neutral; user clicks pills to activate.
    @State private var safeModeOn = false
    @State private var headlessModeOn = false
    @State private var pulse = false
    @State private var showTitleMenu = false
    @State private var showPermissions = false
    @State private var showRenameSheet = false
    @State private var renameDraft: String = ""
    @State private var showDeleteAlert = false

    private var eitherArmed: Bool { safeModeOn || headlessModeOn }
    private var bothArmed:   Bool { safeModeOn && headlessModeOn }

    var body: some View {
        // Title + dropdown only. Model/mode/context/headless live in
        // Settings or the composer — not the chat chrome.
        HStack(spacing: 8) {
            titleMenu
            Spacer(minLength: 8)
            cloudChip
            computerUseChip
            worktreeChip
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 44)
        .sheet(isPresented: $showRenameSheet) {
            RenameConversationSheet(
                draft: $renameDraft,
                onCancel: { showRenameSheet = false },
                onCommit: { newTitle in
                    showRenameSheet = false
                    onRename(newTitle)
                }
            )
            .frame(minWidth: 360)
        }
        .alert("Delete this conversation?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This will remove \"\(title)\" and its messages from disk. This cannot be undone.")
        }
    }

    // MARK: - Title menu

    private var titleMenu: some View {
        titleMenuButton
            .popover(isPresented: $showTitleMenu, arrowEdge: .bottom) {
                ChatTitleDropdown(
                    onRename: {
                        showTitleMenu = false
                        renameDraft = title
                        showRenameSheet = true
                    },
                    onDuplicate: {
                        showTitleMenu = false
                        onDuplicate()
                    },
                    onExportMarkdown: {
                        showTitleMenu = false
                        onExportMarkdown()
                    },
                    onCopyMarkdown: {
                        showTitleMenu = false
                        onCopyMarkdown()
                    },
                    onEnableWorktree: {
                        showTitleMenu = false
                        onEnableWorktree()
                    },
                    onReviewWorktree: {
                        showTitleMenu = false
                        onReviewWorktree()
                    },
                    onDisableWorktree: {
                        showTitleMenu = false
                        onDisableWorktree()
                    },
                    worktreeOn: worktreeActive,
                    onDelete: {
                        showTitleMenu = false
                        showDeleteAlert = true
                    }
                )
                .background(Theme.Palette.subtle)
            }
    }

    private var titleMenuButton: some View {
        Button { showTitleMenu.toggle() } label: {
            HStack(spacing: 6) {
                if let project = projectName {
                    HStack(spacing: 3) {
                        Image(systemName: "folder.fill").font(.system(size: 9))
                        Text(project)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(Theme.Palette.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.Palette.accent.opacity(0.10))
                    .clipShape(Capsule())

                    Text("/")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                }
                Text(title)
                    .font(.system(size: 20))                    // was 12
                    .foregroundColor(Theme.Palette.tertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold)) // was 9
                    .foregroundColor(Theme.Palette.tertiary)
                    .rotationEffect(.degrees(showTitleMenu ? 180 : 0))
                    .animation(.easeInOut(duration: 0.15), value: showTitleMenu)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: - CloudBots chip (labeled cloud; not a local backend)

    @ViewBuilder
    private var cloudChip: some View {
        if cloudBotsEnabled {
            HStack(spacing: 5) {
                Image(systemName: "cloud")
                    .font(.system(size: 11, weight: .semibold))
                Text(CloudBotCopy.cloudLabel)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.Palette.info)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.Palette.info.opacity(0.14), in: Capsule())
            .help(CloudBotCopy.chipHelp)
            .accessibilityLabel(CloudBotCopy.chipAccessibility)
            .accessibilityIdentifier("cloud-bot-label")
            .layoutPriority(1)
        }
    }

    // MARK: - Computer-use chip (this Mac, not cloud)

    @ViewBuilder
    private var computerUseChip: some View {
        if computerUseEnabled {
            HStack(spacing: 5) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 11, weight: .semibold))
                Text(ComputerUseCopy.macLabel)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.Palette.success)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.Palette.success.opacity(0.14), in: Capsule())
            .help(ComputerUseCopy.chipHelp)
            .accessibilityLabel(ComputerUseCopy.chipAccessibility)
            .accessibilityIdentifier("computer-use-label")
            .layoutPriority(1)
        }
    }

    // MARK: - Worktree chip (visible; do not bury isolation in the title menu)

    @ViewBuilder
    private var worktreeChip: some View {
        if worktreeActive {
            Button(action: onReviewWorktree) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                    Text(worktreeChipLabel)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.Palette.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.Palette.accentSubtle, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Review worktree — merge, discard, or keep isolating. Opens merge/review.")
            .accessibilityLabel("Worktree \(worktreeChipLabel). Review or edit main tree.")
            .layoutPriority(1)
        } else if projectName != nil {
            Button(action: onEnableWorktree) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .medium))
                    Text("Isolate in worktree")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.Palette.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Isolate edits in a git worktree (not the main tree).")
            .accessibilityLabel("Isolate work in git worktree")
            .layoutPriority(1)
        }
    }

    private var worktreeChipLabel: String {
        let raw = worktreeBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return "Worktree" }
        if let short = raw.split(separator: "/").last, !short.isEmpty {
            return String(short)
        }
        return raw
    }

    // MARK: - Pulse

    private func firePulse() {
        withAnimation(.easeIn(duration: 0.15)) { pulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.5)) { pulse = false }
        }
    }
}

// MARK: - Capability chip
//
// `ModelCapability` (the enum) lives in AgentCore. The chip below maps each
// case to a presentation color — that mapping is App-side because AgentCore
// can't import SwiftUI.

private extension ModelCapability {
    var color: Color {
        switch self {
        case .toolCalling: return Theme.Palette.violet
        case .reasoning:   return Theme.Palette.accent
        case .vision:      return Theme.Palette.success
        case .longContext: return Theme.Palette.info
        }
    }
}

struct CapabilityChip: View {
    let capability: ModelCapability
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: capability.icon).font(.system(size: 10))
            Text(capability.rawValue).font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(capability.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(capability.color.opacity(0.08))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(capability.color.opacity(0.20), lineWidth: 0.5))
    }
}

// MARK: - Armed-mode pills (Headless / Safe Mode)
//
// Neutral by default — outline + secondary text. When `isActive` is
// true, fills green and pulses the LED-glow shadow stack. Tapping the
// pill flips its `isActive` via the `onTap` callback.

private struct ArmedModePill: View {
    let icon: String
    let label: String
    let isActive: Bool
    let pulse: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isActive ? Theme.Palette.success : Theme.Palette.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isActive
                    ? Theme.Palette.success.opacity(pulse ? 0.22 : 0.12)
                    : Color.clear
            )
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    isActive
                        ? Theme.Palette.success.opacity(pulse ? 0.6 : 0.35)
                        : Theme.Palette.divider,
                    lineWidth: 0.5
                )
            )
            .shadow(
                color: isActive ? Theme.Palette.success.opacity(pulse ? 1.0 : 0.7) : .clear,
                radius: isActive ? (pulse ? 4 : 1.5) : 0
            )
            .shadow(
                color: isActive ? Theme.Palette.success.opacity(pulse ? 0.75 : 0.4) : .clear,
                radius: isActive ? (pulse ? 8 : 3) : 0
            )
        }
        .buttonStyle(.plain)
        .help(isActive ? "\(label) is on — click to disable" : "\(label) is off — click to enable")
    }
}

// MARK: - Worktree pill

private struct WorktreePill: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
            Text("Worktree")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(Theme.Palette.success)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.Palette.success.opacity(0.10))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.Palette.success.opacity(0.25), lineWidth: 0.5))
    }
}

// MARK: - Context usage indicator

struct ContextUsageIndicator: View {
    let tokens: Int
    let limit: Int

    private var percent: Int {
        guard limit > 0 else { return 0 }
        return Int((Double(tokens) / Double(limit) * 100).rounded())
    }

    private var color: Color {
        switch percent {
        case ..<50:   return Theme.Palette.success
        case 50..<75: return Theme.Palette.warning
        case 75..<90: return Theme.Palette.warning
        default:      return Theme.Palette.error
        }
    }

    private func formatted(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(formatted(tokens)) / \(formatted(limit))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.Palette.tertiary)
            Text("\(percent)%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color.opacity(0.12))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 0.5))
        }
    }
}

// MARK: - Fingerprint permissions button

private struct FingerprintPermissionsButton: View {
    let glowOn: Bool
    var pulse: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "touchid")
                .font(.system(size: 28, weight: .regular))
                .foregroundColor(glowOn ? Theme.Palette.success : Theme.Palette.tertiary)
                .frame(width: 44, height: 44)
                .shadow(color: shadowColor(opacity: pulse ? 1.0 : 0.7),
                        radius: glowOn ? (pulse ? 8 : 3) : 0)
                .shadow(color: shadowColor(opacity: pulse ? 0.75 : 0.4),
                        radius: glowOn ? (pulse ? 16 : 6) : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(glowOn ? "Permissions — a security mode is active" : "Permissions")
    }

    private func shadowColor(opacity: Double) -> Color {
        glowOn ? Theme.Palette.success.opacity(opacity) : .clear
    }
}
