// ConnectionSettingsView.swift
// AgentOS — Claude Edition
//
// Connection tab of Settings. Mirrors DEV PLAN's ConnectionSettingsView
// with adaptations for this codebase:
//
//   * `@Binding var settings: AppSettings` is preserved so the existing
//     `SettingsViewV2` call site keeps compiling.
//   * Adds `@EnvironmentObject var app: AppViewModel` for action wiring:
//     backend panels and Local API server lifecycle.
//     recentLog), LocalAPIServer lifecycle, and `refreshModels()` after
//     EXO connect.
//   * Uses Claude Edition's `Theme.Palette.*` tokens (no `.tokenGreen`,
//     no `.muted` as foreground) and `.font(.system(...))`.
//
// One panel per backend (matches AI Backend picker); Local API Server +
// Privacy sections always show below.
//

import SwiftUI
import AppKit
import AgentCore

// MARK: - Connection test state

/// Per-backend connection-test status. Each backend panel owns its own
/// `@State` so a Test in LM Studio doesn't blow away an EXO result.
enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success(modelCount: Int)
    case failure(String)
}

// MARK: - Connection pane (chip nav)
//
// Apple HIG: segmented controls are for a *few short* mutually exclusive
// choices. Seven backends with labels like "Custom Endpoint" and
// "Local API Server" will always clip in a single-row NSSegmentedControl.
// Authoritative guidance (HIG + Stack Overflow / Apple Forums consensus):
// use a menu, radio list, or wrapping chip/button group when labels are
// long or options exceed ~4.
//
// We use a wrapping chip grid so every full label is visible, no
// horizontal clipping. Selection only changes which pane is shown —
// active backend routing stays on each pane's ActiveBackendChip.

private enum ConnectionPane: String, CaseIterable, Identifiable {
    case lmStudio, exo, omlx, ollama, unslothStudio, custom, localAPI

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lmStudio:       return "LM Studio"
        case .exo:            return "EXO"
        case .omlx:           return "oMLX"
        case .ollama:         return "Ollama"
        case .unslothStudio:  return "Unsloth Studio"
        case .custom:         return "Custom Endpoint"
        case .localAPI:       return "Local API Server"
        }
    }

    var icon: String {
        switch self {
        case .lmStudio:       return "desktopcomputer"
        case .exo:            return "dot.radiowaves.left.and.right"
        case .omlx:           return "server.rack"
        case .ollama:         return "terminal.fill"
        case .unslothStudio:  return "flame.fill"
        case .custom:         return "link"
        case .localAPI:       return "network"
        }
    }

    /// Initial pane on Settings open — land on whichever backend is
    /// currently active so the user sees the most relevant config
    /// first. Local API Server is never the default landing pane.
    static func initial(forActive backend: BackendIdentifier) -> ConnectionPane {
        switch backend {
        case .mlx, .xai: return .lmStudio   // xAI / Grok removed from product
        case .lmStudio:  return .lmStudio
        case .exo:       return .exo
        case .omlx:      return .omlx
        case .ollama:    return .ollama
        case .unslothStudio: return .unslothStudio
        case .custom:    return .custom
        }
    }
}

// MARK: - Root view

struct ConnectionSettingsView: View {
    @Binding var settings: AppSettings
    @EnvironmentObject var app: AppViewModel

