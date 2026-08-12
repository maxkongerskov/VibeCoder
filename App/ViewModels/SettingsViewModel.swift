//
//  SettingsViewModel.swift
//  AgentOS — Claude Edition
//
//  Thin facade over the AgentCore `SettingsStore` actor. The DEV PLAN
//  version called `AppSettings.load()` / `AppSettings.save()` synchronously
//  via a UserDefaults-backed extension and used a `didSet` to auto-persist
//  on every keystroke. AgentCore moved persistence into an `actor`, so:
//
//    • `loadAll()` is async and runs at view-appear / on-boot.
//    • `save()` snapshots the current value and writes it through the
//      store actor.
//    • A debounce Task replaces the DEV PLAN's `didSet { settings.save() }`
//      so we don't spam the actor with every text-field keystroke.
//
//  `testConnection` and `testSearch` reach into services that the
//  Claude Edition backend batch hasn't ported yet (`LMStudioService`,
//  `WebSearchTool`). They take their service as an injected closure so
//  Settings views can render now and the App can wire a real probe
//  later without touching this file again.
//

import Foundation
import Combine
import SwiftUI
import AgentCore

// MARK: - Injection points

/// Result of a backend reachability probe surfaced to the Settings UI.
public struct SettingsConnectionResult: Sendable, Equatable {
    public let connected: Bool
    public let modelCount: Int
    public let message: String

    public init(connected: Bool, modelCount: Int, message: String) {
        self.connected = connected
        self.modelCount = modelCount
        self.message = message
    }
}

/// Closure-shaped probes. The App injects a real implementation; tests
/// inject a stub. Both are async + Sendable so we can call them from a
/// detached Task.
public typealias SettingsConnectionProbe = @Sendable (AppSettings) async -> SettingsConnectionResult
public typealias SettingsSearchProbe = @Sendable (AppSettings) async -> String

// MARK: - View model

@MainActor
final class SettingsViewModel: ObservableObject {

    // MARK: Published state

    /// The live settings struct. Mutations route through `apply(_:)` so
    /// we can debounce persistence to the SettingsStore actor.
    @Published var settings: AppSettings = AppSettings()

    /// Result of the latest "Test connection" button press.
    @Published var connectionStatusText: String = ""
    @Published var connectionStatusIsGood: Bool = false

    /// Result of the latest "Test web search" button press.
    @Published var searchTestResult: String = ""

    // MARK: Dependencies

    private let store: SettingsStore
    private let connectionProbe: SettingsConnectionProbe?
    private let searchProbe: SettingsSearchProbe?

    /// Debounce handle for persistence. Cancelled on every change so
    /// only the trailing write hits the actor (UX-wise the user sees
    /// "saved as you typed", but the disk only takes one write per
    /// lull).
    private var persistTask: Task<Void, Never>?

    // MARK: - Init

    init(store: SettingsStore = .shared,
         connectionProbe: SettingsConnectionProbe? = nil,
         searchProbe: SettingsSearchProbe? = nil) {
        self.store = store
        self.connectionProbe = connectionProbe
        self.searchProbe = searchProbe
        Task { [weak self] in
            await self?.loadAll()
        }
    }

    // MARK: - Load / save

    /// Pull the latest cached snapshot from the store actor. Used at
    /// view-appear and after settings are mutated by other actors
    /// (e.g. a server-side import).
    func loadAll() async {
        let current = await store.current()
        self.settings = current
    }

    /// Persist immediately, bypassing the debounce. Used by the "Save"
    /// button on Settings sheets where the user expects a synchronous
    /// commit.
    func save() async {
        persistTask?.cancel()
        persistTask = nil
        let snapshot = settings
        await store.replace(snapshot)
    }

    /// Mutate-in-place + persist with a short debounce. Pass a closure
    /// that takes an `inout AppSettings` so callers can do batched
    /// edits in one frame:
    ///
    ///   vm.apply { $0.lmStudioPort = 1234; $0.lmStudioHost = "127.0.0.1" }
    func apply(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        schedulePersist()
    }

    private func schedulePersist() {
        persistTask?.cancel()
        let snapshot = settings
        persistTask = Task { [store] in
            try? await Task.sleep(nanoseconds: 250_000_000)   // 250 ms debounce
            if Task.isCancelled { return }
            await store.replace(snapshot)
        }
    }

    // MARK: - Convenience setters
    //
    // The DEV PLAN had `setTheme` / `setLLMURL` / similar methods. The
    // Claude-Edition `AppSettings` struct doesn't carry a theme, but it
    // does carry per-backend host/port pairs. These wrappers exist so
    // the Settings view can stay dumb (`Button("Reset") { vm.reset() }`).

    /// Switch the active backend.
    func setBackend(_ backend: BackendIdentifier) {
        apply { $0.backend = backend }
    }

    /// Update the LM Studio host/port pair atomically.
    func setLMStudioEndpoint(host: String, port: Int) {
        apply {
            $0.lmStudioHost = host
            $0.lmStudioPort = port
        }
    }

    /// Update the EXO host/port pair atomically.
    func setEXOEndpoint(host: String, port: Int) {
        apply {
            $0.exoHost = host
            $0.exoPort = port
        }
    }

    /// Update the oMLX host/port pair atomically.
    func setOMLXEndpoint(host: String, port: Int) {
        apply {
            $0.omlxHost = host
            $0.omlxPort = port
        }
    }

    /// Replace the global system prompt.
    func setSystemPrompt(_ prompt: String) {
        apply { $0.systemPrompt = prompt }
    }

    /// Update the default sampling block.
    func setDefaultSampling(_ params: SamplingParams) {
        apply { $0.defaultSampling = params }
    }

    /// Toggle the LocalAPIServer on/off. The App watches this flag and
    /// starts/stops the server in `AppViewModel.updateSettings`.
    func setLocalAPI(enabled: Bool, port: Int? = nil) {
        apply {
            $0.localAPIEnabled = enabled
            if let p = port { $0.localAPIPort = p }
        }
    }

    /// Restore defaults. Persists immediately rather than debouncing.
    func reset() {
        settings = AppSettings()
        Task { await save() }
    }

    // MARK: - Probes (injected)

    /// "Test connection" button in Settings → Backend. Surfaces the
    /// result into `connectionStatusText` / `connectionStatusIsGood`.
    func testConnection() {
        connectionStatusText = "Testing…"
        connectionStatusIsGood = false
        guard let probe = connectionProbe else {
            connectionStatusText = "(connection probe not wired)"
            return
        }
        let snapshot = settings
        Task { [weak self] in
            let result = await probe(snapshot)
            await MainActor.run {
                self?.connectionStatusText = result.message
                self?.connectionStatusIsGood = result.connected
            }
        }
    }

    /// "Test search" button in Settings → Web search. Truncates the
    /// returned snippet so a flood of results doesn't blow up the UI.
    func testSearch() {
        searchTestResult = "Searching…"
        guard let probe = searchProbe else {
            searchTestResult = "(search probe not wired)"
            return
        }
        let snapshot = settings
        Task { [weak self] in
            let result = await probe(snapshot)
            await MainActor.run {
                self?.searchTestResult = String(result.prefix(120))
            }
        }
    }
}
