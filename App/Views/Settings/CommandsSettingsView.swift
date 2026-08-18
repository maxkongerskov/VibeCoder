//
//  CommandsSettingsView.swift
//  Settings → Commands: user / workspace markdown slash commands.
//  Disk is the source of truth. `$ARGUMENTS` / `$1` stay literal in the file.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentCore

struct CommandsSettingsView: View {
    @EnvironmentObject private var app: AppViewModel

    @State private var projectRoot: URL?
    @State private var userCommands: [CommandProfileDraft] = []
    @State private var workspaceCommands: [CommandProfileDraft] = []
    @State private var searchText: String = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var editor: CommandEditorItem?
    @State private var pendingDelete: CommandPendingDelete?

    private var userRoot: URL { CommandProfilePaths.userRoot() }
    private var workspaceRoot: URL? {
        projectRoot.map { CommandProfilePaths.projectRoot($0) }
    }

    private var filteredUser: [CommandProfileDraft] { filter(userCommands) }
    private var filteredWorkspace: [CommandProfileDraft] { filter(workspaceCommands) }

    private var visibleCount: Int { filteredUser.count + filteredWorkspace.count }
    private var totalCount: Int { userCommands.count + workspaceCommands.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Commands")
                    .font(.system(size: 16, weight: .semibold))
                Text("Markdown `/name` files. The prompt body may include $ARGUMENTS or $1, $2… — they are stored as written and not expanded here.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.tertiary)
                TextField("Search commands", text: $searchText)
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
                    commandSection(title: "User", rows: filteredUser, scope: .user)
                }
                if !filteredWorkspace.isEmpty {
                    commandSection(title: "Workspace", rows: filteredWorkspace, scope: .workspace)
                }
            }