    @State private var selectedPane: ConnectionPane = .ollama

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {

            // ── Wrapping backend chips (full labels, no clip) ────────────
            connectionPaneSwitcher

            // ── Selected pane ────────────────────────────────────────────
            switch selectedPane {
            case .lmStudio: LMStudioPanel(settings: $settings)
            case .exo:      EXOPanel(settings: $settings)
            case .omlx:     OMLXPanel(settings: $settings)
            case .ollama:   OllamaPanel(settings: $settings)
            case .unslothStudio: UnslothStudioPanel(settings: $settings)
            case .custom:   CustomEndpointPanel(settings: $settings)
            case .localAPI:
                LocalAPIServerSection(settings: $settings)
                XcodeMCPSection(settings: $settings)
            }
            // Crash-reporting / privacy toggle now lives solely in the
            // Privacy tab (removed the duplicate that used to
            // sit here under Connection).
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            selectedPane = .initial(forActive: settings.backend)
        }
    }

    /// Adaptive grid of selectable chips. Columns reflow as the detail
    /// column width changes so "Custom Endpoint" / "Local API Server"
    /// never truncate against the sheet edge.
    private var connectionPaneSwitcher: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configure")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.tertiary)
                .textCase(.uppercase)
                .tracking(0.4)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 148, maximum: 200), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(ConnectionPane.allCases) { pane in
                    connectionPaneChip(pane)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectionPaneChip(_ pane: ConnectionPane) -> some View {
        let on = selectedPane == pane
        return Button {
            withAnimation(Theme.Motion.quick) { selectedPane = pane }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: pane.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? Theme.Palette.accent : Theme.Palette.secondary)
                    .frame(width: 14, alignment: .center)
                Text(pane.label)
                    .font(.system(size: 12, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.Palette.primary : Theme.Palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? Theme.Palette.accent.opacity(0.14) : Theme.Palette.subtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        on ? Theme.Palette.accent.opacity(0.45) : Theme.Palette.divider,
                        lineWidth: on ? 1 : 0.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pane.label)
        .accessibilityLabel(pane.label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Active-backend chip
//
// Header chip for each backend card. Shows "Active ✓" (filled accent)
// when the card's backend is the one AgentOS is currently routing
// through. Otherwise renders a "Use this backend" button that flips
// the active backend on tap via `app.updateSettings`.
//
// Replaces the segmented Backend picker that used to sit at the top
// of Connection settings. With all three backend cards visible at
// once, the picker became redundant — switching active is now done
// where the switch logically lives: on the card itself.

private struct ActiveBackendChip: View {
    let backend: BackendIdentifier
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        if app.settings.backend == backend {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                Text("Active")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Theme.Palette.accent)
            .clipShape(Capsule())
        } else {
            Button {
                // Same path as Model → Backend strip: flip routing + refresh models.
                app.activateBackend(backend)
            } label: {
                Text("Use this backend")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.Palette.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .stroke(Theme.Palette.accent.opacity(0.4),
                                    lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Make this the backend \(AppBranding.displayName) routes chat through")
        }
    }
}

// MARK: - LM Studio panel

private struct LMStudioPanel: View {
    @Binding var settings: AppSettings
    @EnvironmentObject var app: AppViewModel

    @State private var testState: ConnectionTestState = .idle
    @State private var portText: String = "1234"

    var body: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .foregroundColor(Theme.Palette.accent)
                    Text("LM Studio")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Palette.primary)
                    Spacer()
                    ActiveBackendChip(backend: .lmStudio)
                }

                Text("Connect to a running LM Studio server (Developer → Local Server, default port 1234). Downloaded models appear in the picker; selecting one loads it if needed.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HostRow(label: "Host",
                        placeholder: "127.0.0.1",
                        value: Binding(
                            get: { settings.lmStudioHost },
                            set: { v in app.persistSettings { $0.lmStudioHost = v } }
                        ))

                PortRow(label: "Port",
                        intValue: Binding(
                            get: { settings.lmStudioPort },
                            set: { v in app.persistSettings { $0.lmStudioPort = v } }
                        ),
                        textBuffer: $portText)

                baseURLRow("http://\(settings.lmStudioHost):\(settings.lmStudioPort)/v1")

                HStack {
                    Text("API Key")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.primary)
                        .frame(width: 80, alignment: .leading)
                    SecureField("Optional", text: Binding(
                        get: { settings.lmStudioAPIKey },
                        set: { v in app.persistSettings { $0.lmStudioAPIKey = v } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                }

                TestConnectionRow(testState: $testState) {
                    await testLMStudio()
                }

                Toggle(isOn: Binding(
                    get: { settings.lmStudioAutoConnect },
                    set: { v in app.updateSettings { $0.lmStudioAutoConnect = v } }
                )) {
                    Text("Auto-connect on launch")
                        .font(.system(size: 12))
                }
            }
        }
        .onAppear { portText = "\(settings.lmStudioPort)" }
    }

    private func testLMStudio() async {
        await MainActor.run {
            testState = .testing
            app.applySettingsSideEffects()
        }
        let host = settings.lmStudioHost
        let port = settings.lmStudioPort
        let key = settings.lmStudioAPIKey.isEmpty ? nil : settings.lmStudioAPIKey
        do {
            let backend = LMStudioBackend(host: host, port: port, apiKey: key)
            let models = try await backend.listModels()
            // P0: applyActivations + mirror first model via applyActivation.
            await app.ingestConnectionTestModels(models)
            await MainActor.run { testState = .success(modelCount: models.count) }
        } catch {
            await MainActor.run { testState = .failure(error.localizedDescription) }
        }
    }
}

// MARK: - EXO panel

private struct EXOPanel: View {
    @Binding var settings: AppSettings
    @EnvironmentObject var app: AppViewModel

    @State private var testState: ConnectionTestState = .idle
    @State private var portText: String = "52415"

    /// EXO's integrations page URL — same host:port as the API but
    /// served at `/#/integrations`. The "Running model" line on this
    /// page is the canonical source for the loaded model ID across
    /// every current EXO build.
    private var integrationsURL: URL? {
        URL(string: "http://\(settings.exoHost):\(settings.exoPort)/#/integrations")
    }

    var body: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundColor(Theme.Palette.accent)
                    Text("EXO Cluster")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Palette.primary)
                    Spacer()
                    ActiveBackendChip(backend: .exo)
                }

                Text("EXO hosts one model at a time. Paste the exact model ID EXO has loaded, then click Connect. EXO exposes an OpenAI-compatible API on port 52415.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HostRow(label: "Host",
                        placeholder: "127.0.0.1",
                        value: Binding(
                            get: { settings.exoHost },
                            set: { v in app.persistSettings { $0.exoHost = v } }
                        ))

                PortRow(label: "Port",
                        intValue: Binding(
                            get: { settings.exoPort },
                            set: { v in app.persistSettings { $0.exoPort = v } }
                        ),
                        textBuffer: $portText)

                baseURLRow("http://\(settings.exoHost):\(settings.exoPort)/v1",
                           label: "Endpoint")

                // Permanent Model ID field — the user copies this from
                // EXO's own dashboard. We deliberately do NOT try to
                // auto-detect: EXO's API surface doesn't reliably name
                // the loaded model on current builds, and silent wrong
                // guesses fail at first chat turn with a confusing 404.
                HStack {
                    Text("Model ID")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.primary)
                        .frame(width: 80, alignment: .leading)
                    TextField("e.g. mlx-community/gpt-oss-20b-MXFP4-Q8",
                              text: Binding(
                                get: { settings.exoModelID },
                                set: { v in app.persistSettings { $0.exoModelID = v } }
                              ))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await connect() } }
                }

                // Inline guide — exactly the workflow that works:
                // open EXO's integrations page, copy "Running model".
                HStack(spacing: 4) {
                    Text("Find this in EXO's dashboard:")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                    if let url = integrationsURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 3) {
                                Text("Open Integrations page")
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10))
                            }
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Palette.accent)
                        }
                        .buttonStyle(.plain)
                        .help(url.absoluteString)
                    }
                    Spacer()
                }
                .padding(.leading, 84)  // align under the field

                // Connect — pings reachability, then pins the typed ID.
                HStack(spacing: Theme.Spacing.s) {
                    Button {
                        Task { await connect() }
                    } label: {
                        if case .testing = testState {
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.65)
                                Text("Connecting…").font(.system(size: 12))
                            }
                        } else {
                            Text("Connect").font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(testState == .testing
                              || settings.exoModelID
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty)

                    switch testState {
                    case .success:
                        Label("Connected — using \(settings.exoModelID)",
                              systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Palette.success)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Palette.error)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    default:
                        EmptyView()
                    }
                }

                Toggle(isOn: Binding(
                    get: { settings.exoAutoConnect },
                    set: { v in app.updateSettings { $0.exoAutoConnect = v } }
                )) {
                    Text("Auto-connect on launch")
                        .font(.system(size: 12))
                }

                Divider().padding(.vertical, 2)

                // Quick-start command snippets.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start EXO in terminal:")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                    codeSnippetView("python -m exo")

                    Text("Or with a specific model:")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                        .padding(.top, 2)
                    codeSnippetView("python -m exo run <your-model>")
                }
            }
        }
        .onAppear { portText = "\(settings.exoPort)" }
    }

    /// Pings EXO for reachability, then pins the typed Model ID as
    /// the active EXO model. We trust the user — auto-detect was
    /// dropped because EXO doesn't reliably name the loaded model
    /// over any API surface. The ping prevents silent pinning
    /// against a dead host.
    private func connect() async {
        await MainActor.run { testState = .testing }
        let host = settings.exoHost
        let port = settings.exoPort
        let typed = settings.exoModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            await MainActor.run { testState = .failure("Enter the model ID EXO has loaded.") }
            return
        }
        do {
            let backend = EXOBackend(host: host, port: port, pinnedModelID: typed)
            _ = try await backend.discoverAvailableModelIDs()  // reachability only
            let descriptor = ModelDescriptor(id: typed,
                                             displayName: typed,
                                             backend: .exo,
                                             supportsTools: true)
            await MainActor.run {
                app.availableModels = [descriptor]
                app.selectedModelID = typed
                testState = .success(modelCount: 1)
            }
        } catch {
            await MainActor.run {
                testState = .failure("Can't connect to EXO at \(host):\(port) — \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - oMLX panel

private struct OMLXPanel: View {
    @Binding var settings: AppSettings
    @EnvironmentObject var app: AppViewModel

    @State private var testState: ConnectionTestState = .idle
    @State private var portText: String = "8080"

    var body: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .foregroundColor(Theme.Palette.accent)
                    Text("oMLX")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Palette.primary)
                    Spacer()
                    ActiveBackendChip(backend: .omlx)
                }

                Text("Connect to a running oMLX server. Start oMLX, load a model, and it exposes an OpenAI-compatible API on port 8080.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HostRow(label: "Host",
                        placeholder: "127.0.0.1",
                        value: Binding(
                            get: { settings.omlxHost },
                            set: { v in app.persistSettings { $0.omlxHost = v } }
                        ))

                PortRow(label: "Port",
                        intValue: Binding(
                            get: { settings.omlxPort },
                            set: { v in app.persistSettings { $0.omlxPort = v } }
                        ),
                        textBuffer: $portText)

                baseURLRow("http://\(settings.omlxHost):\(settings.omlxPort)/v1")

                HStack {
                    Text("API Key")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.primary)
                        .frame(width: 80, alignment: .leading)
                    SecureField("Optional — from OMLX_API_KEY env",
                                text: Binding(
                                    get: { settings.omlxAPIKey },
                                    set: { v in app.persistSettings { $0.omlxAPIKey = v } }
                                ))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                }

                TestConnectionRow(testState: $testState) {
                    await testOMLX()
                }
            }
        }
        .onAppear { portText = "\(settings.omlxPort)" }
    }

    private func testOMLX() async {
        await MainActor.run {
            testState = .testing
            app.applySettingsSideEffects()
        }
        let host = settings.omlxHost
        let port = settings.omlxPort
        let key = settings.omlxAPIKey.isEmpty ? nil : settings.omlxAPIKey
        do {
            let backend = OMLXBackend(host: host, port: port, apiKey: key)
            let models = try await backend.listModels()
            await app.ingestConnectionTestModels(models)
            await MainActor.run { testState = .success(modelCount: models.count) }
        } catch {
            await MainActor.run { testState = .failure(error.localizedDescription) }
        }
    }
}

