//
//  ModelPickerButton.swift
//
//  Model picker in the input card: popover with search across every
//  provider VibeCoder can reach, plus curated catalog entries recognized
//  by the app even when they are not currently loaded.
//

import SwiftUI
import AgentCore

struct ModelPickerButton: View {
    @Binding var selectedModelID: String

    @EnvironmentObject private var app: AppViewModel
    @State private var showMenu = false
    @State private var searchText = ""
    @State private var expanded: [String: Bool] = ModelPickerButton.loadExpanded()
    @State private var providerRows: [ProviderModelRow] = []
    @State private var isRefreshing = false
    @FocusState private var searchFocused: Bool

    private static let storageKey = "vibecoder.modelPicker.expanded"

    private static let defaultExpanded: [String: Bool] = [
        "active": true,
        "lmStudio": true,
        "omlx": true,
        "ollama": true,
        "unslothStudio": true,
        "exo": true,
        "custom": true,
        "mlx": true,
        "catalog": true,
    ]

    private static func loadExpanded() -> [String: Bool] {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            return defaultExpanded.merging(decoded) { _, persisted in persisted }
        }
        return defaultExpanded
    }

    private func saveExpanded() {
        if let data = try? JSONEncoder().encode(expanded) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func isExpanded(_ id: String) -> Bool { expanded[id] ?? true }

    private func toggle(_ id: String) {
        expanded[id, default: true].toggle()
        saveExpanded()
    }

    // MARK: - Display

    private var displayName: String {
        if selectedModelID.isEmpty {
            return providerRows.isEmpty && app.availableModels.isEmpty
                ? "No model"
                : "Select model"
        }
        if let m = providerRows.first(where: { $0.modelID == selectedModelID }) {
            return Self.prettyModelName(m.displayName)
        }
        if let m = app.availableModels.first(where: { $0.id == selectedModelID }) {
            return Self.prettyModelName(m.displayName)
        }
        return Self.prettyModelName(selectedModelID)
    }

    /// Trims wire names for the chip: drop .gguf, split-file suffix, simplify quant.
    /// `nonisolated` so plain model-row helpers can call it off the main actor.
    nonisolated static func prettyModelName(_ raw: String) -> String {
        var s = raw
        if s.hasSuffix(".gguf") { s.removeLast(5) }
        s = s.replacingOccurrences(of: #"-\d{5}-of-\d{5}$"#,
                                   with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"-(Q\d+)(_[A-Z](_[A-Z])?|_0)?\b"#,
                                   with: "-$1",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "-", with: " ")
        return s
    }

    // MARK: - Sections + search

    private var filteredSections: [PickerSection] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = q.isEmpty
            ? providerRows
            : providerRows.filter { $0.matches(query: q) }

        let activeBackend = app.settings.backend
        var byKey: [String: (label: String, rows: [ProviderModelRow])] = [:]

        for row in rows {
            let key: String
            let label: String
            if row.isLive && row.backend == activeBackend {
                key = "active"
                label = "Active · \(Self.backendTitle(activeBackend))"
            } else if row.isLive {
                key = row.backend.rawValue
                label = Self.backendTitle(row.backend)
            } else {
                key = "catalog"
                label = "Recognized catalog (not loaded)"
            }
            var bucket = byKey[key] ?? (label, [])
            bucket.rows.append(row)
            byKey[key] = bucket
        }

        // Prefer Active first, then live providers, then catalog.
        let order = ["active"]
            + BackendIdentifier.allCasesForPicker.map(\.rawValue)
            + ["catalog"]

        return order.compactMap { key in
            guard let bucket = byKey[key], !bucket.rows.isEmpty else { return nil }
            let sorted = bucket.rows.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return PickerSection(id: key, label: bucket.label, models: sorted)
        }
    }

    nonisolated static func backendTitle(_ id: BackendIdentifier) -> String {
        switch id {
        case .lmStudio: return "LM Studio"
        case .exo:      return "EXO"
        case .mlx:      return "MLX"
        case .omlx:     return "oMLX"
        case .ollama:   return "Ollama"
        case .unslothStudio: return "Unsloth Studio"
        case .xai:      return "xAI"   // not listed in picker; label only for legacy rows
        case .custom:   return "Custom endpoint"
        }
    }

    // MARK: - Body

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { showMenu.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
            .foregroundStyle(Theme.Palette.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(showMenu ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .inputCardUpwardPopup(isPresented: $showMenu, alignment: .trailing) {
            InputCardPopupChrome(
                width: InputCardPopupStyle.modelMenuWidth,
                maxHeight: InputCardPopupStyle.modelMenuMaxHeight,
                includePadding: false
            ) {
                modelMenu
            }
        }
        .task(id: showMenu) {
            guard showMenu else { return }
            await refreshProviderRows()
            try? await Task.sleep(nanoseconds: 50_000_000)
            searchFocused = true
        }
        .onChange(of: showMenu) { _, open in
            if !open { searchText = "" }
        }
    }

    private var modelMenu: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider().opacity(0.35)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if isRefreshing && providerRows.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Scanning providers…")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Palette.tertiary)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity)
                    } else if filteredSections.isEmpty {
                        Text(searchText.isEmpty
                             ? "No models found.\nOpen Settings → Connection to configure providers."
                             : "No models match “\(searchText)”.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Palette.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(20)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(filteredSections) { section in
                            sectionHeader(id: section.id,
                                          label: section.label,
                                          count: section.models.count)
                            if isExpanded(section.id) {
                                ForEach(section.models) { model in
                                    ModelMenuRow(
                                        model: model,
                                        isSelected: model.modelID == selectedModelID
                                            && (model.backend == app.settings.backend || !model.isLive),
                                        onTap: {
                                            Task {
                                                await app.selectModel(
                                                    backend: model.backend,
                                                    modelID: model.modelID)
                                                selectedModelID = model.modelID
                                                showMenu = false
                                            }
                                        },
                                        onLoad: model.supportsLoadUnload
                                            ? { self.performLoad(model) }
                                            : nil,
                                        onUnload: model.supportsLoadUnload
                                            ? { self.performUnload(model) }
                                            : nil
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 420)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.tertiary)
            TextField("Search models across providers…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit {
                    // Enter selects first match when searching.
                    if let first = filteredSections.first?.models.first {
                        Task {
                            await app.selectModel(backend: first.backend, modelID: first.modelID)
                            selectedModelID = first.modelID
                            showMenu = false
                        }
                    }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                .buttonStyle(.plain)
            }
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    @ViewBuilder
    private func sectionHeader(id: String, label: String, count: Int) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { toggle(id) } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.Palette.tertiary)
                    .rotationEffect(.degrees(isExpanded(id) ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: isExpanded(id))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Palette.tertiary)
                    .tracking(0.3)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.Palette.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Load / unload (picker row actions)

    private func performLoad(_ model: ProviderModelRow) {
        Task { @MainActor in
            _ = await app.loadModel(backend: model.backend, modelID: model.modelID)
            await refreshProviderRows()
        }
    }

    private func performUnload(_ model: ProviderModelRow) {
        Task { @MainActor in
            _ = await app.unloadModel(backend: model.backend, modelID: model.modelID)
            await refreshProviderRows()
        }
    }

    // MARK: - Catalog build

    @MainActor
    private func refreshProviderRows() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let backends = BackendIdentifier.allCasesForPicker
        var live: [ProviderModelRow] = []

        await withTaskGroup(of: [ProviderModelRow].self) { group in
            for id in backends {
                let backend = app.makeBackend(id)
                group.addTask {
                    let models = (try? await backend.listModels()) ?? []
                    return models.map { desc in
                        ProviderModelRow(
                            backend: id,
                            modelID: desc.id,
                            displayName: desc.displayName,
                            contextLength: desc.contextLength,
                            supportsTools: desc.supportsTools,
                            isLive: true,
                            isCurated: false,
                            isLoaded: desc.isLoaded
                        )
                    }
                }
            }
            for await batch in group {
                live.append(contentsOf: batch)
            }
        }

        // Also include whatever the active connection already has (covers race).
        for desc in app.availableModels {
            let row = ProviderModelRow(
                backend: desc.backend,
                modelID: desc.id,
                displayName: desc.displayName,
                contextLength: desc.contextLength,
                supportsTools: desc.supportsTools,
                isLive: true,
                isCurated: false,
                isLoaded: desc.isLoaded
            )
            if !live.contains(where: { $0.identityKey == row.identityKey }) {
                live.append(row)
            }
        }

        // Curated catalog VibeCoder recognizes — shown even when not loaded.
        // Skip in-process MLX seed rows: .mlx is a stub (stream throws) and
        // boot migrates .mlx → .ollama. Listing them only caused failed selects.
        let catalog = ModelCatalogLoader.seed()
        var curated: [ProviderModelRow] = []
        for entry in catalog.gguf {
            // GGUF seed is historical; surface under Ollama as the local GGUF host.
            let row = ProviderModelRow(
                backend: .ollama,
                modelID: entry.ggufFile,
                displayName: entry.displayName,
                contextLength: entry.defaultContextLength,
                supportsTools: entry.toolCapable,
                isLive: false,
                isCurated: true,
                isLoaded: false
            )
            if !live.contains(where: {
                $0.modelID == row.modelID
                    || $0.displayName.localizedCaseInsensitiveContains(
                        entry.displayName.components(separatedBy: " (").first ?? entry.displayName)
            }) {
                curated.append(row)
            }
        }

        providerRows = live + curated
    }
}

// MARK: - Models

private struct PickerSection: Identifiable {
    let id: String
    let label: String
    let models: [ProviderModelRow]
}

struct ProviderModelRow: Identifiable, Hashable {
    /// Unique across providers (same model id can appear on two servers).
    var id: String { identityKey }
    var identityKey: String { "\(backend.rawValue)::\(modelID)" }

    let backend: BackendIdentifier
    let modelID: String
    let displayName: String
    let contextLength: Int?
    let supportsTools: Bool
    /// Currently returned by that provider's /models (or equivalent).
    let isLive: Bool
    /// From VibeCoder's curated seed catalog.
    let isCurated: Bool
    /// Server-resident in memory when known (`nil` = unknown).
    let isLoaded: Bool?

    var supportsLoadUnload: Bool { backend.supportsLoadUnload && isLive }

    func matches(query: String) -> Bool {
        let q = query.lowercased()
        if displayName.lowercased().contains(q) { return true }
        if modelID.lowercased().contains(q) { return true }
        if ModelPickerButton.prettyModelName(displayName).lowercased().contains(q) { return true }
        if backend.rawValue.lowercased().contains(q) { return true }
        if ModelPickerButton.backendTitle(backend).lowercased().contains(q) { return true }
        if supportsTools && "tools".contains(q) { return true }
        if isCurated && ("catalog".contains(q) || "recognized".contains(q)) { return true }
        if !isLive && ("not loaded".contains(q) || "unloaded".contains(q)) { return true }
        if isLoaded == true && ("loaded".contains(q) || "in memory".contains(q)) { return true }
        if isLoaded == false && ("unloaded".contains(q) || "not loaded".contains(q)) { return true }
        return false
    }
}

private extension BackendIdentifier {
    /// Providers the model picker probes. Order = section preference.
    static var allCasesForPicker: [BackendIdentifier] {
        // Omit .mlx — in-process MLX is a stub; boot migrates .mlx → .ollama.
        // Showing it only produces "unsupported" failures after select.
        [.lmStudio, .omlx, .ollama, .unslothStudio, .exo, .custom]
    }
}

// MARK: - Row

private struct ModelMenuRow: View {
    let model: ProviderModelRow
    let isSelected: Bool
    let onTap: () -> Void
    /// Load without selecting / switching backend (provider-native load).
    var onLoad: (() -> Void)? = nil
    /// Unload without selecting.
    var onUnload: (() -> Void)? = nil
    @State private var hovering = false
    @State private var actionBusy = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.Palette.accent)
                            .frame(width: 14)
                    } else {
                        Color.clear.frame(width: 14, height: 14)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ModelPickerButton.prettyModelName(model.displayName))
                            .font(.system(size: 13))
                            .foregroundColor(Theme.Palette.primary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(ModelPickerButton.backendTitle(model.backend))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.Palette.tertiary)
                            if let ctx = model.contextLength {
                                Text("· \(ctx.formatted()) ctx")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.Palette.tertiary)
                            }
                            if model.isLoaded == true {
                                Text("· loaded")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.Palette.success)
                            } else if model.isLoaded == false {
                                Text("· unloaded")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.Palette.tertiary)
                            } else if !model.isLive {
                                Text("· not loaded")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.Palette.warning)
                            }
                        }
                        .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if model.supportsTools {
                        Text("tools")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Theme.Palette.violet)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.Palette.violet.opacity(0.12))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.Palette.violet.opacity(0.25), lineWidth: 0.5))
                    }
                    if model.isCurated && !model.isLive {
                        Text("catalog")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Theme.Palette.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.Palette.accent.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.supportsLoadUnload {
                loadUnloadControl
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? Theme.Palette.hover : Color.clear)
        )
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var loadUnloadControl: some View {
        if actionBusy {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 52, height: 22)
        } else if model.isLoaded == true, let onUnload {
            Button {
                actionBusy = true
                onUnload()
                // Row rebuild after refresh clears busy; timeout safety.
                Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    await MainActor.run { actionBusy = false }
                }
            } label: {
                Text("Unload")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.Palette.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().stroke(Theme.Palette.divider, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Unload from \(ModelPickerButton.backendTitle(model.backend)) memory")
        } else if let onLoad {
            Button {
                actionBusy = true
                onLoad()
                Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    await MainActor.run { actionBusy = false }
                }
            } label: {
                Text("Load")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.Palette.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Theme.Palette.accent.opacity(0.12))
                            .overlay(Capsule().stroke(Theme.Palette.accent.opacity(0.35), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .help("Load into \(ModelPickerButton.backendTitle(model.backend)) memory")
        }
    }
}

// MARK: - Compatibility shim for ModelPickerSheet / other call sites

enum MockPickerData {
    struct Section: Identifiable {
        let id: String
        let label: String
        let models: [PickerModel]
    }

    struct PickerModel: Identifiable, Hashable {
        let model: LMModel
        let prettyName: String
        let subtitle: String?
        let badge: Badge?

        var id: String { model.id }
        var displayName: String { prettyName }

        init(id: String,
             displayName: String,
             backendSource: BackendIdentifier? = nil,
             subtitle: String?,
             badge: Badge?) {
            self.model = LMModel(id: id, backendSource: backendSource)
            self.prettyName = displayName
            self.subtitle = subtitle
            self.badge = badge
        }
    }

    struct Badge: Hashable {
        let label: String
        let color: Color
    }

    /// Legacy static list removed — picker builds live + catalog rows instead.
    static let sections: [Section] = []
    static let defaultSelectedID = ""
}
