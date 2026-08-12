//
//  BackendConnectionCoordinator.swift
//
//  Models list, backend selection, local API server, and EXO model pinning.
//  Bundled llama.cpp / GGUF product removed — all inference is HTTP backends.
//

import Foundation
import SwiftUI
import AppKit
import AgentCore
import MLXBackend

@MainActor
final class BackendConnectionCoordinator: ObservableObject {

    weak var host: AppViewModel?

    @Published var availableModels: [ModelDescriptor] = []
    @Published var selectedModelID: String?
    @Published var activeModelSettings: ModelSettings?
    @Published var modelListError: String?
    /// Surfaced when `activateModel` / warmUp fails (e.g. oMLX load error).
    @Published var modelLoadError: String?
    /// True while warmUp is in flight for the selected model.
    @Published var isLoadingModel: Bool = false
    @Published var localServerRunning: Bool = false

    internal var testingBackend: (any InferenceBackend)?

    init() {}

    // MARK: - Model list

    func ingestConnectionTestModels(_ models: [ModelDescriptor]) async {
        guard let host else { return }
        await ModelSettingsStore.shared.applyActivations(models: models, defaults: host.settings)
        availableModels = models
        modelListError = nil
        if let id = selectedModelID, models.contains(where: { $0.id == id }) {
            activeModelSettings = await ModelSettingsStore.shared.applyActivation(
                modelId: id,
                defaults: host.settings,
                advertised: models.first(where: { $0.id == id })?.contextLength)
        } else {
            selectedModelID = nil
            activeModelSettings = nil
        }
    }

    func activateModel(id: String) async {
        guard let host else { return }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        selectedModelID = trimmed
        modelLoadError = nil
        isLoadingModel = true
        defer { isLoadingModel = false }

        // Prefer the catalog entry; if the picker id is a fresh profile alias
        // not yet in `availableModels`, still warm the engine so oMLX loads it.
        let model = availableModels.first(where: { $0.id == trimmed })
            ?? ModelDescriptor(
                id: trimmed,
                displayName: trimmed,
                backend: host.settings.backend,
                supportsTools: true,
                contextLength: availableModels.first(where: {
                    OMLXModelManager.engineModelID($0.id) == OMLXModelManager.engineModelID(trimmed)
                })?.contextLength
            )

        activeModelSettings = await ModelSettingsStore.shared.applyActivation(
            modelId: model.id,
            defaults: host.settings,
            advertised: model.contextLength)
        do {
            // oMLX: warmUp → POST /v1/models/{engine}/load and wait until ready.
            // Other backends no-op or light-check.
            try await currentBackend().warmUp(model: model)
            modelLoadError = nil
        } catch {
            let msg = error.localizedDescription
            Diagnostics.warn("warmUp(\(model.id)) failed: \(msg)")
            modelLoadError = msg
        }
    }

    func applyPreparedModelSettings(_ settings: ModelSettings) {
        activeModelSettings = settings
    }

    private func syncActiveModelSettingsFromStore() async {
        guard let host else { return }
        guard let id = selectedModelID,
              let model = availableModels.first(where: { $0.id == id }) else {
            activeModelSettings = nil
            return
        }
        activeModelSettings = await ModelSettingsStore.shared.applyActivation(
            modelId: model.id,
            defaults: host.settings,
            advertised: model.contextLength)
    }

    func refreshModels() async {
        guard let host else { return }
        let backend = currentBackend()
        do {
            let models = try await backend.listModels()
            await ModelSettingsStore.shared.applyActivations(models: models, defaults: host.settings)
            self.availableModels = models
            self.modelListError = nil

            if let id = selectedModelID,
               models.contains(where: { $0.id == id }) {
                // Keep selection.
            } else if models.count == 1 {
                // Only auto-select when the server exposes a single model.
                selectedModelID = models[0].id
            } else {
                // Multiple models and no valid selection — force an explicit pick
                // (do not silently use models.first; that hid "no selection").
                selectedModelID = nil
            }
            await syncActiveModelSettingsFromStore()
        } catch {
            self.availableModels = []
            self.activeModelSettings = nil
            self.modelListError = error.localizedDescription
        }
    }

    // MARK: - Backend resolution

    func currentBackend() -> any InferenceBackend {
        guard let host else { return BackendFactory.make(from: AppSettings()) }
        if let testingBackend { return testingBackend }
        if host.settings.backend == .mlx { return MLXBackend() }
        return BackendFactory.make(from: host.settings)
    }

    func makeBackend(_ id: BackendIdentifier) -> any InferenceBackend {
        guard let host else { return BackendFactory.make(from: AppSettings()) }
        if id == .mlx { return MLXBackend() }
        var s = host.settings
        s.backend = id
        return BackendFactory.make(from: s)
    }

    // MARK: - EXO pinning

    func pinEXOModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        applyEXOModel(trimmed)
    }

    func activateBackend(_ id: BackendIdentifier) {
        host?.updateSettings { $0.backend = id }
        if id == .exo {
            Task { await autoPinEXOLoadedModel() }
        } else {
            Task { await refreshModels() }
        }
    }

    private func autoPinEXOLoadedModel() async {
        guard let host else { return }
        let backend = EXOBackend(host: host.settings.exoHost, port: host.settings.exoPort)
        for attempt in 0..<3 {
            if let model = (try? await backend.fetchTopology())?.activeModel,
               !model.isEmpty {
                applyEXOModel(model)
                return
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 700_000_000) }
        }
        if let downloaded = (try? await backend.fetchCatalog())?.first(where: { $0.downloaded }) {
            applyEXOModel(downloaded.id)
        }
    }

    private func applyEXOModel(_ id: String) {
        host?.updateSettings {
            $0.backend = .exo
            $0.exoModelID = id
        }
        availableModels = [ModelDescriptor(id: id, displayName: id,
                                           backend: .exo, supportsTools: true)]
        selectedModelID = id
    }

    // MARK: - Local API server

    func startLocalServer() async {
        guard let host else { return }
        let backend = currentBackend()
        await LocalAPIServer.shared.configure(
            backend: backend,
            settings: host.settings,
            agentToolsEnabled: host.settings.localAPIAgentToolsEnabled)
        do {
            if localServerRunning {
                await LocalAPIServer.shared.stopAndWait()
                localServerRunning = false
            }
            try await LocalAPIServer.shared.start(port: host.settings.localAPIPort)
            self.localServerRunning = true
        } catch {
            Diagnostics.error("LocalAPIServer start: \(error.localizedDescription)")
            self.localServerRunning = false
        }
    }

    func stopLocalServer() async {
        await LocalAPIServer.shared.stopAndWait()
        self.localServerRunning = false
    }
}