// MARK: - Ollama panel

private struct OllamaPanel: View {
    @Binding var settings: AppSettings
    @EnvironmentObject var app: AppViewModel

    @State private var testState: ConnectionTestState = .idle
    @State private var portText: String = "11434"

    var body: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(Theme.Palette.accent)
                    Text("Ollama")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Palette.primary)
                    Spacer()
                    ActiveBackendChip(backend: .ollama)
                }

                Text("Connect to a running Ollama server for a redundant local model path. Ollama exposes an OpenAI-compatible API on port 11434 by default (`ollama serve`).")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HostRow(label: "Host",
                        placeholder: "127.0.0.1",
                        value: Binding(
                            get: { settings.ollamaHost },
                            set: { v in app.persistSettings { $0.ollamaHost = v } }
                        ))

                PortRow(label: "Port",
                        intValue: Binding(
                            get: { settings.ollamaPort },
                            set: { v in app.persistSettings { $0.ollamaPort = v } }
                        ),
                        textBuffer: $portText)

                baseURLRow("http://\(settings.ollamaHost):\(settings.ollamaPort)/v1")

                TestConnectionRow(testState: $testState) {
                    await testOllama()
                }

                Toggle(isOn: Binding(
                    get: { settings.ollamaAutoConnect },
                    set: { v in app.updateSettings { $0.ollamaAutoConnect = v } }
                )) {
                    Text("Auto-connect on launch")
                        .font(.system(size: 12))
                }

                Divider().padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Start Ollama in terminal:")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                    codeSnippetView("ollama serve")

                    Text("Pull a model first if needed:")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                        .padding(.top, 2)
                    codeSnippetView("ollama pull llama3.2")
                }
            }
        }
        .onAppear { portText = "\(settings.ollamaPort)" }
    }

    private func testOllama() async {
        await MainActor.run {
            testState = .testing
            app.applySettingsSideEffects()
        }
        let host = settings.ollamaHost
        let port = settings.ollamaPort
        do {
            let backend = OllamaBackend(host: host, port: port)
            let models = try await backend.listModels()
            await app.ingestConnectionTestModels(models)
            await MainActor.run { testState = .success(modelCount: models.count) }
        } catch {
            await MainActor.run { testState = .failure(error.localizedDescription) }
        }
    }
}