            Text("\(totalCount) commands")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
                .accessibilityIdentifier("settings-commands-footer")

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
            CommandEditorSheet(
                item: item,
                projectAvailable: projectRoot != nil,
                onSave: { saved in commit(saved) },
                onCancel: { editor = nil }
            )
        }
        .alert(
            "Delete command?",
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
            Text("This removes \(pendingDelete?.name ?? "the command") from disk.")
        }
    }

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
            .accessibilityIdentifier("settings-commands-new")

            Button {
                importCommand()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("settings-commands-import")

            Button {
                SettingsManagersPaths.reveal(userRoot)
            } label: {
                Label("Open user commands folder", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("settings-commands-open-folder")

            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: Theme.Spacing.s) {
            Image(systemName: "slash.circle")
                .font(.system(size: 32))
                .foregroundColor(Theme.Palette.tertiary.opacity(0.5))
            Text("No commands found")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Palette.tertiary)
            Text("Create a markdown command or import a .md file.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
        .accessibilityIdentifier("settings-commands-empty")
    }

    private func commandSection(
        title: String,
        rows: [CommandProfileDraft],
        scope: CommandsSettingsScope
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Palette.tertiary)
            ForEach(rows) { draft in
                CommandSettingsRow(
                    draft: draft,
                    onEdit: { startEdit(draft, scope: scope) },
                    onDelete: {
                        pendingDelete = CommandPendingDelete(
                            name: draft.name,
                            fileURL: draft.fileURL
                        )
                    }
                )
            }
        }
    }

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
        userCommands = CommandProfileCodec.loadDirectory(userRoot)
        if let workspaceRoot {
            workspaceCommands = CommandProfileCodec.loadDirectory(workspaceRoot)
        } else {
            workspaceCommands = []
        }
        statusMessage = nil
        statusIsError = false
    }

    private func filter(_ list: [CommandProfileDraft]) -> [CommandProfileDraft] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return list }
        return list.filter {
            $0.name.lowercased().contains(query)
                || $0.description.lowercased().contains(query)
                || $0.prompt.lowercased().contains(query)
        }
    }

    private func startAdd() {
        editor = CommandEditorItem(
            isNew: true,
            scope: .user,
            originalURL: nil,
            draft: CommandProfileDraft(
                prompt: "Run custom command. $ARGUMENTS"
            )
        )
    }

    private func startEdit(_ draft: CommandProfileDraft, scope: CommandsSettingsScope) {
        editor = CommandEditorItem(
            isNew: false,
            scope: scope,
            originalURL: draft.fileURL,
            draft: draft
        )
    }

    private func commit(_ item: CommandEditorItem) {
        do {
            let name = item.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let directory: URL
            switch item.scope {
            case .user:
                directory = userRoot
            case .workspace:
                guard let workspaceRoot else { throw CommandProfileError.noProject }
                directory = workspaceRoot
            }
            let dest = CommandProfileCodec.fileURL(name: name, directory: directory)
            try CommandProfileCodec.write(item.draft, to: dest)
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

    private func delete(_ row: CommandPendingDelete) {
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

    private func importCommand() {
        let root: URL
        if let workspaceRoot {
            root = workspaceRoot
        } else {
            root = userRoot
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a markdown command file"
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown]
        }
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        do {
            let dest = try CommandProfileCodec.importCommand(from: picked, into: root)
            statusIsError = false
            statusMessage = "Imported \(dest.deletingPathExtension().lastPathComponent)."
            reload()
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}

// MARK: - Models

struct CommandPendingDelete: Identifiable {
    var id: String { name }
    let name: String
    let fileURL: URL?
}

struct CommandEditorItem: Identifiable {
    let id = UUID()
    var isNew: Bool
    var scope: CommandsSettingsScope
    var originalURL: URL?
    var draft: CommandProfileDraft
}

enum CommandsSettingsScope: String, CaseIterable, Identifiable {
    case user
    case workspace
    var id: String { rawValue }
    var label: String {
        switch self {
        case .user: return "User"
        case .workspace: return "Workspace"
        }
    }
}

// MARK: - Row

private struct CommandSettingsRow: View {
    let draft: CommandProfileDraft
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("/\(draft.name)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.Palette.primary)
                if !draft.description.isEmpty {
                    Text(draft.description)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !draft.argumentHint.isEmpty {
                    Text(draft.argumentHint)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.Palette.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
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
        .padding(Theme.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Palette.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
        .accessibilityIdentifier("settings-command-row-\(draft.name)")
    }
}

// MARK: - Editor

private struct CommandEditorSheet: View {
    let item: CommandEditorItem
    let projectAvailable: Bool
    let onSave: (CommandEditorItem) -> Void
    let onCancel: () -> Void

    @State private var draft: CommandProfileDraft
    @State private var scope: CommandsSettingsScope
    @State private var errorMessage: String?

    init(
        item: CommandEditorItem,
        projectAvailable: Bool,
        onSave: @escaping (CommandEditorItem) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.projectAvailable = projectAvailable
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: item.draft)
        _scope = State(initialValue: item.scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text(item.isNew ? "New Command" : "Edit Command")
                .font(.system(size: 14, weight: .semibold))

            if item.isNew {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scope")
                        .font(.system(size: 11, weight: .medium))
                    Picker("Scope", selection: $scope) {
                        Text(CommandsSettingsScope.user.label)
                            .tag(CommandsSettingsScope.user)
                        Text(CommandsSettingsScope.workspace.label)
                            .tag(CommandsSettingsScope.workspace)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!projectAvailable)
                    if !projectAvailable {
                        Text("No project open — new commands go to the user folder.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.Palette.tertiary)
                    }
                }
            }

            labeledField("Name", text: $draft.name, placeholder: "review-pr")
            labeledField("Description", text: $draft.description, placeholder: "Review a pull request")
            labeledField("Argument hint", text: $draft.argumentHint, placeholder: "<file-path>")

            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt")
                    .font(.system(size: 11, weight: .medium))
                TextEditor(text: $draft.prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 140, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.Palette.canvas)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Theme.Palette.divider, lineWidth: 0.5)
                    )
                Text("Use $ARGUMENTS or $1 $2… in the body. They are saved as written.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Palette.tertiary)
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
        guard CommandProfileNaming.isValidName(name) else {
            errorMessage = CommandProfileError.invalidName.localizedDescription
            return
        }
        var next = item
        next.scope = (!projectAvailable && item.isNew) ? .user : scope
        next.draft = CommandProfileDraft(
            name: name,
            description: draft.description,
            argumentHint: draft.argumentHint,
            prompt: draft.prompt,
            fileURL: item.draft.fileURL
        )
        do {
            _ = try CommandProfileCodec.encode(next.draft)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        errorMessage = nil
        onSave(next)
    }
}

// MARK: - Disk codec (App-only; no AgentCore discovery)

enum CommandProfileError: Error, LocalizedError, Equatable {
    case invalidName
    case emptyPrompt
    case noProject
    case missingMarkdown
    case io(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Name may only contain letters, numbers, hyphens, and underscores."
        case .emptyPrompt:
            return "Prompt cannot be empty."
        case .noProject:
            return "Open a project to use workspace scope."
        case .missingMarkdown:
            return "The selection is not a markdown command file."
        case .io(let message):
            return message
        }
    }
}

enum CommandProfileNaming {
    /// ZCode command slugs: letters, numbers, hyphen, underscore.
    static func isValidName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("/") { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }
    }

    static func slugify(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { trimmed.removeFirst() }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = trimmed.unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) { return Character(scalar) }
            if CharacterSet.whitespaces.contains(scalar) || scalar == "." {
                return "-"
            }
            return "-"
        }
        var dashed = String(mapped)
        while dashed.contains("--") {
            dashed = dashed.replacingOccurrences(of: "--", with: "-")
        }
        return dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
    }
}

enum CommandProfilePaths {
    static func userRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".vibecoder/commands", isDirectory: true)
    }

    static func projectRoot(_ projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".vibecoder/commands", isDirectory: true)
    }
}

