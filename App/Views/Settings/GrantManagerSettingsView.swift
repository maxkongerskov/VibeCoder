//
//  GrantManagerSettingsView.swift
//
//  Phase C PC1 — Settings section: list Always/Never grants, revoke,
//  and show file-loaded PermissionRules paths.
//

import SwiftUI
import AgentCore

struct GrantManagerSettingsView: View {
    @EnvironmentObject private var app: AppViewModel
    @StateObject private var model = GrantManagerViewModel()

    var body: some View {
        settingsCard {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(Theme.Palette.accent)
                Text("Remembered grants")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Reload Always/Never grants from disk")
                .disabled(model.isBusy)
            }

            Text(SettingsDiscoverabilityCopy.grantsIntro)
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = model.persistError, !err.isEmpty {
                Text("Disk persist warning: \(err)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.items.isEmpty {
                Text(SettingsDiscoverabilityCopy.grantsEmpty)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.items) { item in
                        grantRow(item)
                    }
                }

                HStack(spacing: 8) {
                    Button("Clear all…") {
                        Task { await model.clearAll() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isBusy || model.items.isEmpty)
                    .help("Remove every Always/Never grant for all projects")

                    if let root = app.openedProject?.url.path {
                        Button("Clear this project") {
                            Task { await model.clearProject(root) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isBusy)
                    }
                }
            }

            if let status = model.statusMessage {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.secondary)
            }

            Divider().opacity(0.4)

            // File-loaded rules summary (not the same as durable Always/Never).
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundColor(Theme.Palette.accent)
                Text("Permission rule files")
                    .font(.system(size: 12, weight: .semibold))
            }

            Text(model.rulesSummaryText.isEmpty
                 ? "Open a project to scan for permission rule files (.vibecoder/permissions.json and related)."
                 : model.rulesSummaryText)
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if model.rulesSourcePaths.isEmpty {
                Text("No rule files found (home + project: .vibecoder / .agentos permissions.json, .claude/settings.json). That is normal if you only use Always/Never prompts.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.rulesSourcePaths, id: \.self) { path in
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.Palette.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Text("File rules seed deny/allow lists each turn. They are not the Always/Never list above — edit the JSON on disk to change them. Revoke only affects remembered Always/Never grants.")
                .font(.system(size: 10))
                .foregroundColor(Theme.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: app.openedProject?.url.path) {
            model.projectRoot = app.openedProject?.url
            await model.reload()
        }
    }

    @ViewBuilder
    private func grantRow(_ item: GrantListItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.decisionLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (item.decision == .allow
                             ? Theme.Palette.success
                             : Theme.Palette.error).opacity(0.15)
                        )
                        .foregroundColor(
                            item.decision == .allow
                            ? Theme.Palette.success
                            : Theme.Palette.error
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Palette.primary)
                        .lineLimit(1)
                }
                Text(item.subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.Palette.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Revoke") {
                Task { await model.revoke(item) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isBusy)
        }
        .padding(.vertical, 4)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.Palette.divider, lineWidth: 0.5)
        )
    }
}