// MARK: - Unsloth Studio panel

private struct UnslothStudioPanel: View {
    @Binding var settings: AppSettings
    @EnvironmentObject var app: AppViewModel

    @State private var testState: ConnectionTestState = .idle
    @State private var portText: String = "8888"

    var body: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .foregroundColor(Theme.Palette.accent)
                    Text("Unsloth Studio")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Palette.primary)
                    Spacer()
                    ActiveBackendChip(backend: .unslothStudio)
                }

                Text("Connect to a running Unsloth Studio server (default port 8888). Models from Studio’s models folder and cache appear in the picker; you can load and unload them from the model list without opening Studio.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HostRow(label: "Host",
                        placeholder: "127.0.0.1",
                        value: Binding(
                            get: { settings.unslothHost },
                            set: { v in app.persistSettings { $0.unslothHost = v } }
                        ))

                PortRow(label: "Port",
                        intValue: Binding(
                            get: { settings.unslothPort },
                            set: { v in app.persistSettings { $0.unslothPort = v } }
                        ),
                        textBuffer: $portText)

                baseURLRow("http://\(settings.unslothHost):\(settings.unslothPort)/v1")

                HStack {
                    Text("API Key")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.primary)
                        .frame(width: 80, alignment: .leading)
                    SecureField("Optional — auto-reads local Studio agent key",
                                text: Binding(
                                    get: { settings.unslothAPIKey },
                                    set: { v in app.persistSettings { $0.unslothAPIKey = v } }
                                ))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                }

                Text("Studio requires a Bearer token. Leave blank to use the key minted under ~/.unsloth/studio/auth/ when present.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                TestConnectionRow(testState: $testState) {
                    await testUnsloth()
                }

                Toggle(isOn: Binding(
                    get: { settings.unslothAutoConnect },
                    set: { v in app.updateSettings { $0.unslothAutoConnect = v } }
                )) {
                    Text("Auto-connect on launch")
                        .font(.system(size: 12))
                }
            }
        }
        .onAppear { portText = "\(settings.unslothPort)" }
    }

    private func testUnsloth() async {
        await MainActor.run {
            testState = .testing
            app.applySettingsSideEffects()
        }
        let host = settings.unslothHost
        let port = settings.unslothPort
        let key = settings.unslothAPIKey.isEmpty ? nil : settings.unslothAPIKey
        do {
            let backend = UnslothStudioBackend(host: host, port: port, apiKey: key)
            let models = try await backend.listModels()
            await app.ingestConnectionTestModels(models)
            await MainActor.run { testState = .success(modelCount: models.count) }
        } catch {
            await MainActor.run { testState = .failure(error.localizedDescription) }
        }
    }
}

