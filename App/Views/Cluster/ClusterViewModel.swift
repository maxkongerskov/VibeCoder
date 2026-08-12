//
//  ClusterViewModel.swift
//  AgentOS — Claude Edition
//
//  Polls the active EXO cluster's /state (node graph) and lazily fetches
//  its /models catalog for the Cluster pane. Constructs its own EXOBackend
//  from the saved EXO host/port — same pattern as the Connection panel's
//  Test button — so it's decoupled from whichever backend drives chat.
//

import Foundation
import Combine
import AgentCore

@MainActor
final class ClusterViewModel: ObservableObject {

    enum State: Equatable {
        case loading
        case connected(EXOBackend.ClusterTopology)
        case unavailable(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading): return true
            case let (.unavailable(a), .unavailable(b)): return a == b
            case let (.connected(a), .connected(b)):
                return a.nodes.map(\.id) == b.nodes.map(\.id) && a.primary == b.primary
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .loading

    /// Catalog of models EXO can serve, badged by fit against pooled memory.
    /// Loaded lazily the first time the Models section is shown.
    enum CatalogState: Equatable {
        case idle
        case loading
        case loaded([EXOCatalogModel])
        case failed(String)
    }
    @Published private(set) var catalog: CatalogState = .idle

    private let host: String
    private let port: Int
    private var backend: EXOBackend?
    private var pollTask: Task<Void, Never>?

    /// Refresh cadence while the pane is visible. EXO topology changes
    /// rarely (nodes join/leave), so a slow poll is plenty.
    private let pollInterval: UInt64 = 12_000_000_000   // 12 s

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Begin polling. Called when the pane appears.
    func start() {
        backend = EXOBackend(host: host, port: port)
        Task { await refresh() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let interval = self?.pollInterval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    /// Stop polling. Called when the pane disappears.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One topology fetch. Failure → `.unavailable` with a readable reason
    /// (cluster unreachable, or EXO not serving /state). Never throws to the UI.
    func refresh() async {
        guard let backend else { return }
        do {
            let topo = try await backend.fetchTopology()
            state = .connected(topo)
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    /// Fetch the EXO model catalog once. No-op if already loading or loaded.
    func loadCatalogIfNeeded() {
        if case .idle = catalog {} else { return }
        Task { await reloadCatalog() }
    }

    /// Force a catalog refetch. Never throws to the UI.
    func reloadCatalog() async {
        if backend == nil { backend = EXOBackend(host: host, port: port) }
        guard let backend else { return }
        catalog = .loading
        do {
            let models = try await backend.fetchCatalog()
            catalog = .loaded(models)
        } catch {
            catalog = .failed(error.localizedDescription)
        }
    }
}
