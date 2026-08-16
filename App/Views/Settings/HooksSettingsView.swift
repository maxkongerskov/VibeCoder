//
//  HooksSettingsView.swift
//  Settings → Hooks: edit project `.vibecoder/hooks/hooks.json`.
//  User scope (`~/.vibecoder/hooks.json`) is display-only — the agent
//  reads project hooks only.
//

import SwiftUI
import AppKit
import AgentCore

struct HooksSettingsView: View {
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

    @State private var scope: Scope = .project
    @State private var projectRoot: URL?
    @State private var entries: [HookEntry] = []
    @State private var editing: HookEntry?
    @State private var isAdding = false
    @State private var pendingDelete: HookEntry?
    @State private var statusMessage: String?

    private var isUserScope: Bool { scope == .user }
    private var canEdit: Bool { !isUserScope && projectRoot != nil }

    private var activePath: URL? {
        switch scope {
        case .project:
            guard let projectRoot else { return nil }
            return HookConfigStore.configURL(projectRoot: projectRoot)
        case .user:
            return HookConfigStore.userConfigURL
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hooks")
                    .font(.system(size: 16, weight: .semibold))
                Text("Manage task lifecycle hooks to automatically execute commands on specific events.")
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

            if isUserScope {
                Text("Agent reads project hooks only. This path is shown for reference.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if projectRoot == nil {
                Text("No project open. Open a project from the sidebar or bind the current chat to a folder to edit hooks.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if entries.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ForEach(groupedEntries, id: \.event) { group in
                        eventSection(group.event, rows: group.rows)
                    }
                }
                .disabled(!canEdit)
                .opacity(canEdit ? 1 : 0.65)
            }

            Button {
                startAdd()
            } label: {
                Label("Add hook", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canEdit)

            Text("Changes apply to new sessions.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)

            if let statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.error)
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
        .onChange(of: scope) { _, _ in reload() }
        .sheet(item: $editing) { item in
            HookEditorSheet(
                entry: item,
                isNew: isAdding,
                onSave: { saved in commitEdit(saved) },
                onCancel: {
                    editing = nil
                    isAdding = false
                }
            )
        }
        .alert(
            "Delete hook?",
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
            Text("This removes the hook from hooks.json. Existing sessions are not affected.")
        }
    }

    // MARK: - Path

    private var pathRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.tertiary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(activePath?.path ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            Button("Reveal in Finder") { revealActivePath() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(activePath == nil)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: Theme.Spacing.s) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 32))
                .foregroundColor(Theme.Palette.tertiary.opacity(0.5))
            Text(isUserScope ? "No user hooks file" : "No hooks configured")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Palette.tertiary)
            Text(
                isUserScope
                    ? "The agent does not load ~/.vibecoder/hooks.json."
                    : "Add a hook to run a command on SessionStart, PreToolUse, Stop, and other lifecycle events."
            )
            .font(.system(size: 11))
            .foregroundColor(Theme.Palette.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
    }

    // MARK: - Groups

    private var groupedEntries: [(event: String, rows: [HookEntry])] {
        var map: [String: [HookEntry]] = [:]
        var extras: [String] = []
        for entry in entries {
            let event = HookConfigStore.canonicalEventName(entry.event)
            if map[event] == nil,
               !HookConfigStore.editorEvents.contains(event),
               event != HookDispatcher.eventNotification {
                extras.append(event)
            }
            map[event, default: []].append(entry)
        }
        let order = HookConfigStore.editorEvents
            + [HookDispatcher.eventNotification]
            + extras.sorted()
        return order.compactMap { event in
            guard let rows = map[event], !rows.isEmpty else { return nil }
            return (event, rows)
        }
    }