// MARK: - Custom Endpoint panel

private struct CustomEndpointPanel: View {
    @Binding var settings: AppSettings
    @EnvironmentObject var app: AppViewModel

    @State private var endpointText: String = ""
    @State private var testState: ConnectionTestState = .idle

    var body: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .foregroundColor(Theme.Palette.accent)
                    Text("Custom Endpoint")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Palette.primary)
                    Spacer()
                    ActiveBackendChip(backend: .custom)
                }

                Text("Connect to any OpenAI-compatible API server — OpenRouter, Groq, Together AI, vLLM, llama.cpp server, text-generation-webui, oMLX, or any service that exposes /v1/chat/completions and /v1/models.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Endpoint")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.primary)
                        .frame(width: 80, alignment: .leading)

                    TextField("http://127.0.0.1:8080/v1", text: $endpointText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }

                Text("Include http:// (or https://). Example: http://127.0.0.1:8080/v1 — bare host:port is accepted and normalized.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("API Key")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.primary)
                        .frame(width: 80, alignment: .leading)

                    SecureField("Optional", text: Binding(
                        get: { settings.customAPIKey },
                        set: { v in app.persistSettings { $0.customAPIKey = v } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                }

                if let preview = ConnectionSettingsView.normalizedEndpointURL(from: endpointText)?.absoluteString {
                    baseURLRow(preview, label: "Resolved")
                }

                TestConnectionRow(testState: $testState) {
                    await testCustom()
                }
            }
        }
        .onAppear { endpointText = settings.customEndpoint }
        .onChange(of: endpointText) { _, newEndpoint in
            let trimmed = newEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            // Persist as typed; normalize on test / activate so partial edits
            // don't thrash settings while the user is still typing.
            app.persistSettings { $0.customEndpoint = trimmed }
        }
    }

    private func testCustom() async {
        await MainActor.run {
            testState = .testing
            app.applySettingsSideEffects()
        }
        let raw = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = ConnectionSettingsView.normalizedEndpointURL(from: raw) else {
            await MainActor.run {
                testState = .failure(
                    "Invalid endpoint URL. Use e.g. http://127.0.0.1:8080/v1 (include http://)."
                )
            }
            return
        }
        // Write the normalized form so BackendFactory + future tests agree.
        await MainActor.run {
            endpointText = baseURL.absoluteString
            app.updateSettings { $0.customEndpoint = baseURL.absoluteString }
        }
        do {
            let client = OpenAICompatibleClient(
                config: .init(
                    baseURL: baseURL,
                    bearerToken: settings.customAPIKey.isEmpty ? nil : settings.customAPIKey
                )
            )
            let bare = try await client.listModels()
            let models = bare.map {
                ModelDescriptor(
                    id: $0.id,
                    displayName: $0.displayName,
                    backend: .custom,
                    supportsTools: $0.supportsTools,
                    contextLength: $0.contextLength,
                    parameterCountB: $0.parameterCountB
                )
            }
            await app.ingestConnectionTestModels(models)
            // Successful test ⇒ route chat through custom if not already.
            if app.settings.backend != .custom {
                await MainActor.run { app.activateBackend(.custom) }
            } else {
                await app.refreshModels()
            }
            await MainActor.run { testState = .success(modelCount: models.count) }
        } catch {
            await MainActor.run { testState = .failure(error.localizedDescription) }
        }
    }
}

