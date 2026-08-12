//
//  ProjectMemorySettingsView.swift
//  S4 — Settings → Memory: edit project MEMORY.md / DECISIONS.md.
//

import SwiftUI
import AgentCore

struct ProjectMemorySettingsView: View {
    @EnvironmentObject private var app: AppViewModel
    @StateObject private var model = ProjectMemoryEditorViewModel()
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Project memory")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Palette.primary)
                        Text("Edit MEMORY.md and DECISIONS.md in the project folder. When inject is on, the agent loads these on each turn (tail-capped).")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let root = model.projectRoot {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.tertiary)
                        Text(root.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.Palette.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("No project open. Open a project from the sidebar or bind the current chat to a folder to edit memory files.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("File", selection: $model.kind) {
                    ForEach(ProjectMemoryFileKind.allCases) { k in
                        Text(k.displayName).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.projectRoot == nil)

                Text(model.kind.help)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.draft)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 220, maxHeight: 360)
                        .focused($editorFocused)
                        .disabled(model.projectRoot == nil)

                    if model.projectRoot != nil,
                       model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(placeholder)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.Palette.tertiary.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.Palette.canvas)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            editorFocused
                                ? Theme.Palette.accent.opacity(0.55)
                                : Theme.Palette.divider,
                            lineWidth: editorFocused ? 1.25 : 0.5
                        )
                )
                .opacity(model.projectRoot == nil ? 0.55 : 1)

                HStack(spacing: 10) {
                    if model.isDirty {
                        Text("Unsaved changes")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Palette.warning)
                    } else if model.fileExistsOnDisk {
                        Text("On disk")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.tertiary)
                    } else if model.projectRoot != nil {
                        Text("File not created yet — Save to create")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.tertiary)
                    }
                    Spacer(minLength: 0)
                    Button("Reload") { model.load() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.projectRoot == nil)
                    Button("Revert") { model.revert() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.projectRoot == nil || !model.isDirty)
                    Button("Insert template") { model.insertTemplateIfEmpty() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.projectRoot == nil)
                    Button("Save") { _ = model.save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.projectRoot == nil || !model.isDirty)
                        .keyboardShortcut("s", modifiers: .command)
                }

                if let status = model.statusMessage {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(model.statusIsError ? Theme.Palette.error : Theme.Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingsCard {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.Palette.accent)
                    Text("How this connects")
                        .font(.system(size: 13, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 6) {
                    bullet("Files live at the project root (same paths the agent injects).")
                    bullet("Settings → toggles for inject/dream remain separate; this editor only edits markdown.")
                    bullet("AppSupport workspace MEMORY (dream consolidations) is separate from these project files.")
                    bullet("No embeddings — text files only.")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.secondary)
            }

            // Memory flags (honest discoverability)
            settingsCard {
                HStack(spacing: 8) {
                    Image(systemName: "switch.2")
                        .foregroundStyle(Theme.Palette.accent)
                    Text("Agent memory flags")
                        .font(.system(size: 13, weight: .semibold))
                }
                Toggle("Enable hybrid memory tools", isOn: Binding(
                    get: { app.settings.memoryEnabled },
                    set: { app.settings.memoryEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Toggle("Inject project MEMORY / DECISIONS into prompt", isOn: Binding(
                    get: { app.settings.injectProjectMemory },
                    set: { app.settings.injectProjectMemory = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Toggle("Dream consolidation at turn end", isOn: Binding(
                    get: { app.settings.dreamEnabled },
                    set: { app.settings.dreamEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Text("Dream is extractive by default (optional LLM consolidator is a separate opt-in in AgentLoop config).")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { refreshProjectRoot() }
        .onChange(of: app.selectedConversationID) { _, _ in refreshProjectRoot() }
        .onChange(of: app.openedProject?.id) { _, _ in refreshProjectRoot() }
    }

    private var placeholder: String {
        switch model.kind {
        case .memory:
            return "# Memory\n\nNotes the agent should remember across sessions…"
        case .decisions:
            return "# Design Decisions\n\n## …\n\n**Decision:** …\n\n**Rationale:** …"
        }
    }

    private func refreshProjectRoot() {
        // Prefer conversation project, then opened project overlay.
        if let id = app.selectedConversationID,
           let conv = app.conversations.first(where: { $0.id == id }),
           let root = conv.projectRoot {
            model.projectRoot = root
            return
        }
        model.projectRoot = app.openedProject?.url
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if DEBUG
struct ProjectMemorySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ProjectMemorySettingsView()
            .environmentObject(AppViewModel())
            .padding()
            .frame(width: 560, height: 640)
    }
}
#endif
