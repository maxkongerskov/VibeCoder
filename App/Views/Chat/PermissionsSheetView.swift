// PermissionsSheetView.swift
// AgentOS — Claude Edition
//
// Safe Mode editor sheet. Reached via the fingerprint button in
// ChatHeaderView. Manages path + shell-command allowlists plus
// the Safe Mode and Headless mode armed-mode toggles.
//
// Ported from DEV PLAN (AgentOS/Views/Chat/PermissionsSheetView.swift).
// DEV PLAN removals: ChatViewModel / ToolPermissions bindings, worktree
// section, project-folder picker — all replaced by local @State mock
// data per the NEW DAY prop-based pattern.

import SwiftUI
import AgentCore

struct PermissionsSheetView: View {
    @Binding var safeModeOn: Bool
    @Binding var headlessModeOn: Bool
    /// Path + shell allow-lists. ChatView passes bindings into
    /// `AppViewModel.safeMode*` so edits land in the conversation's
    /// real `SafeModeConfig`. MockChatView passes `.constant(...)`
    /// so the visual state still works without an AppViewModel.
    @Binding var allowedPaths: [String]
    @Binding var shellPrefixes: [String]
    var onDismiss: () -> Void

    @State private var newPath: String = ""
    @State private var newShellPrefix: String = ""

    @State private var addingPath: Bool = false
    @State private var addingShell: Bool = false

    // Glow pulse — fires when the second mode is enabled while the sheet
    // is open. Mirrors the 0.65 s swell in ChatHeaderView.
    @State private var pulse: Bool = false

