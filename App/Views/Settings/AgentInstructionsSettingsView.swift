//
//  AgentInstructionsSettingsView.swift
//
//  Settings → Agent: global system prompt so the user can pre-inform
//  the agent. Wired via AppSettings.systemPrompt → AgentRunBootstrap
//  hostSystemPrompt → AgentSystemPromptComposer.
//

import SwiftUI
import AgentCore

struct AgentInstructionsSettingsView: View {
    @Binding var settings: AppSettings

    @State private var draft: String = ""
    @State private var didLoad = false
    @FocusState private var editorFocused: Bool

    private var estimatedTokens: Int {
        TokenEstimator.estimate(draft)
    }

    private var isDefault: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            == AppSettings.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDirty: Bool {
        draft != settings.systemPrompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System instructions")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Palette.primary)
                        Text("Prepended to every agent turn (before project AGENTS.md and built-in editing rules). Use this to set tone, stack preferences, or standing constraints.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 200, maxHeight: 320)
                        .focused($editorFocused)
                        .onChange(of: draft) { _, newValue in
                            // Live-bind so Close persists without a Save button dance.
                            settings.systemPrompt = newValue
                        }

                    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("e.g. Prefer SwiftUI over AppKit. Never invent APIs. Reply in Danish.")
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

                HStack(spacing: 12) {
                    Label("~\(estimatedTokens) tokens", systemImage: "number")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Palette.tertiary)
                    if isDirty {
                        Text("Saved with settings")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.tertiary)
                    }
                    Spacer(minLength: 0)
                    Button("Reset to default") {
                        draft = AppSettings.defaultSystemPrompt
                        settings.systemPrompt = draft
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDefault)
                    .help("Restore the built-in default system prompt")
                }
            }

            settingsCard {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.Palette.accent)
                    Text("How this is applied")
                        .font(.system(size: 13, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 6) {
                    bullet("Injected as the host system prompt on every interactive and headless run.")
                    bullet("Does not replace project AGENTS.md / CLAUDE.md — those still load when present.")
                    bullet("Per-conversation overrides (if any) still apply on top of this text.")
                    bullet("Leave blank only if you want no host instructions (harness rules still apply in Agent mode). Chat mode ignores this entirely.")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            guard !didLoad else { return }
            draft = settings.systemPrompt
            didLoad = true
        }
        .onChange(of: settings.systemPrompt) { _, newValue in
            // External replace (import / reset elsewhere) — keep editor in sync
            // when not focused to avoid fighting the user mid-edit.
            if !editorFocused, draft != newValue {
                draft = newValue
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(Theme.Palette.tertiary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if DEBUG
struct AgentInstructionsSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AgentInstructionsSettingsView(settings: .constant(.default))
            .padding()
            .frame(width: 640, height: 520)
    }
}
#endif
