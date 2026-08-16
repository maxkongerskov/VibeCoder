//
//  SubagentsSettingsView.swift
//  Settings → Subagents: user / workspace markdown profiles + built-in types.
//

import SwiftUI
import AppKit
import AgentCore

struct SubagentsSettingsView: View {
    @EnvironmentObject private var app: AppViewModel

    private enum Scope: String, CaseIterable, Identifiable {
        case project
        case user
        var id: String { rawValue }
        var label: String {
            switch self {
            case .project: return "Workspace"
            case .user: return "User"
            }
        }
    }

    @State private var projectRoot: URL?
    @State private var userProfiles: [DiscoveredAgentDefinition] = []
    @State private var workspaceProfiles: [DiscoveredAgentDefinition] = []
    @State private var searchText: String = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var editor: SubagentEditorItem?
    @State private var pendingDelete: PendingDelete?

    private var userRoot: URL { SettingsManagersPaths.userAgentsRoot() }
    private var workspaceRoot: URL? {
        projectRoot.map { SettingsManagersPaths.projectAgentsRoot($0) }
    }

    private var filteredUser: [DiscoveredAgentDefinition] {
        filterProfiles(userProfiles)
    }

    private var filteredWorkspace: [DiscoveredAgentDefinition] {
        filterProfiles(workspaceProfiles)
    }

