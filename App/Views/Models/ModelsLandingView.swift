//
//  ModelsLandingView.swift
//
//  Connected-models pane. Bundled llama.cpp / GGUF library product removed —
//  models come from the active HTTP backend (Ollama, oMLX, LM Studio, etc.).
//

import SwiftUI
import AgentCore

@MainActor
struct ModelsLandingView: View {
    @EnvironmentObject private var app: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header
                backendCard
                modelsList
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.l)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.Palette.canvas)
        .task { await app.refreshModels() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Image(systemName: "cpu")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text("Models")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primary)
                Spacer()
                Button {
                    Task { await app.refreshModels() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text("Models are provided by your active backend (Ollama, oMLX, LM Studio, EXO, or a custom OpenAI-compatible endpoint). Configure the connection under Settings → Connection.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var backendCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Active backend")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(app.settings.backend.shortLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
            }
            if let err = app.modelListError, !err.isEmpty {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.error)
            }
            if let mid = app.selectedModelID {
                Text("Selected: \(mid)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.subtle)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var modelsList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Available from server")
                .font(.system(size: 13, weight: .semibold))
            if app.availableModels.isEmpty {
                Text("No models reported. Start Ollama or oMLX (or another backend), then Refresh.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .padding(.vertical, Theme.Spacing.m)
            } else {
                ForEach(app.availableModels, id: \.id) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.system(size: 12, weight: .medium))
                            Text(model.id)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.Palette.tertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if app.selectedModelID == model.id {
                            Text("Active")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.Palette.success)
                        }
                        Button("Use") {
                            Task { await app.activateModel(id: model.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(app.selectedModelID == model.id)
                    }
                    .padding(10)
                    .background(Theme.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
