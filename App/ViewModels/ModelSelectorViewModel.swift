//
//  ModelSelectorViewModel.swift
//  AgentOS — Claude Edition
//
//  Drives the model picker in the chat header. Probes every connected
//  backend (LM Studio / EXO / llama.cpp), merges the results, dedupes
//  by `(backend, id)`, and exposes a `selectedModelID` plus a load-
//  progress snapshot for MLX bring-up.
//
//  Ported from DEV PLAN's ViewModels/ModelSelectorViewModel.swift.
//
//  Differences vs DEV PLAN:
//    • Probing is delegated to AgentCore's `InferenceBackend` protocol
//      via `backendsProvider` instead of a hard-wired `LMStudioService`.
//      The host injects backends (real or mock), which lets us defer
//      the actual `LlamaCppService` / `OpenAICompatibleClient` wiring
//      to a later backend batch.
//    • `LMModel` keeps its slim id+backend shape from AgentCore. The
//      capability inference reuses `LMModel.capabilities` /
//      `LMModel.probablySupportsTools`.
//    • Catalog-flag-wins-over-heuristic uses `CuratedMLXCatalog` and
//      `CuratedMLXCatalog` (the AgentCore-renamed types) instead of
//      the original `MLXModelCatalog` enum.
//    • MLX load progress comes from an injected `mlxLoadStateProvider`
//      closure rather than a singleton — the actual MLX backend may
//      not be wired yet, and a closure lets the App swap in a real
//      `AsyncStream<MLXModelLoadState>` once it is.
//

import Foundation
import Combine
import SwiftUI
import AgentCore

// MARK: - Injected provider protocols

/// Snapshot of the set of backends we should probe. Each call must
/// return a fresh list — the picker re-resolves whenever the user
/// changes ports / hosts in Settings. Kept Sendable so probing can
/// happen off the main actor.
public protocol ModelSelectorBackendsProviding: Sendable {
    func backends(for settings: AppSettings) -> [any InferenceBackend]
}

/// Optional handle on the MLX bring-up state stream. The DEV PLAN VM
/// owned an `MLXProgressService` singleton; we abstract over it so the
/// App can plug in a real or stub source without dragging MLXBackend
/// into this file.
public protocol MLXLoadStateProviding: Sendable {
    /// Latest snapshot. UI polls or observes this on activation.
    func current() async -> MLXModelLoadState
    /// Optional continuous stream of snapshots; `nil` if the provider
    /// has no live source yet (stub case).
    func updates() -> AsyncStream<MLXModelLoadState>?
}

// MARK: - View model

@MainActor
final class ModelSelectorViewModel: ObservableObject {

    // MARK: Published surface

    /// Flat list of every model discovered across all backends, post-
    /// dedupe. The picker groups by `backendSource` in the UI layer.
    @Published var models: [LMModel] = []
    /// Currently selected model id. Empty string = "no selection yet".
    @Published var selectedModelID: String = ""
    /// True while a `fetchModels` is in flight.
    @Published var isLoading: Bool = false
    /// Surface-level error string for the picker.
    @Published var errorMessage: String?
    /// MLX load state snapshot. Defaults to `.idle` so the UI can render
    /// before the first stream tick lands.
    @Published var mlxLoadState: MLXModelLoadState = .idle

    // MARK: Tools-unsupported cache

    /// UserDefaults-backed override: when a real run with a model
    /// produces malformed tool calls, the agent loop calls
    /// `markToolsUnsupported(modelID:)` to remember that for future
    /// launches. The cache wins over heuristic capability inference.
    private let cacheKey = "agentos.newday.toolsUnsupported"
    private var toolsUnsupportedCache: [String: Bool] = [:]

    // MARK: Dependencies

    private let backendsProvider: ModelSelectorBackendsProviding
    private let mlxLoadStateProvider: MLXLoadStateProviding?

    private var mlxStreamTask: Task<Void, Never>?

    // MARK: - Init

    init(backendsProvider: ModelSelectorBackendsProviding,
         mlxLoadStateProvider: MLXLoadStateProviding? = nil) {
        self.backendsProvider = backendsProvider
        self.mlxLoadStateProvider = mlxLoadStateProvider

        // Restore the tools-unsupported cache. Filter out empty keys
        // (same crash-class the DEV PLAN's comment called out: an empty
        // key would pin selectedModelID="" to "no tools" on next launch).
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            self.toolsUnsupportedCache = decoded.filter { !$0.key.isEmpty }
        }

