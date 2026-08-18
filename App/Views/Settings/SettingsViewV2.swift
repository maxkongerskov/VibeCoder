// SettingsViewV2.swift
// AgentOS — Claude Edition
//
// macOS-style preferences: grouped sidebar, detail column, fixed chrome.
// Agent tab exposes global system instructions (AppSettings.systemPrompt).

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentCore

// MARK: - Tabs

private enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case agent, skills, subagents, commands, hooks, connection, model, mcp, tools, context, memory, general, privacy, advanced, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agent:      return "Agent"
        case .skills:     return "Skills"
        case .subagents:  return "Subagents"
        case .commands:   return "Commands"
        case .hooks:      return "Hooks"
        case .connection: return "Connection"
        case .model:      return "Model & Backend"
        case .mcp:        return "MCP Servers"
        case .tools:      return "Tools"
        case .context:    return "Context"
        case .memory:     return "Memory"
        case .general:    return "Appearance"
        case .privacy:    return "Privacy"
        case .advanced:   return "Advanced"
        case .about:      return "About"
        }
    }

    var icon: String {
        switch self {
        case .agent:      return "text.bubble.fill"
        case .skills:     return "sparkles"
        case .subagents:  return "person.2"
        case .commands:   return "slash.circle"
        case .hooks:      return "bolt.horizontal.circle"
        case .connection: return "network"
        case .model:      return "cpu"
        case .mcp:        return "server.rack"
        case .tools:      return "wrench.and.screwdriver"
        case .context:    return "rectangle.compress.vertical"
        case .memory:     return "brain.head.profile"
        case .general:    return "paintbrush.fill"
        case .privacy:    return "lock.shield"
        case .advanced:   return "gearshape.2"
        case .about:      return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .agent:      return "Instructions & behavior"
        case .skills:     return "Discover & enable"
        case .subagents:  return "Profiles & tools"
        case .commands:   return "Markdown /commands"
        case .hooks:      return "Lifecycle events"
        case .connection: return "Local servers & APIs"
        case .model:      return "Providers & sampling"
        case .mcp:        return "External tools"
        case .tools:      return "Built-in capabilities"
        case .context:    return "Window & compact"
        case .memory:     return "MEMORY & DECISIONS"
        case .general:    return "Theme & type"
        case .privacy:    return "Data & backup"
        case .advanced:   return "Chrome filter & debug"
        case .about:      return "Version & credits"
        }
    }

    /// Sidebar grouping (macOS Settings style).
    enum Group: String, CaseIterable {
        case agent = "Agent"
        case models = "Models & network"
        case workspace = "Workspace"
        case system = "System"
    }

    var group: Group {
        switch self {
        case .agent, .skills, .subagents, .commands, .hooks: return .agent
        case .connection, .model, .mcp: return .models
        case .tools, .context, .memory: return .workspace
        case .general, .privacy, .advanced, .about: return .system
        }
    }

    static func tabs(in group: Group) -> [SettingsTab] {
        allCases.filter { $0.group == group }
    }
}

/// Deep-link / test IDs matching private `SettingsTab.rawValue`.
enum SettingsManagersTabID {
    static let skills = SettingsTab.skills.rawValue
    static let subagents = SettingsTab.subagents.rawValue
    static let commands = SettingsTab.commands.rawValue
    static var allRawValues: [String] { SettingsTab.allCases.map(\.rawValue) }
}

// MARK: - Settings shell

struct SettingsViewV2: View {
    @Binding var settings: AppSettings

    var onDismiss: (() -> Void)? = nil
    /// Optional deep-link tab id (e.g. "mcp" from `/mcps`, "agent" for instructions).
    var initialTabRaw: String? = nil

    @State private var selectedTab: SettingsTab = .agent
    @State private var searchText: String = ""

    /// Prefs sheet ideal size (System Settings–inspired). RootView must not
    /// force a smaller frame or the sidebar/footer will clip.
    private let windowWidth: CGFloat = 980
    private let windowHeight: CGFloat = 700
    private let navWidth: CGFloat = 228

