//
//  SkillsSettingsView.swift
//  Settings → Skills: discover SKILL.md packages and enable/disable via frontmatter.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentCore

struct SkillsSettingsView: View {
    @EnvironmentObject private var app: AppViewModel

    private enum Scope: String, CaseIterable, Identifiable {
        case project
        case user
        var id: String { rawValue }
        var label: String {
            switch self {
            case .project: return "Project"
            case .user: return "User"
            }
        }
    }

    private enum Availability: String, CaseIterable, Identifiable {
        case all
        case enabled
        case disabled
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .enabled: return "Enabled"
            case .disabled: return "Disabled"
            }
        }
    }

    @State private var scope: Scope = .project
    @State private var projectRoot: URL?
    @State private var skills: [DiscoveredSkill] = []
    @State private var searchText: String = ""
    @State private var availability: Availability = .all
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var showingNewSkill = false

    private var activeRoot: URL? {
        switch scope {
        case .project:
            guard let projectRoot else { return nil }
            return SettingsManagersPaths.projectSkillsRoot(projectRoot)
        case .user:
            return SettingsManagersPaths.userSkillsRoot()
        }
    }

    private var canWrite: Bool {
        switch scope {
        case .project: return projectRoot != nil
        case .user: return true
        }
    }

    private var filteredSkills: [DiscoveredSkill] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return skills.filter { skill in
            switch availability {
            case .all: break
            case .enabled:
                if !skill.isModelInvocable { return false }
            case .disabled:
                if skill.isModelInvocable { return false }
            }
            guard !query.isEmpty else { return true }
            return skill.name.lowercased().contains(query)
                || skill.description.lowercased().contains(query)
        }
    }

    private var diskSkills: [DiscoveredSkill] {
        filteredSkills.filter { $0.source != .bundled }
    }

    private var bundledSkills: [DiscoveredSkill] {
        filteredSkills.filter { $0.source == .bundled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Skills")
                    .font(.system(size: 16, weight: .semibold))
                Text("Discover SKILL.md packages the agent can load. Disk is the source of truth — enabling rewrites frontmatter, it does not keep a parallel store.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Scope", selection: $scope) {
                ForEach(Scope.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)

            pathRow

            if scope == .project && projectRoot == nil {
                Text("No project open. Open a project from the sidebar or switch to User to create personal skills.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            filterBar

            actionRow

            if filteredSkills.isEmpty {
                emptyState
            } else {
                if !diskSkills.isEmpty {
                    skillSection(title: "Workspace and personal skills", rows: diskSkills)
                }
                if !bundledSkills.isEmpty {
                    skillSection(title: "Bundled", rows: bundledSkills)
                }
            }

            if let statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(statusIsError ? Theme.Palette.error : Theme.Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.s)
        .onAppear { refreshProjectRoot(); reload() }
        .onChange(of: app.selectedConversationID) { _, _ in
            refreshProjectRoot()
            reload()
        }
        .onChange(of: app.openedProject?.id) { _, _ in
            refreshProjectRoot()
            reload()
        }
        .sheet(isPresented: $showingNewSkill) {
            NewSkillSheet(
                defaultScopeLabel: scope.label,
                onSave: { name, description, body in
                    createSkill(name: name, description: description, body: body)
                },
                onCancel: { showingNewSkill = false }
            )
        }
    }

    // MARK: - Chrome

    private var pathRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.tertiary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(activeRoot?.path ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            Button("Reveal in Finder") { openSkillsFolder() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(activeRoot == nil)
        }
    }

    private var filterBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.tertiary)
                TextField("Search skills", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.Palette.canvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )

            Picker("Filter", selection: $availability) {
                ForEach(Availability.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
        }
    }

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                showingNewSkill = true
            } label: {
                Label("New skill", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canWrite)

            Button {
                importSkill()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canWrite)

            Button {
                openSkillsFolder()
            } label: {
                Label("Open skills folder", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(activeRoot == nil)

            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: Theme.Spacing.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundColor(Theme.Palette.tertiary.opacity(0.5))
            Text("No skills found")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Palette.tertiary)
            Text("Create a skill, import a SKILL.md package, or clear the search filter.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
    }

    private func skillSection(title: String, rows: [DiscoveredSkill]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Palette.tertiary)
            ForEach(rows) { skill in
                SkillSettingsRow(
                    skill: skill,
                    canToggle: skill.source != .bundled && skill.fileURL != nil,
                    onToggle: { enabled in setEnabled(skill, enabled: enabled) },
                    onReveal: {
                        if let url = skill.fileURL {
                            SettingsManagersPaths.reveal(url)
                        }
                    }
                )
            }
        }
    }

    // MARK: - Actions

    private func refreshProjectRoot() {
        if let id = app.selectedConversationID,
           let conv = app.conversations.first(where: { $0.id == id }),
           let root = conv.projectRoot {
            projectRoot = root
            return
        }
        projectRoot = app.openedProject?.url
    }

    private func reload() {
        skills = SkillDiscovery.discover(
            projectRoot: projectRoot,
            includeBundled: true,
            metadataOnly: true
        )
        statusMessage = nil
        statusIsError = false
    }

    private func setEnabled(_ skill: DiscoveredSkill, enabled: Bool) {
        guard skill.source != .bundled, let url = skill.fileURL else { return }
        do {
            try SkillFrontmatterWriter.applyDisableModelInvocation(at: url, disabled: !enabled)
            statusIsError = false
            statusMessage = nil
            reload()
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func createSkill(name: String, description: String, body: String) {
        guard let root = activeRoot else {
            statusIsError = true
            statusMessage = SettingsManagersError.noProject.localizedDescription
            return
        }
        do {
            _ = try SkillFrontmatterWriter.writeNewSkill(
                name: name,
                description: description,
                body: body,
                root: root
            )
            showingNewSkill = false
            statusIsError = false
            statusMessage = "Created \(SettingsManagersNaming.slugify(name))."
            reload()
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func importSkill() {
        guard let root = activeRoot else {
            statusIsError = true
            statusMessage = SettingsManagersError.noProject.localizedDescription
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose a SKILL.md file or a skill folder"
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown, .folder]
        } else {
            panel.allowedContentTypes = [.item, .folder]
        }
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        do {
            let dest = try SkillFrontmatterWriter.importSkill(from: picked, into: root)
            statusIsError = false
            statusMessage = "Imported \(dest.deletingLastPathComponent().lastPathComponent)."
            reload()
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func openSkillsFolder() {
        guard let root = activeRoot else { return }
        SettingsManagersPaths.reveal(root)
    }
}

// MARK: - Row

private struct SkillSettingsRow: View {
    let skill: DiscoveredSkill
    let canToggle: Bool
    let onToggle: (Bool) -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Palette.primary)
                    scopeBadge
                }
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { skill.isModelInvocable },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .controlSize(.small)
            .disabled(!canToggle)
            .help(canToggle
                  ? "Enabled for the model (`disable-model-invocation`)"
                  : "Bundled skills are read-only. Duplicate to User to customize.")
            if skill.fileURL != nil {
                Button(action: onReveal) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Reveal SKILL.md")
            }
        }
        .padding(Theme.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Palette.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
    }

    private var scopeBadge: some View {
        Text(scopeLabel)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(Theme.Palette.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Theme.Palette.canvas)
            )
            .overlay(
                Capsule().stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
    }

    private var scopeLabel: String {
        switch skill.source {
        case .project: return "Project"
        case .user: return "User"
        case .bundled: return "Bundled"
        }
    }
}

// MARK: - New skill

private struct NewSkillSheet: View {
    let defaultScopeLabel: String
    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var instructions: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("New Skill")
                .font(.system(size: 14, weight: .semibold))
            Text("Creates a SKILL.md package in the \(defaultScopeLabel.lowercased()) skills folder.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            labeledField("Name", text: $name, placeholder: "code-review")
            labeledField("Description", text: $description, placeholder: "When to load this skill")

            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions")
                    .font(.system(size: 11, weight: .medium))
                TextEditor(text: $instructions)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.Palette.canvas)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Theme.Palette.divider, lineWidth: 0.5)
                    )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Palette.error)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Create") { validateAndSave() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(width: 480)
    }

    @ViewBuilder
    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func validateAndSave() {
        let slug = SettingsManagersNaming.slugify(name)
        guard SettingsManagersNaming.isValidName(slug) else {
            errorMessage = SettingsManagersError.invalidName.localizedDescription
            return
        }
        errorMessage = nil
        onSave(slug, description, instructions)
    }
}

#if DEBUG
struct SkillsSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SkillsSettingsView()
            .environmentObject(AppViewModel())
            .padding()
            .frame(width: 560, height: 640)
    }
}
#endif
