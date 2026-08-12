//
//  ClusterView.swift
//  AgentOS — Claude Edition
//
//  The "Cluster" pane — live view of the EXO cluster, in two sections via a
//  segmented control:
//    • Nodes  — the live /state node graph (device, chip, RAM, GPU load).
//    • Models — EXO's /models catalog, each entry badged by whether it fits
//               the cluster's pooled memory, with one-click "Use on cluster".
//  Visible in the sidebar only when EXO is the active backend (RootView
//  filters the tab). All fields decode defensively and degrade gracefully.
//

import SwiftUI
import AgentCore

@MainActor
struct ClusterView: View {

    @EnvironmentObject private var app: AppViewModel
    @StateObject private var vm: ClusterViewModel

    init(host: String, port: Int) {
        _vm = StateObject(wrappedValue: ClusterViewModel(host: host, port: port))
    }

    enum ClusterSection: String, CaseIterable, Identifiable {
        case nodes = "Nodes"
        case models = "Models"
        var id: String { rawValue }
    }
    @State private var section: ClusterSection = .nodes
    @State private var search: String = ""
    @State private var fitsOnly: Bool = false
    @State private var downloadedOnly: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionContent
        }
        .background(Theme.Palette.canvas)
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "network")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.Palette.accent)
                Text("Cluster")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primary)
                if case .connected(let topo) = vm.state {
                    Text(summary(topo))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.secondary)
                        .padding(.leading, Theme.Spacing.xs)
                }
                Spacer()
                Button { refreshCurrent() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(section == .models ? "Refresh catalog" : "Refresh topology")
            }
            sectionPicker
            if section == .models {
                Text("You load models in EXO itself — Pin just copies the model's name into \(AppBranding.displayName)'s EXO backend setting so it knows which one to use.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .lineLimit(2)
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.ml + 2)
    }

    private var sectionPicker: some View {
        HStack(spacing: 2) {
            ForEach(ClusterSection.allCases) { s in
                Button {
                    section = s
                    if s == .models { vm.loadCatalogIfNeeded() }
                } label: {
                    Text(s.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(section == s ? Color.white : Theme.Palette.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(section == s ? Theme.Palette.accent : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.Palette.subtle)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Theme.Palette.divider, lineWidth: 0.5)
                )
        )
    }

    private func refreshCurrent() {
        Task {
            if section == .models { await vm.reloadCatalog() }
            else { await vm.refresh() }
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .nodes:  nodesContent
        case .models: modelsContent
        }
    }

    // MARK: Content

    @ViewBuilder
    private var nodesContent: some View {
        switch vm.state {
        case .loading:
            centered {
                ProgressView()
                Text("Reading cluster topology…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .padding(.top, Theme.Spacing.s)
            }
        case .unavailable(let reason):
            centered {
                Image(systemName: "network.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.Palette.tertiary)
                Text("Cluster topology unavailable")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primary)
                    .padding(.top, Theme.Spacing.s)
                Text("Is EXO running at \(vm_hostPort)? The Cluster view reads EXO's /state endpoint — inference still works without it, but the node graph won't show.\n\n\(reason)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .padding(.top, Theme.Spacing.xs)
            }
        case .connected(let topo):
            if topo.nodes.isEmpty {
                centered {
                    Image(systemName: "network")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.Palette.tertiary)
                    Text("Connected, but no nodes reported")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Palette.secondary)
                        .padding(.top, Theme.Spacing.s)
                }
            } else {
                nodeGrid(topo)
            }
        }
    }

    private func nodeGrid(_ topo: EXOBackend.ClusterTopology) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: Theme.Spacing.m)],
                spacing: Theme.Spacing.m
            ) {
                ForEach(topo.nodes, id: \.id) { node in
                    nodeCard(node,
                             isCoordinator: node.id == topo.primary,
                             activeModel: topo.activeModel)
                }
            }
            .padding(Theme.Spacing.l)
        }
    }

    private func nodeCard(_ node: EXOBackend.ClusterTopology.Node,
                          isCoordinator: Bool,
                          activeModel: String?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
            HStack(alignment: .top) {
                Image(systemName: nodeIcon(node, isCoordinator: isCoordinator))
                    .font(.system(size: 20))
                    .foregroundStyle(isCoordinator ? Theme.Palette.accent : Theme.Palette.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name ?? shortID(node.id))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.primary)
                        .lineLimit(1)
                    Text(isCoordinator ? "Coordinator" : "Worker")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isCoordinator ? Theme.Palette.accent : Theme.Palette.tertiary)
                }
                Spacer()
                Circle()
                    .fill(Theme.Palette.success)
                    .frame(width: 8, height: 8)
            }

            Divider().opacity(0.5)

            if let chip = node.chip, !chip.isEmpty {
                metricRow(icon: "cpu", label: chip)
            }
            if let mem = node.memoryGB {
                metricRow(icon: "memorychip", label: memoryLabel(total: mem, free: node.memoryFreeGB))
            }
            if let gpu = node.gpuUsage {
                metricRow(icon: "speedometer", label: "GPU \(Int((gpu * 100).rounded()))%")
            }
            if node.runsActiveModel, let model = activeModel {
                metricRow(icon: "shippingbox", label: shortModel(model))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m + 2)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card + 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card + 2, style: .continuous)
                .stroke(isCoordinator ? Theme.Palette.accent.opacity(0.5) : Theme.Palette.divider,
                        lineWidth: isCoordinator ? 1 : 0.5)
        )
    }

    private func metricRow(icon: String, label: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Palette.tertiary)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.Palette.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Helpers

    private var vm_hostPort: String { "\(app.settings.exoHost):\(app.settings.exoPort)" }

    private func nodeIcon(_ node: EXOBackend.ClusterTopology.Node, isCoordinator: Bool) -> String {
        if isCoordinator { return "star.circle.fill" }
        let device = (node.device ?? "").lowercased()
        if device.contains("book") { return "laptopcomputer" }
        if device.contains("mac") { return "desktopcomputer" }
        return "cpu"
    }

    /// Peer ids are long (12D3KooW…); show a readable prefix when there's
    /// no friendly name.
    private func shortID(_ id: String) -> String {
        id.count > 12 ? String(id.prefix(12)) + "…" : id
    }

    /// "mlx-community/MiniMax-M2.7-8bit" → "MiniMax-M2.7-8bit"
    private func shortModel(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    private func memoryLabel(total: Int, free: Int?) -> String {
        if let free { return "\(total) GB · \(free) free" }
        return "\(total) GB"
    }

    private func summary(_ topo: EXOBackend.ClusterTopology) -> String {
        let n = topo.nodes.count
        let totalGB = topo.nodes.compactMap(\.memoryGB).reduce(0, +)
        let macs = "\(n) Mac\(n == 1 ? "" : "s")"
        return totalGB > 0 ? "\(macs) · \(totalGB) GB pooled" : macs
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) { content() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Models browser

    /// Pooled cluster memory (GiB) from the current topology, or 0 if the
    /// node graph hasn't loaded yet (fit badges then show as neutral).
    private var pooledGB: Int {
        if case .connected(let topo) = vm.state { return topo.pooledMemoryGB }
        return 0
    }

    /// The model EXO currently has loaded (its active instance), or nil if
    /// nothing's loaded / topology not yet read. Drives the Unload button.
    private var loadedModelID: String? {
        if case .connected(let topo) = vm.state { return topo.activeModel }
        return nil
    }

    @ViewBuilder
    private var modelsContent: some View {
        switch vm.catalog {
        case .idle, .loading:
            centered {
                ProgressView()
                Text("Loading cluster catalog…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .padding(.top, Theme.Spacing.s)
            }
        case .failed(let reason):
            centered {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.Palette.tertiary)
                Text("Couldn't load EXO's catalog")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.Palette.secondary)
                    .padding(.top, Theme.Spacing.s)
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.top, Theme.Spacing.xs)
            }
        case .loaded(let models):
            modelBrowser(models)
        }
    }

    private func modelBrowser(_ models: [EXOCatalogModel]) -> some View {
        let filtered = filteredSorted(models)
        return VStack(spacing: 0) {
            browserToolbar(total: models.count, shown: filtered.count)
            if filtered.isEmpty {
                centered {
                    Text("No models match.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.s) {
                        ForEach(filtered) { model in
                            ClusterModelRow(
                                model: model,
                                fit: ClusterFit.evaluate(modelGB: model.storageGB, pooledGB: pooledGB),
                                isActive: model.id == app.settings.exoModelID,
                                isLoaded: model.id == loadedModelID,
                                onPin: { app.pinEXOModel(model.id) }
                            )
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.bottom, Theme.Spacing.l)
                }
            }
        }
    }

    private func browserToolbar(total: Int, shown: Int) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
                TextField("Search models", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 6)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Palette.divider, lineWidth: 0.5))
            .frame(maxWidth: 260)

            Toggle(isOn: $downloadedOnly) {
                Text("Downloaded")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.checkbox)
            .help("Show only models EXO already has downloaded")

            Toggle(isOn: $fitsOnly) {
                Text("Fits cluster")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.checkbox)

            Spacer()
            Text("\(shown) of \(total)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.tertiary)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    /// Filter by search + fit toggle, then sort runnable-first (fits, then
    /// tight) each by size descending — so the biggest model the cluster can
    /// actually serve sits on top — with models that exceed the pool sunk to
    /// the bottom, smallest (closest-to-fitting) first.
    private func filteredSorted(_ models: [EXOCatalogModel]) -> [EXOCatalogModel] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let pooled = pooledGB
        func fitOf(_ m: EXOCatalogModel) -> ClusterFit {
            ClusterFit.evaluate(modelGB: m.storageGB, pooledGB: pooled)
        }
        func rank(_ f: ClusterFit) -> Int {
            switch f {
            case .fits: return 0
            case .tight: return 1
            case .unknown: return 2
            case .exceeds: return 3
            }
        }
        return models.filter { m in
            let matchesSearch = needle.isEmpty
                || m.id.lowercased().contains(needle)
                || (m.baseModel ?? "").lowercased().contains(needle)
                || (m.family ?? "").lowercased().contains(needle)
            if !matchesSearch { return false }
            if downloadedOnly && !m.downloaded { return false }
            if fitsOnly {
                let f = fitOf(m)
                return f == .fits || f == .tight
            }
            return true
        }
        .sorted { a, b in
            let fa = fitOf(a), fb = fitOf(b)
            if fa != fb { return rank(fa) < rank(fb) }
            let sa = a.storageGB ?? 0, sb = b.storageGB ?? 0
            return fa == .exceeds ? (sa < sb) : (sa > sb)
        }
    }
}