    private var eitherOn: Bool { safeModeOn || headlessModeOn }
    private var bothOn:   Bool { safeModeOn && headlessModeOn }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().foregroundColor(Theme.Palette.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.ml) {
                    modeTogglesSection
                    if safeModeOn {
                        pathsSection
                        shellSection
                        changesNote
                    } else {
                        offHint
                    }
                }
                .padding(Theme.Spacing.l)
            }
            Divider().foregroundColor(Theme.Palette.divider)
            footerBar
        }
        .frame(width: 700, height: 600)
        .background(Theme.Palette.canvas)
        .onChange(of: bothOn) { _, isOn in
            if isOn { firePulse() }
        }
    }

    // MARK: - Pulse animation

    private func firePulse() {
        withAnimation(.easeIn(duration: 0.15)) { pulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.5)) { pulse = false }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "touchid")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(eitherOn ? Theme.Palette.success : Theme.Palette.tertiary)
                .shadow(
                    color: eitherOn
                        ? Theme.Palette.success.opacity(pulse ? 1.0 : 0.7)
                        : .clear,
                    radius: eitherOn ? (pulse ? 4 : 1.5) : 0
                )
                .shadow(
                    color: eitherOn
                        ? Theme.Palette.success.opacity(pulse ? 0.75 : 0.4)
                        : .clear,
                    radius: eitherOn ? (pulse ? 8 : 3) : 0
                )
            Text("Permissions")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.Palette.primary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Palette.tertiary)
                    .frame(width: 24, height: 24)
                    .background(Theme.Palette.subtle)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, Theme.Spacing.ml)
        .padding(.vertical, Theme.Spacing.m)
    }

    // MARK: - Mode toggles section

    private var modeTogglesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionLabel(icon: "shield.lefthalf.filled", title: "Run Modes")

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                // Safe Mode toggle
                modeToggleRow(
                    icon: "shield.lefthalf.filled",
                    label: "Safe Mode",
                    isOn: $safeModeOn,
                    description: "When ON, the agent can only touch the filesystem within paths you list and only run shell commands that start with allowed prefixes. Empty list = nothing allowed."
                )

                Divider().foregroundColor(Theme.Palette.divider)

                // Headless mode toggle
                modeToggleRow(
                    icon: "moon.zzz.fill",
                    label: "Headless",
                    isOn: $headlessModeOn,
                    description: "Treat this conversation as unattended. The agent is told to be conservative with destructive actions and a markdown summary is appended at the end of each turn."
                )
            }
            .padding(Theme.Spacing.m)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func modeToggleRow(
        icon: String,
        label: String,
        isOn: Binding<Bool>,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                // LED pill — mirrors ArmedModePill from ChatHeaderView
                PermissionsArmedPill(
                    icon: icon,
                    label: label,
                    isActive: isOn.wrappedValue,
                    pulse: pulse
                )
                Spacer()
                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text(description)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Path allowlist section

    private var pathsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionLabel(icon: "folder", title: "Allowed Filesystem Paths")

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Agent may read/write/list/delete within these paths and their descendants.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)

                if allowedPaths.isEmpty {
                    Text("No paths allowed. The agent cannot touch the filesystem in this state.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.warning)
                        .padding(.vertical, Theme.Spacing.xs)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(allowedPaths, id: \.self) { path in
                            PermissionsAllowlistRow(text: path) {
                                allowedPaths.removeAll { $0 == path }
                            }
                        }
                    }
                }

                if addingPath {
                    HStack(spacing: Theme.Spacing.xs) {
                        TextField("~/code/myproject", text: $newPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { commitPath() }
                        Button("Add") { commitPath() }
                            .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") {
                            newPath = ""
                            addingPath = false
                        }
                        .foregroundColor(Theme.Palette.tertiary)
                    }
                } else {
                    Button("+ Add path...") { addingPath = true }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Palette.accent)
                        .buttonStyle(.plain)
                }
            }
            .padding(Theme.Spacing.m)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
        }
    }

    private func commitPath() {
        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !allowedPaths.contains(trimmed) {
            allowedPaths.append(trimmed)
        }
        newPath = ""
        addingPath = false
    }

    // MARK: - Shell command allowlist section

    private var shellSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionLabel(icon: "terminal", title: "Allowed Shell Command Prefixes")

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Each entry matches commands that begin with that exact text (e.g. \"git\" allows \"git status\", \"git push\"\u{2026}).")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)

                if shellPrefixes.isEmpty {
                    Text("No shell commands allowed. The agent cannot run anything via run_shell_command in this state.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.warning)
                        .padding(.vertical, Theme.Spacing.xs)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(shellPrefixes, id: \.self) { prefix in
                            PermissionsAllowlistRow(text: prefix) {
                                shellPrefixes.removeAll { $0 == prefix }
                            }
                        }
                    }
                }

                if addingShell {
                    HStack(spacing: Theme.Spacing.xs) {
                        TextField("swift build", text: $newShellPrefix)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { commitShellPrefix() }
                        Button("Add") { commitShellPrefix() }
                            .disabled(newShellPrefix.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") {
                            newShellPrefix = ""
                            addingShell = false
                        }
                        .foregroundColor(Theme.Palette.tertiary)
                    }
                } else {
                    Button("+ Add command...") { addingShell = true }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Palette.accent)
                        .buttonStyle(.plain)
                }
            }
            .padding(Theme.Spacing.m)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
        }
    }

    private func commitShellPrefix() {
        let trimmed = newShellPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !shellPrefixes.contains(trimmed) {
            shellPrefixes.append(trimmed)
        }
        newShellPrefix = ""
        addingShell = false
    }

    // MARK: - Off hint + explainer

    private var offHint: some View {
        Text("Safe Mode is OFF \u{2014} the agent has the same access as the user running \(AppBranding.displayName). Enable it to constrain what the agent can do (e.g. headless runs, untrusted prompts).")
            .font(.system(size: 12))
            .foregroundColor(Theme.Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Theme.Spacing.m)
            .background(Theme.Palette.subtle)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var changesNote: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text("Changes take effect on your next message.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
            Text("The agent is told about these rules in its system prompt so it plans within scope rather than discovering blocks by trial-and-error.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onDismiss)
                .keyboardShortcut(.cancelAction)
            Button("Save", action: onDismiss)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, Theme.Spacing.ml)
        .padding(.vertical, Theme.Spacing.m)
    }

    // MARK: - Helpers

    private func sectionLabel(icon: String, title: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.Palette.accent)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.Palette.primary)
        }
    }
}

// MARK: - PermissionsArmedPill
//
// Read-only display pill that mirrors ChatHeaderView's ArmedModePill look.
// Non-interactive here (the sheet uses a Toggle switch instead of tap-to-toggle).

private struct PermissionsArmedPill: View {
    let icon: String
    let label: String
    let isActive: Bool
    let pulse: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(isActive ? Theme.Palette.success : Theme.Palette.secondary)
        .padding(.horizontal, Theme.Spacing.s)
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
}

// MARK: - PermissionsAllowlistRow
//
// Single path or shell-prefix chip with monospaced label and remove button.

private struct PermissionsAllowlistRow: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(Theme.Palette.success)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.Palette.primary)
                .lineLimit(1)
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, 5)
        .background(Theme.Palette.subtle)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
    }
}