extension ConnectionSettingsView {
    /// Accepts full URLs and common shorthand (`127.0.0.1:8080`, `localhost:8080/v1`).
    /// Strips a pasted `/v1/chat/completions` or `/chat/completions` down to the API root `/v1`.
    static func normalizedEndpointURL(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Strip wrapping quotes users sometimes paste.
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }

        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = "http://" + s
        }

        // If path is empty or just "/", append /v1 (OpenAI-compatible default).
        guard var components = URLComponents(string: s),
              let host = components.host, !host.isEmpty else {
            // URLComponents can fail on some host:port forms; try URL then fix path.
            guard let url = URL(string: s), url.host != nil else { return nil }
            var fallback = URLComponents()
            fallback.scheme = url.scheme
            fallback.host = url.host
            fallback.port = url.port
            let path = url.path
            if path.isEmpty || path == "/" {
                fallback.path = "/v1"
            } else {
                fallback.path = stripChatCompletions(path)
            }
            return fallback.url
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1"
        } else {
            components.path = stripChatCompletions(components.path)
        }
        return components.url
    }

    /// `/v1/chat/completions` and `/chat/completions` both collapse to `/v1`.
    private static func stripChatCompletions(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        let lower = p.lowercased()
        if lower.hasSuffix("/v1/chat/completions") {
            return String(p.dropLast("/chat/completions".count))
        }
        if lower.hasSuffix("/chat/completions") {
            let trimmed = String(p.dropLast("/chat/completions".count))
            if trimmed.lowercased().hasSuffix("/v1") { return trimmed }
            if trimmed.isEmpty || trimmed == "/" { return "/v1" }
            return trimmed + "/v1"
        }
        return p.isEmpty ? "/v1" : p
    }
}

