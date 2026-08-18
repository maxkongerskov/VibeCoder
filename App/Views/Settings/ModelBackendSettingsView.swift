// ModelBackendSettingsView.swift
//
// "Model & Backend" tab in Settings. Relocates the two pieces of the
// old SidebarShell that no longer live in the sidebar after ZCode parity:
//
//   1. Engine switcher (active backend: LM Studio / llama.cpp / EXO / oMLX / Ollama)
//   2. Agents panel (two-model mode: orchestrator → worker handoff)
//
// Nothing here is new functionality — both were sidebar controls that
// disappeared when the sidebar became task-centric. Moving them to
// Settings preserves "switch active backend" and "two-model mode"
// without forcing the user back to an engine-centric sidebar.
//
// The reachability probe (green/red dots) moves with the switcher:
// it's what makes "is this backend up" visible, and it belongs next
// to the thing it describes.

import SwiftUI
import AppKit
import AgentCore

struct ModelBackendSettingsView: View {
    @Binding var settings: AppSettings
    @EnvironmentObject private var app: AppViewModel

    /// Reachability probe — same class the old SidebarShell used. Pings
    /// each backend's host:port every 15s and publishes up/down so the
    /// dots reflect reality, not decoration.
    @StateObject private var engineProbe = EngineReachabilityProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {

            // ── Active backend card ─────────────────────────────
            settingsCard {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .foregroundColor(Theme.Palette.accent)
                    Text("Active Backend")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("The backend that runs new chats. Switching here changes where prompts are sent; open backends' own panes in Connection to start them.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)

                engineStrip

                // "Serving on :port" indicator — same as old sidebar.
                if settings.localAPIEnabled {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.Palette.success).frame(width: 6, height: 6)
                        Text(settings.localAPIAgentToolsEnabled
                             ? "Local API on :\(settings.localAPIPort) (agent loop; tools execute, capped)"
                             : "Local API on :\(settings.localAPIPort) (completions only, tools: [])")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.Palette.tertiary)
                    }
                }
            }
            .onAppear { engineProbe.start(settings: settings) }
            .onChange(of: settings) { _, s in engineProbe.start(settings: s) }
            .onDisappear { engineProbe.stop() }

            // ── Two-model (Agents) card ───────────────────────
            settingsCard {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .foregroundColor(Theme.Palette.accent)
                    Text("Agents (Two-Model Mode)")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.orchestratorEnabled },
                        set: { app.setTwoModelEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                if settings.orchestratorEnabled {
                    HStack(spacing: 6) {
                        Button {
                            Task { await app.refreshRoleModelOptions() }
                        } label: {
                            Image(systemName: app.isRefreshingRoleModels
                                  ? "arrow.triangle.2.circlepath"
                                  : "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.Palette.tertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(app.isRefreshingRoleModels)
                        .help("Refresh the model list from all backends")

                        Text(app.orchestrationActive
                              ? "Running 2 models — orchestrator → worker"
                              : (app.roleModelOptions.isEmpty
                                 ? "Loading available models…"
                                 : "Pick a model for each role to enable the handoff"))
                            .font(.system(size: 10))
                            .foregroundColor(app.orchestrationActive
                                             ? Theme.Palette.success
                                             : Theme.Palette.tertiary)
                        Spacer()
                    }
                    .padding(.top, 2)

                    rolePicker(title: "Orchestrator",
                               tint: Theme.Palette.accent,
                               selectedBackend: settings.orchestratorBackend,
                               selectedModelID: settings.orchestratorModelID,
                               isSet: settings.orchestratorBackendSet,
                               onClear: { app.clearRole(.orchestrator) },
                               onPick: { backend, modelID in
                                   app.setOrchestratorModel(backend: backend,
                                                            modelID: modelID)
                               })

                    rolePicker(title: "Worker",
                               tint: Theme.Palette.violet,
                               selectedBackend: settings.workerBackend,
                               selectedModelID: settings.workerModelID,
                               isSet: settings.workerBackendSet,
                               onClear: { app.clearRole(.worker) },
                               onPick: { backend, modelID in
                                   app.setWorkerModel(backend: backend,
                                                      modelID: modelID)
                               })
                } else {
                    Text("Two-model mode pairs an orchestrator (plans) with a worker (executes). Turn on to enable the handoff.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                }
            }
        }
    }

    // MARK: - Engine strip
    //
    // Same four-cell segmented control the old SidebarShell had, just in a
    // settings card. Each cell shows a reachability dot and its label;
    // the active backend gets the accent fill.

    private var engineStrip: some View {
        HStack(spacing: 0) {
            engineCell(.lmStudio, "LM Studio")
            engineCell(.exo, "EXO")
            engineCell(.omlx, "oMLX")
            engineCell(.ollama, "Ollama")
            engineCell(.unslothStudio, "Unsloth")
            engineCell(.custom, "Custom")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.Palette.subtle)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5))
        )
    }

    private func engineCell(_ id: BackendIdentifier, _ label: String) -> some View {
        let active = settings.backend == id
        let reach = engineProbe.status[id] ?? .unknown
        return Button {
            app.activateBackend(id)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor(reach, active: active))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(active ? .white : Theme.Palette.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(active ? Theme.Palette.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(engineHelp(label, reach))
    }

    private func dotColor(_ r: EngineReachabilityProbe.Reachability,
                          active: Bool) -> Color {
        switch r {
        case .up:                 return active ? Theme.Palette.success : Theme.Palette.tertiary
        case .down:               return Theme.Palette.error
        case .checking, .unknown: return Theme.Palette.tertiary
        }
    }

    private func engineHelp(_ label: String,
                            _ r: EngineReachabilityProbe.Reachability) -> String {
        switch r {
        case .up:       return "\(label) — reachable. Click to make it the active backend."
        case .down:     return "\(label) — not reachable. Click to switch anyway (start it in Connection)."
        case .checking: return "\(label) — checking…"
        case .unknown:  return "\(label) — click to make it the active backend."
        }
    }

    // MARK: - Role picker
    //
    // One row per role (Orchestrator / Worker). A label + a Menu that
    // lists every available (backend, model) option grouped by backend.
    // "None" clears the role. Relocated from SidebarShell.rolePicker
    // with the same grouping/checkmark logic so behavior is identical.

    @ViewBuilder
    private func rolePicker(title: String,
                            tint: Color,
                            selectedBackend: BackendIdentifier,
                            selectedModelID: String,
                            isSet: Bool,
                            onClear: @escaping () -> Void,
                            onPick: @escaping (BackendIdentifier, String) -> Void) -> some View {
        let grouped = Dictionary(grouping: app.roleModelOptions, by: \.backend)
        let currentLabel: String = {
            guard isSet, !selectedModelID.isEmpty else { return "Choose model…" }
            if let opt = app.roleModelOptions.first(where: {
                $0.backend == selectedBackend && $0.modelID == selectedModelID
            }) { return opt.displayName }
            return "\(selectedBackend.shortLabel) · \(selectedModelID)"
        }()
        let hasSelection = isSet && !selectedModelID.isEmpty

        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.Palette.tertiary)
                Menu {
                    Button { onClear() } label: {
                        if !hasSelection {
                            Label("None", systemImage: "checkmark")
                        } else { Text("None") }
                    }
                    Divider()
                    if app.roleModelOptions.isEmpty {
                        Text(app.isRefreshingRoleModels
                             ? "Loading…" : "No models — start a backend in Connection")
                    }
                    ForEach([BackendIdentifier.lmStudio,
                              .exo, .omlx, .ollama, .unslothStudio, .custom], id: \.self) { backend in
                        if let opts = grouped[backend], !opts.isEmpty {
                            Section(backend.shortLabel) {
                                ForEach(opts) { opt in
                                    Button {
                                        onPick(opt.backend, opt.modelID)
                                    } label: {
                                        if opt.backend == selectedBackend
                                            && opt.modelID == selectedModelID {
                                            Label(opt.displayName, systemImage: "checkmark")
                                        } else { Text(opt.displayName) }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(hasSelection
                                              ? Theme.Palette.primary
                                              : Theme.Palette.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(Theme.Palette.tertiary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.Palette.subtle)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.Palette.divider, lineWidth: 0.5))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}