    private var filteredBuiltIns: [SubagentType] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return SubagentType.allCases }
        return SubagentType.allCases.filter {
            $0.rawValue.lowercased().contains(query)
                || $0.shortDescription.lowercased().contains(query)
        }
    }

    private var visibleCount: Int {
        filteredUser.count + filteredWorkspace.count + filteredBuiltIns.count
    }

    private var totalCount: Int {
        userProfiles.count + workspaceProfiles.count + SubagentType.allCases.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Subagents")
                    .font(.system(size: 16, weight: .semibold))
                Text("Markdown profiles spawned by the `task` tool. Workspace files are editable here — a VibeCoder advantage over ZCode.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.tertiary)
                TextField("Search subagents", text: $searchText)
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

            actionRow

            if visibleCount == 0 {
                emptyState
            } else {
                if !filteredUser.isEmpty {
                    profileSection(title: "User", rows: filteredUser, scope: .user)
                }
                if !filteredWorkspace.isEmpty {
                    profileSection(title: "Workspace", rows: filteredWorkspace, scope: .project)
                }
                if !filteredBuiltIns.isEmpty {
                    builtInSection
                }
            }

            Text("\(totalCount) subagents")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)

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
        .sheet(item: $editor) { item in
            SubagentEditorSheet(
                item: item,
                projectAvailable: projectRoot != nil,
                onSave: { saved in commit(saved) },
                onCancel: { editor = nil }
            )
        }
        .alert(
            "Delete subagent?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete { delete(row) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes \(pendingDelete?.name ?? "the profile") from disk. Running sessions are not affected.")
        }
    }

    // MARK: - Sections

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                startAdd()
            } label: {
                Label("New", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                SettingsManagersPaths.reveal(userRoot)
            } label: {
                Label("Open user subagents folder", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: Theme.Spacing.s) {
            Image(systemName: "person.2")
                .font(.system(size: 32))
                .foregroundColor(Theme.Palette.tertiary.opacity(0.5))
            Text("No subagents found")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Palette.tertiary)
            Text("Create a profile or clear the search filter.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
    }

    private func profileSection(
        title: String,
        rows: [DiscoveredAgentDefinition],
        scope: Scope
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Palette.tertiary)
            ForEach(rows) { def in
                SubagentSettingsRow(
                    name: def.name,
                    description: def.description,
                    detail: diskDetail(def),
                    readOnly: false,
                    onEdit: { startEdit(def, scope: scope) },
                    onDelete: {
                        pendingDelete = PendingDelete(
                            name: def.name,
                            fileURL: def.fileURL
                        )
                    }
                )
            }
        }
    }

    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Built-in")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Palette.tertiary)
            Text("Built-in profiles are runtime defaults and cannot be edited here.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(filteredBuiltIns, id: \.rawValue) { type in
                SubagentSettingsRow(
                    name: type.displayName,
                    description: type.shortDescription,
                    detail: "Tools: \(builtInToolsLabel(type))",
                    readOnly: true,
                    onEdit: {},
                    onDelete: {}
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
        userProfiles = SubagentProfileCodec.loadDirectory(userRoot)
        if let workspaceRoot {
            workspaceProfiles = SubagentProfileCodec.loadDirectory(workspaceRoot)
        } else {
            workspaceProfiles = []
        }
        statusMessage = nil
        statusIsError = false
    }

    private func filterProfiles(_ list: [DiscoveredAgentDefinition]) -> [DiscoveredAgentDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return list }
        return list.filter {
            $0.name.lowercased().contains(query)
                || $0.description.lowercased().contains(query)
        }
    }

    private func diskDetail(_ def: DiscoveredAgentDefinition) -> String {
        var parts: [String] = []
        if let model = def.model, !model.isEmpty {
            parts.append(model)
        }
        if def.tools.isEmpty {
            parts.append("Inherit all tools")
        } else {
            parts.append("Tools: \(def.tools.joined(separator: ", "))")
        }
        if let maxTurns = def.maxTurns {
            parts.append("\(maxTurns) turns")
        }
        if def.background == true {
            parts.append("Background")
        }
        return parts.joined(separator: " · ")
    }

    private func builtInToolsLabel(_ type: SubagentType) -> String {
        type.preferredTools.sorted().joined(separator: ", ")
    }

    private func startAdd() {
        editor = SubagentEditorItem(
            isNew: true,
            scope: .user,
            originalURL: nil,
            draft: SubagentProfileDraft(
                systemPrompt: "Complete the assigned task directly."
            )
        )
    }

    private func startEdit(_ def: DiscoveredAgentDefinition, scope: Scope) {
        let draft: SubagentProfileDraft
        if let url = def.fileURL, let loaded = SubagentProfileCodec.draft(from: url) {
            draft = loaded
        } else {
            draft = SubagentProfileDraft(definition: def, inheritAllTools: def.tools.isEmpty)
        }
        editor = SubagentEditorItem(
            isNew: false,
            scope: scope == .project ? .project : .user,
            originalURL: def.fileURL,
            draft: draft
        )
    }

    private func commit(_ item: SubagentEditorItem) {
        do {
            let name = item.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let directory: URL
            switch item.scope {
            case .user:
                directory = userRoot
            case .project:
                guard let workspaceRoot else { throw SettingsManagersError.noProject }
                directory = workspaceRoot
            }
            let dest = SubagentProfileCodec.fileURL(name: name, directory: directory)
            try SubagentProfileCodec.write(item.draft, to: dest)
            if let original = item.originalURL,
               original.standardizedFileURL.path != dest.standardizedFileURL.path {
                try? FileManager.default.removeItem(at: original)
            }
            editor = nil
            statusIsError = false
            statusMessage = item.isNew ? "Created \(name)." : "Saved \(name)."
            reload()
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func delete(_ row: PendingDelete) {
        guard let url = row.fileURL else { return }
        do {
            try FileManager.default.removeItem(at: url)
            statusIsError = false
            statusMessage = "Deleted \(row.name)."
            reload()
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}

// MARK: - Models

private struct PendingDelete: Identifiable {
    var id: String { name }
    let name: String
    let fileURL: URL?
}

struct SubagentEditorItem: Identifiable {
    let id = UUID()
    var isNew: Bool
    var scope: SubagentsSettingsViewScope
    var originalURL: URL?
    var draft: SubagentProfileDraft
}

/// Scope tag used by the editor sheet (mirrors the view's private Scope).
enum SubagentsSettingsViewScope: String, CaseIterable, Identifiable {
    case project
    case user
    var id: String { rawValue }
    var label: String {
        switch self {
        case .project: return "Workspace"
        case .user: return "User"
        }
    }
}

// MARK: - Row

private struct SubagentSettingsRow: View {
    let name: String
    let description: String
    let detail: String
    let readOnly: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Palette.primary)
                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.Palette.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if !readOnly {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Edit")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Delete")
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
        .opacity(readOnly ? 0.92 : 1)
    }
}

// MARK: - Editor

private struct SubagentEditorSheet: View {
    let item: SubagentEditorItem
    let projectAvailable: Bool
    let onSave: (SubagentEditorItem) -> Void
    let onCancel: () -> Void

    @State private var draft: SubagentProfileDraft
    @State private var scope: SubagentsSettingsViewScope
    @State private var maxTurnsText: String
    @State private var toolsText: String
    @State private var errorMessage: String?

    init(
        item: SubagentEditorItem,
        projectAvailable: Bool,
        onSave: @escaping (SubagentEditorItem) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.projectAvailable = projectAvailable
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: item.draft)
        _scope = State(initialValue: item.scope)
        _maxTurnsText = State(initialValue: item.draft.maxTurns.map(String.init) ?? "")
        _toolsText = State(initialValue: item.draft.tools.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text(item.isNew ? "New Subagent" : "Edit Subagent")
                .font(.system(size: 14, weight: .semibold))

            if item.isNew {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scope")
                        .font(.system(size: 11, weight: .medium))
                    Picker("Scope", selection: $scope) {
                        Text(SubagentsSettingsViewScope.user.label).tag(SubagentsSettingsViewScope.user)
                        Text(SubagentsSettingsViewScope.project.label)
                            .tag(SubagentsSettingsViewScope.project)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!projectAvailable)
                    if !projectAvailable {
                        Text("No project open — new profiles go to the user folder.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.Palette.tertiary)
                    }
                }
            }

            labeledField("Name", text: $draft.name, placeholder: "code-reviewer")
            labeledField("Description", text: $draft.description, placeholder: "Reviews diffs carefully")

            VStack(alignment: .leading, spacing: 4) {
                Text("System prompt")
                    .font(.system(size: 11, weight: .medium))
                TextEditor(text: $draft.systemPrompt)
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

            labeledField("Model", text: $draft.model, placeholder: "inherit if empty")

            HStack(alignment: .bottom, spacing: Theme.Spacing.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max turns")
                        .font(.system(size: 11, weight: .medium))
                    TextField("optional", text: $maxTurnsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 88)
                }
                Toggle("Background", isOn: $draft.background)
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }

            Toggle("Inherit all tools", isOn: $draft.inheritAllTools)
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Omits the tools: key. An empty tools list is fail-closed.")

            if !draft.inheritAllTools {
                labeledField("Tools", text: $toolsText, placeholder: "read_file, grep_code, write_file")
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
                Button("Save") { validateAndSave() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(width: 500)
        .onAppear {
            if item.isNew, !projectAvailable {
                scope = .user
            }
        }
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
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SettingsManagersNaming.isValidName(name) else {
            errorMessage = SettingsManagersError.invalidName.localizedDescription
            return
        }
        let turnsTrimmed = maxTurnsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxTurns: Int?
        if turnsTrimmed.isEmpty {
            maxTurns = nil
        } else if let value = Int(turnsTrimmed), value > 0 {
            maxTurns = value
        } else {
            errorMessage = "Max turns must be a positive whole number"
            return
        }
        let tools = toolsText
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var next = item
        next.scope = (!projectAvailable && item.isNew) ? .user : scope
        next.draft = SubagentProfileDraft(
            name: name,
            description: draft.description,
            systemPrompt: draft.systemPrompt,
            model: draft.model,
            maxTurns: maxTurns,
            background: draft.background,
            inheritAllTools: draft.inheritAllTools,
            tools: tools
        )
        do {
            _ = try SubagentProfileCodec.encode(next.draft)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        errorMessage = nil
        onSave(next)
    }
}

#if DEBUG
struct SubagentsSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SubagentsSettingsView()
            .environmentObject(AppViewModel())
            .padding()
            .frame(width: 560, height: 640)
    }
}
#endif