// MARK: - Model row

@MainActor
private struct ClusterModelRow: View {
    let model: EXOCatalogModel
    let fit: ClusterFit
    let isActive: Bool
    let isLoaded: Bool
    let onPin: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.shortName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.primary)
                        .lineLimit(1)
                    fitBadge
                    if isLoaded {
                        PillLite(text: "LOADED", color: Theme.Palette.success)
                    } else if isActive {
                        PillLite(text: "PINNED", color: Theme.Palette.accent)
                    } else if model.downloaded {
                        PillLite(text: "DOWNLOADED", color: Theme.Palette.accent)
                    }
                }
                Text(metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.m)
            useButton
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s + 1)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(isLoaded ? Theme.Palette.success.opacity(0.5) : Theme.Palette.divider,
                        lineWidth: isLoaded ? 1 : 0.5)
        )
        .opacity(fit == .exceeds ? 0.55 : 1)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let s = model.storageGB { parts.append(String(format: "%.0f GB", s)) }
        if let q = model.quantization, !q.isEmpty { parts.append(q) }
        if let ctx = model.contextLength { parts.append("\(ctx / 1024)K ctx") }
        if let base = model.baseModel, !base.isEmpty { parts.append(base) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var fitBadge: some View {
        switch fit {
        case .fits:    PillLite(text: "FITS", color: Theme.Palette.success)
        case .tight:   PillLite(text: "TIGHT", color: Theme.Palette.warning)
        case .exceeds: PillLite(text: "EXCEEDS", color: Theme.Palette.error)
        case .unknown: EmptyView()
        }
    }

    @ViewBuilder
    private var useButton: some View {
        if isActive {
            Text("Pinned")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.tertiary)
        } else if fit == .exceeds {
            Text("Too large")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.tertiary)
        } else {
            Button(action: onPin) {
                Text("Pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.Palette.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Pin this as the EXO Model ID. Load it from EXO itself — this just points \(AppBranding.displayName) at it.")
        }
    }
}

/// Small capsule badge used by cluster model rows.
private struct PillLite: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