    private var filteredTabs: [SettingsTab] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return SettingsTab.allCases }
        return SettingsTab.allCases.filter {
            $0.label.lowercased().contains(q)
                || $0.subtitle.lowercased().contains(q)
                || $0.rawValue.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider().opacity(0.4)

            HStack(alignment: .top, spacing: 0) {
                navColumn
                    .frame(width: navWidth)
                    .frame(maxHeight: .infinity, alignment: .top)

                Divider().opacity(0.4)

                VStack(spacing: 0) {
                    detailHeader
                    detailColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    footerBar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(
            minWidth: 920, idealWidth: windowWidth, maxWidth: 1100,
            minHeight: 620, idealHeight: windowHeight, maxHeight: 820
        )
        .background(Theme.Palette.canvas)
        .onAppear {
            if let raw = initialTabRaw,
               let tab = SettingsTab(rawValue: raw) {
                selectedTab = tab
            }
        }
    }

    // MARK: - Header / footer

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.Palette.accent.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Settings")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primary)
                Text("Configure \(AppBranding.displayName) for your Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
            }

            Spacer(minLength: 16)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.tertiary)
                TextField("Search settings", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .frame(width: 168)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.Palette.subtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.Palette.canvas)
    }

    private var detailHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: selectedTab.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.Palette.accent.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedTab.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primary)
                Text(selectedTab.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(Theme.Palette.canvas)
    }

    private var footerBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Close") {
                if let onDismiss {
                    onDismiss()
                } else {
                    NSApp.keyWindow?.close()
                }
            }
            .keyboardShortcut(.cancelAction)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.accent)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Theme.Palette.canvas.opacity(0.98))
        .overlay(alignment: .top) {
            Divider().opacity(0.35)
        }
    }

    // MARK: - Nav

    private var navColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(SettingsTab.Group.allCases, id: \.self) { group in
                        let tabs = SettingsTab.tabs(in: group)
                        if !tabs.isEmpty {
                            navGroup(title: group.rawValue, tabs: tabs)
                        }
                    }
                } else {
                    navGroup(title: "Results", tabs: filteredTabs)
                    if filteredTabs.isEmpty {
                        Text("No matching settings")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.subtle)
    }

    private func navGroup(title: String, tabs: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.tertiary)
                .tracking(0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)

            ForEach(tabs) { tab in
                navButton(tab)
            }
        }
    }

    private func navButton(_ tab: SettingsTab) -> some View {
        let on = selectedTab == tab
        return Button {
            withAnimation(Theme.Motion.quick) { selectedTab = tab }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, alignment: .center)
                    .foregroundStyle(on ? Theme.Palette.accent : Theme.Palette.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.label)
                        .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.Palette.primary : Theme.Palette.secondary)
                        .lineLimit(1)
                    Text(tab.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(on ? Theme.Palette.accent.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(on ? Theme.Palette.accent.opacity(0.22) : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.label)
    }

    // MARK: - Detail

    private var detailColumn: some View {
        ScrollView(.vertical, showsIndicators: true) {
            detailContent
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .foregroundStyle(Theme.Palette.primary)
        }
        .background(Theme.Palette.canvas)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .agent:      AgentInstructionsSettingsView(settings: $settings)
        case .skills:     SkillsSettingsView()
        case .subagents:  SubagentsSettingsView()
        case .commands:   CommandsSettingsView()
        case .hooks:      HooksSettingsView()
        case .general:    GeneralSettingsView(settings: $settings)
        case .connection: ConnectionSettingsView(settings: $settings)
        case .model:      ModelBackendSettingsView(settings: $settings)
        case .mcp:        MCPServersSettingsView(settings: $settings)
        case .tools:      ToolsSettingsView(settings: $settings)
        case .context:    ContextSettingsView(settings: $settings)
        case .memory:     ProjectMemorySettingsView()
        case .privacy:    PrivacySettingsView(settings: $settings)
        case .advanced:   AdvancedSettingsView(settings: $settings)
        case .about:      AboutView()
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    @Binding var settings: AppSettings
    @EnvironmentObject private var app: AppViewModel

    @State private var backupStatus: String = ""
    @State private var backupStatusIsError: Bool = false
    @State private var showClearAllConfirm: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            settingsCard {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                        .foregroundColor(Theme.Palette.accent)
                    Text("Privacy")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("Local-first: loopback model servers keep chat on this Mac. Custom remote /v1 endpoints, cloud API keys, MCP tools, and agent shell/network commands can send data off-box — only when you configure or allow them. See LEGAL.md.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("App Sandbox is off (full-trust agent). Local API defaults to completions proxy (tools empty); agent-loop is opt-in.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Report an issue…") {
                    if let url = URL(string: "https://github.com/maxkongerskov/VibeCoder/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(Theme.Palette.accent)
            }

            settingsCard {
                HStack(spacing: 6) {
                    Image(systemName: "archivebox")
                        .foregroundColor(Theme.Palette.accent)
                    Text("Conversation Backup")
                        .font(.system(size: 13, weight: .semibold))
                }
                HStack(spacing: Theme.Spacing.s) {
                    Button("Export…") { exportConversations() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Import…") { importConversations() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Clear All…") { showClearAllConfirm = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                }
                Text("Export writes every conversation to a single JSON file. Import merges conversations from such a file.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                if !backupStatus.isEmpty {
                    Text(backupStatus)
                        .font(.system(size: 11))
                        .foregroundColor(backupStatusIsError ? .red : Theme.Palette.accent)
                }
            }
            .confirmationDialog("Delete all conversations?",
                                isPresented: $showClearAllConfirm,
                                titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    app.deleteAllConversations()
                    backupStatusIsError = false
                    backupStatus = "All conversations deleted."
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes every conversation from this Mac. This cannot be undone. Export first if you want a backup.")
            }
        }
    }

    private func exportConversations() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "agentos-conversations.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let all = try await ConversationStore.shared.list()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(all)
                try data.write(to: url, options: .atomic)
                backupStatusIsError = false
                backupStatus = "Exported \(all.count) conversation\(all.count == 1 ? "" : "s")."
            } catch {
                backupStatusIsError = true
                backupStatus = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func importConversations() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let data = try Data(contentsOf: url)
                let convos = try JSONDecoder().decode([Conversation].self, from: data)
                for c in convos { try await ConversationStore.shared.save(c) }
                await app.refreshConversations()
                backupStatusIsError = false
                backupStatus = "Imported \(convos.count) conversation\(convos.count == 1 ? "" : "s")."
            } catch {
                backupStatusIsError = true
                backupStatus = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - About

struct AboutView: View {
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    private let credits: [(name: String, role: String)] = [
        ("Max Køngerskov", "Design & Engineering"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            settingsCard {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(Theme.Palette.accent)
                    Text(AppBranding.displayName)
                        .font(.system(size: 13, weight: .semibold))
                }
                HStack(spacing: Theme.Spacing.xs) {
                    Text("Version \(appVersion)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.secondary)
                    Text("·")
                        .foregroundColor(Theme.Palette.tertiary)
                    Text("Build \(buildNumber)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.secondary)
                }
                Text("Local-first coding agent for macOS.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.secondary)
            }

            settingsCard {
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .foregroundColor(Theme.Palette.accent)
                    Text("Credits")
                        .font(.system(size: 13, weight: .semibold))
                }
                ForEach(credits, id: \.name) { credit in
                    HStack {
                        Text(credit.name)
                            .font(.system(size: 12))
                        Spacer()
                        Text(credit.role)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Palette.tertiary)
                    }
                }
            }

            settingsCard {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .foregroundColor(Theme.Palette.accent)
                    Text("Legal")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("© 2026 Max Køngerskov. All rights reserved.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
            }
        }
    }
}

// MARK: - Shared card

// `settingsCard` is the single card surface for every settings pane.
//
// Contract:
//   • `Theme.Palette.subtle` fill
//   • Hairline `Theme.Palette.divider` stroke
//   • `Theme.Radius.card` corner radius
//   • Full-width frame — never half-cards, regardless of content size
//
// `internal` so every settings view in the App target can call it.

@ViewBuilder
func settingsCard<Content: View>(
    @ViewBuilder _ content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
        content()
    }
    .padding(Theme.Spacing.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
        RoundedRectangle(cornerRadius: Theme.Radius.card)
            .fill(Theme.Palette.subtle)
    )
    .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.card)
            .stroke(Theme.Palette.divider, lineWidth: 0.5)
    )
}

// MARK: - Preview

#if DEBUG
extension AppSettings {
    static let `default` = AppSettings()
}

struct SettingsViewV2_Previews: PreviewProvider {
    static var previews: some View {
        SettingsViewV2(settings: .constant(.default))
            .frame(width: 980, height: 700)
    }
}
#endif