// MARK: - MLX panel (in-process; no connection)

private struct MLXPanel: View {
    var body: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                sectionHeader(icon: "memorychip", title: "MLX")

                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Theme.Palette.warning)
                        .font(.system(size: 13))
                    Text("Not supported in v1")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Palette.primary)
                }
                .padding(Theme.Spacing.s)
                .background(Theme.Palette.warning.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))

                Text("In-process MLX inference is paused for v1. Use Ollama, LM Studio, oMLX, or EXO instead. Persisted `.mlx` selections migrate to Ollama.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Local API Server section

private struct LocalAPIServerSection: View {
    @Binding var settings: AppSettings
    @EnvironmentObject var app: AppViewModel
    @State private var portText: String = "11435"

    var body: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                sectionHeader(icon: "network", title: "Local API Server")

                Text(SettingsDiscoverabilityCopy.localAPIIntro)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: Binding(
                    get: { settings.localAPIEnabled },
                    set: { v in app.updateSettings { $0.localAPIEnabled = v } }
                )) {
                    Text("Run on app launch")
                        .font(.system(size: 12))
                }

                Toggle(isOn: Binding(
                    get: { settings.localAPIAgentToolsEnabled },
                    set: { v in app.updateSettings { $0.localAPIAgentToolsEnabled = v } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SettingsDiscoverabilityCopy.agentToolsToggleTitle)
                            .font(.system(size: 12, weight: .medium))
                        Text(SettingsDiscoverabilityCopy.agentToolsHelpDefaultOff)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Palette.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                Text(SettingsDiscoverabilityCopy.agentToolsStatus(enabled: settings.localAPIAgentToolsEnabled))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.Palette.secondary)

                HStack(spacing: Theme.Spacing.s) {
                    Text("Port")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.primary)
                        .frame(width: 80, alignment: .leading)
                    Stepper(value: Binding(
                        get: { settings.localAPIPort },
                        set: { v in app.persistSettings { $0.localAPIPort = v } }
                    ), in: 1024...65535, step: 1) {
                        Text("\(settings.localAPIPort)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.Palette.primary)
                    }
                    .frame(width: 150)
                }

                HStack(spacing: Theme.Spacing.s) {
                    Button(app.localServerRunning ? "Stop Server" : "Start Server") {
                        Task {
                            if app.localServerRunning {
                                await app.stopLocalServer()
                            } else {
                                await app.startLocalServer()
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Circle()
                        .fill(app.localServerRunning ? Theme.Palette.success : Theme.Palette.tertiary.opacity(0.4))
                        .frame(width: 8, height: 8)

                    Text(app.localServerRunning ? "Listening" : "Stopped")
                        .font(.system(size: 11))
                        .foregroundColor(app.localServerRunning ? Theme.Palette.success : Theme.Palette.tertiary)
                }

                Divider().padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Xcode setup — paste as OpenAI base URL (loopback proxy; tools empty unless agent-loop opt-in is On):")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)

                    HStack(spacing: 6) {
                        Text("http://localhost:\(settings.localAPIPort)/v1")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.Palette.success)
                            .textSelection(.enabled)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                "http://localhost:\(settings.localAPIPort)/v1",
                                forType: .string
                            )
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(Theme.Palette.tertiary)
                        .help("Copy URL")
                    }

                    Text("Endpoints: GET /v1/models · POST /v1/chat/completions")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Palette.tertiary)
                }
            }
        }
    }
}

// MARK: - Xcode MCP section

private struct XcodeMCPSection: View {
    @Binding var settings: AppSettings
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                sectionHeader(icon: "hammer.fill", title: "Xcode MCP Tools")