        // Subscribe to the MLX load stream if the provider has one.
        if let provider = mlxLoadStateProvider, let stream = provider.updates() {
            mlxStreamTask = Task { [weak self] in
                for await snapshot in stream {
                    await MainActor.run { self?.mlxLoadState = snapshot }
                }
            }
        }
    }

    deinit {
        mlxStreamTask?.cancel()
    }

    // MARK: - Derived

    var selectedModel: LMModel? {
        models.first { $0.id == selectedModelID }
    }

    /// "Does the selected model support tool calling?" with three input
    /// signals, in priority order:
    ///   1. Per-model cache override (the agent loop has seen malformed
    ///      output from this model — never offer tools again).
    ///   2. Curated catalog flag (MLX entry's `toolCapable` or GGUF
    ///      entry's `toolCapable` — author-verified).
    ///   3. Keyword heuristic on the model id.
    /// Defaults to `true` when no signal applies (the agent loop will
    /// downgrade on first failure).
    var selectedModelSupportsTools: Bool {
        if toolsUnsupportedCache[selectedModelID] == true { return false }
        if let mlx = CuratedMLXCatalog.model(forRepoId: selectedModelID) {
            return mlx.toolCapable
        }
        return selectedModel?.probablySupportsTools ?? true
    }

    var selectedModelCapabilities: [ModelCapability] {
        selectedModel?.capabilities ?? []
    }

    // MARK: - Fetch

    /// Probe every backend the provider hands us, merge, and dedupe by
    /// `(backend, id)`. Errors are surfaced per-backend in `errorMessage`
    /// only when ALL backends fail — one downed server doesn't poison
    /// the picker.
    func fetchModels(settings: AppSettings) {
        isLoading = true
        errorMessage = nil

        let backends = backendsProvider.backends(for: settings)

        Task { [weak self] in
            await self?.runProbe(backends: backends)
        }
    }

    private func runProbe(backends: [any InferenceBackend]) async {
        var merged: [LMModel] = []
        var allFailed = !backends.isEmpty
        var lastError: String?

        for backend in backends {
            do {
                let descriptors = try await backend.listModels()
                allFailed = false
                merged.append(contentsOf: descriptors.map { LMModel(id: $0.id, backendSource: $0.backend) })
            } catch {
                lastError = error.localizedDescription
            }
        }

        // Dedupe by (backend, id).
        var seen = Set<String>()
        let unique = merged.filter { m in
            let key = "\(m.backendSource?.rawValue ?? "?")::\(m.id)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        await MainActor.run {
            self.models = unique
            // Keep a still-valid selection; never auto-pick the first catalog
            // entry (that became an implicit default load of GLM on oMLX).
            if !self.selectedModelID.isEmpty,
               !unique.contains(where: { $0.id == self.selectedModelID }) {
                self.selectedModelID = ""
            }
            self.errorMessage = (allFailed && lastError != nil) ? lastError : nil
            self.isLoading = false
        }
    }

    // MARK: - Selection

    /// Pick a specific model. Caller is responsible for persisting the
    /// choice into `AppSettings` / the active conversation.
    func select(_ modelID: String) {
        guard models.contains(where: { $0.id == modelID }) else { return }
        selectedModelID = modelID
    }

    // MARK: - Catalog-driven recommendation

    /// Best curated MLX entry for the host's RAM size.
    func recommendedMLXEntry(forSystemRAMGB ram: Int) -> CuratedMLXEntry {
        CuratedMLXCatalog.recommended(forSystemRAMGB: ram)
    }

    // MARK: - Tools-unsupported persistence

    /// The agent loop calls this after a model emits a malformed tool
    /// call. Persists across launches.
    func markToolsUnsupported(modelID: String) {
        // Guard against empty modelID — same crash-class as the DEV
        // PLAN's note: an empty key would match `selectedModelID == ""`
        // on next launch and wedge "no tools" until the user manually
        // picked a real model.
        guard !modelID.isEmpty else { return }
        toolsUnsupportedCache[modelID] = true
        if let data = try? JSONEncoder().encode(toolsUnsupportedCache) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    /// Clear the per-model "no tools" pin (used by Settings → Reset).
    func clearToolsUnsupported(modelID: String) {
        guard toolsUnsupportedCache.removeValue(forKey: modelID) != nil else { return }
        if let data = try? JSONEncoder().encode(toolsUnsupportedCache) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    // MARK: - MLX load progress (manual refresh)

    /// One-shot pull from the load-state provider — handy when the
    /// provider has no live stream and the UI just wants to re-poll on
    /// view appearance.
    func refreshMLXLoadState() async {
        guard let provider = mlxLoadStateProvider else { return }
        let snap = await provider.current()
        self.mlxLoadState = snap
    }
}