    private func eventSection(_ event: String, rows: [HookEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Palette.tertiary)
            ForEach(rows) { row in
                HookRow(
                    entry: row,
                    onToggle: { enabled in toggle(row, enabled: enabled) },
                    onEdit: { startEdit(row) },
                    onDelete: { pendingDelete = row }
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
        switch scope {
        case .project:
            entries = HookConfigStore.loadEntries(projectRoot: projectRoot)
        case .user:
            entries = HookConfigStore.loadUserEntries()
        }
        statusMessage = nil
    }

    private func persist() {
        guard canEdit else { return }
        do {
            try HookConfigStore.saveEntries(entries, projectRoot: projectRoot)
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func startAdd() {
        guard canEdit else { return }
        isAdding = true
        editing = HookEntry(
            event: HookDispatcher.eventSessionStart,
            command: "",
            args: [],
            timeoutSeconds: nil,
            background: false,
            enabled: true
        )
    }

    private func startEdit(_ row: HookEntry) {
        guard canEdit else { return }
        isAdding = false
        editing = row
    }

    private func commitEdit(_ saved: HookEntry) {
        if isAdding {
            entries.append(saved)
        } else if let idx = entries.firstIndex(where: { $0.id == saved.id }) {
            entries[idx] = saved
        } else {
            entries.append(saved)
        }
        editing = nil
        isAdding = false
        persist()
    }

    private func toggle(_ row: HookEntry, enabled: Bool) {
        guard let idx = entries.firstIndex(where: { $0.id == row.id }) else { return }
        entries[idx].enabled = enabled
        persist()
    }

    private func delete(_ row: HookEntry) {
        entries.removeAll { $0.id == row.id }
        persist()
    }

    private func revealActivePath() {
        guard let url = activePath else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let parent = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) {
            NSWorkspace.shared.activateFileViewerSelecting([parent])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(
            [FileManager.default.homeDirectoryForCurrentUser]
        )
    }
}

// MARK: - Row

private struct HookRow: View {
    let entry: HookEntry
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(matcherLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Palette.primary)
                Text(entry.command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.Palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .controlSize(.small)
            .help("Enabled")
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
    }

    private var matcherLabel: String {
        let trimmed = entry.matcher?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "All tools" : trimmed
    }
}

// MARK: - Editor sheet

private struct HookEditorSheet: View {
    @State var entry: HookEntry
    let isNew: Bool
    let onSave: (HookEntry) -> Void
    let onCancel: () -> Void

    @State private var argsText: String = ""
    @State private var timeoutText: String = ""
    @State private var errorMessage: String?

    private let events = HookConfigStore.editorEvents

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text(isNew ? "Add Hook" : "Edit Hook")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Event")
                    .font(.system(size: 11, weight: .medium))
                Picker("Event", selection: $entry.event) {
                    ForEach(pickerEvents, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
            }

            labeledField(
                "Matcher",
                text: Binding(
                    get: { entry.matcher ?? "" },
                    set: { entry.matcher = $0 }
                ),
                placeholder: "e.g. Write, Edit, Bash — blank = all"
            )

            labeledField(
                "Command",
                text: $entry.command,
                placeholder: "echo 'Hello from hook'"
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Arguments (one per line)")
                    .font(.system(size: 11, weight: .medium))
                TextEditor(text: $argsText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 56, maxHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.Palette.canvas)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Theme.Palette.divider, lineWidth: 0.5)
                    )
            }

            HStack(alignment: .bottom, spacing: Theme.Spacing.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Timeout (seconds)")
                        .font(.system(size: 11, weight: .medium))
                    TextField("optional", text: $timeoutText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 88)
                }
                Toggle("Run in background", isOn: $entry.background)
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer(minLength: 0)
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
            }
        }
        .padding(Theme.Spacing.l)
        .frame(width: 460)
        .onAppear {
            argsText = entry.args.joined(separator: "\n")
            if let timeout = entry.timeoutSeconds {
                timeoutText = String(timeout)
            }
            let event = HookConfigStore.canonicalEventName(entry.event)
            if !pickerEvents.contains(event) {
                entry.event = events.first ?? HookDispatcher.eventSessionStart
            } else {
                entry.event = event
            }
        }
    }

    private var pickerEvents: [String] {
        var list = events
        let current = HookConfigStore.canonicalEventName(entry.event)
        if !list.contains(current) {
            list.append(current)
        }
        return list
    }

    private func validateAndSave() {
        let command = entry.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            errorMessage = "Command cannot be empty"
            return
        }
        let timeoutTrimmed = timeoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeout: Int?
        if timeoutTrimmed.isEmpty {
            timeout = nil
        } else if let value = Int(timeoutTrimmed), value >= 0 {
            timeout = value
        } else {
            errorMessage = "Timeout must be a whole number of seconds"
            return
        }
        let matcher = entry.matcher?.trimmingCharacters(in: .whitespacesAndNewlines)
        let args = argsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        errorMessage = nil
        onSave(
            HookEntry(
                id: entry.id,
                event: HookConfigStore.canonicalEventName(entry.event),
                matcher: (matcher?.isEmpty == false) ? matcher : nil,
                command: command,
                args: args,
                timeoutSeconds: timeout,
                background: entry.background,
                enabled: entry.enabled
            )
        )
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
}

#if DEBUG
struct HooksSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        HooksSettingsView()
            .environmentObject(AppViewModel())
            .padding()
            .frame(width: 560, height: 640)
    }
}
#endif