                Text("Connect \(AppBranding.displayName) to Xcode's native MCP server (same path Claude Code and Codex use). Your agent can build, test, read diagnostics, and render SwiftUI previews inside the open Xcode project.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Prerequisites:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.Palette.primary)
                    Text("1. Xcode running with a project open")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Palette.tertiary)
                    Text("2. Xcode → Settings → Intelligence → MCP → Xcode Tools ON")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Palette.tertiary)
                    Text("3. Approve the permission dialog on first connect")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Palette.tertiary)
                }

                Toggle(isOn: Binding(
                    get: { settings.xcodeMCPEnabled },
                    set: { v in app.updateSettings { $0.xcodeMCPEnabled = v } }
                )) {
                    Text("Enable Xcode MCP tools")
                        .font(.system(size: 12))
                }

                HStack(spacing: Theme.Spacing.s) {
                    if settings.xcodeMCPEnabled {
                        Button("Reconnect") {
                            Task { await app.reconnectXcodeMCP() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    Text(app.xcodeMCPStatus.label)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor)
                        .lineLimit(2)
                }

                Text("Bridge: \(XcodeMCPBridge.defaultBridgePath())")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.Palette.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    private var statusColor: Color {
        switch app.xcodeMCPStatus {
        case .connected: return Theme.Palette.success
        case .connecting: return Theme.Palette.warning
        case .failed: return Theme.Palette.error
        case .disconnected: return Theme.Palette.tertiary.opacity(0.4)
        }
    }
}

// MARK: - Privacy section

// MARK: - Shared sub-views

private struct HostRow: View {
    let label: String
    let placeholder: String
    @Binding var value: String
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.Palette.primary)
                .frame(width: 80, alignment: .leading)
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { app.applySettingsSideEffects() }
        }
    }
}

/// Int-backed port row. Uses a String buffer for smooth TextField editing;
/// commits back to the Int binding on submit or every text change (clamped
/// to the IANA dynamic range).
private struct PortRow: View {
    let label: String
    @Binding var intValue: Int
    @Binding var textBuffer: String
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.Palette.primary)
                .frame(width: 80, alignment: .leading)
            TextField("", text: $textBuffer)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .autocorrectionDisabled()
                .onSubmit {
                    commit()
                    app.applySettingsSideEffects()
                }
                .onChange(of: textBuffer) { _, _ in commit() }
            Spacer()
        }
    }

    private func commit() {
        guard let v = Int(textBuffer), (1024...65535).contains(v) else { return }
        intValue = v
    }
}

@ViewBuilder
private func baseURLRow(_ url: String, label: String = "Base URL") -> some View {
    HStack(spacing: 6) {
        Text(label)
            .font(.system(size: 12))
            .foregroundColor(Theme.Palette.primary)
            .frame(width: 80, alignment: .leading)
        Text(url)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Theme.Palette.tertiary)
            .textSelection(.enabled)
    }
}

private struct TestConnectionRow: View {
    @Binding var testState: ConnectionTestState
    let action: () async -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                Task { await action() }
            } label: {
                if case .testing = testState {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.65)
                        Text("Testing…").font(.system(size: 12))
                    }
                } else {
                    Text("Test Connection").font(.system(size: 12))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(testState == .testing)

            switch testState {
            case .idle, .testing:
                EmptyView()
            case .success(let n):
                Label("Connected — \(n) model\(n == 1 ? "" : "s")",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.success)
            case .failure(let msg):
                Label(msg, systemImage: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.error)
                    .lineLimit(1)
            }
        }
    }
}

@ViewBuilder
private func codeSnippetView(_ code: String) -> some View {
    Text(code)
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(Theme.Palette.primary)
        .textSelection(.enabled)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.codeBlock))
}

// MARK: - Section card / header helpers

/// Visual wrapper used by every panel. Uses `Theme.Palette.subtle` for a
/// gentle card lift over the canvas and a hairline divider tint so the
/// cards don't read as loud GroupBox chrome.
@ViewBuilder
private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Palette.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
}

@ViewBuilder
private func sectionHeader(icon: String, title: String) -> some View {
    HStack(spacing: 6) {
        Image(systemName: icon)
            .foregroundColor(Theme.Palette.accent)
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.Palette.primary)
    }
}

// MARK: - Preview

#if DEBUG
struct ConnectionSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ConnectionSettingsView(settings: .constant(.default))
            .environmentObject(AppViewModel())
            .padding()
            .frame(width: 640)
    }
}
#endif