struct CommandProfileDraft: Equatable, Identifiable {
    var name: String
    var description: String
    var argumentHint: String
    var prompt: String
    var fileURL: URL?

    var id: String { fileURL?.path ?? name }

    init(
        name: String = "",
        description: String = "",
        argumentHint: String = "",
        prompt: String = "",
        fileURL: URL? = nil
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.prompt = prompt
        self.fileURL = fileURL
    }
}

enum CommandProfileCodec {
    static func encode(_ draft: CommandProfileDraft) throws -> String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CommandProfileNaming.isValidName(name) else {
            throw CommandProfileError.invalidName
        }
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw CommandProfileError.emptyPrompt }

        var lines = ["---", "name: \(yamlScalar(name))"]
        let desc = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty {
            lines.append("description: \(yamlScalar(desc))")
        }
        let hint = draft.argumentHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty {
            lines.append("argument-hint: \(yamlScalar(hint))")
        }
        lines.append("---")
        lines.append("")
        lines.append(prompt)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func write(_ draft: CommandProfileDraft, to fileURL: URL) throws {
        let markdown = try encode(draft)
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func fileURL(name: String, directory: URL) -> URL {
        directory.appendingPathComponent("\(name).md")
    }

    static func parse(markdown: String, fileURL: URL? = nil) -> CommandProfileDraft? {
        var name = fileURL?.deletingPathExtension().lastPathComponent ?? ""
        var description = ""
        var hint = ""
        var body = markdown

        if markdown.hasPrefix("---") {
            let parts = markdown.split(separator: "---", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 3 {
                let fields = parseFrontmatter(String(parts[1]))
                if let n = fields["name"], !n.isEmpty { name = n }
                if let d = fields["description"] { description = d }
                if let h = firstField(fields, keys: ["argument-hint", "argument_hint", "argumentHint"]) {
                    hint = h
                }
                body = parts.dropFirst(2).joined(separator: "---")
            }
        }

        let prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else { return nil }
        return CommandProfileDraft(
            name: name,
            description: description,
            argumentHint: hint,
            prompt: prompt,
            fileURL: fileURL
        )
    }

    static func loadDirectory(_ directory: URL) -> [CommandProfileDraft] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { file -> CommandProfileDraft? in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return parse(markdown: text, fileURL: file)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func importCommand(from picked: URL, into root: URL) throws -> URL {
        guard picked.pathExtension.lowercased() == "md" else {
            throw CommandProfileError.missingMarkdown
        }
        guard let text = try? String(contentsOf: picked, encoding: .utf8),
              let parsed = parse(markdown: text, fileURL: picked)
        else {
            throw CommandProfileError.missingMarkdown
        }
        let slug = CommandProfileNaming.isValidName(parsed.name)
            ? parsed.name
            : CommandProfileNaming.slugify(parsed.name)
        guard CommandProfileNaming.isValidName(slug) else {
            throw CommandProfileError.invalidName
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = fileURL(name: slug, directory: root)
        if dest.standardizedFileURL.path != picked.standardizedFileURL.path {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: picked, to: dest)
        }
        return dest
    }

    private static func parseFrontmatter(_ block: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in block.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { fields[key] = value }
        }
        return fields
    }

    private static func firstField(_ fields: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = fields[key], !value.isEmpty { return value }
        }
        return nil
    }
}
