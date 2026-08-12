//
//  MCPServersSettingsView.swift
//
//  Settings panel for managing user-configured MCP servers (Streamable HTTP +
//  stdio). Lets the user add, edit, delete, and toggle servers that are
//  exposed to the agent loop as `server__tool` entries.
//
//  The view binds to AppSettings.mcpServers via the standard settings
//  binding pattern used by all other Settings tabs. Changes persist through
//  AppViewModel.updateSettings → SettingsStore (250ms debounced).
//
//  Config file discovery is read-only here — the walker's results are shown
//  as informational context ("3 servers discovered from ~/.vibecoder/mcp.json")
//  but can't be edited from the UI. File-discovered servers merge with
//  AppSettings servers at turn start (see MCPConfigWalker).
//

import SwiftUI
import AppKit
import AgentCore

// MARK: - Main view

struct MCPServersSettingsView: View {
    @Binding var settings: AppSettings
    @EnvironmentObject var app: AppViewModel

    @State private var editingServer: MCPServerConfig?
    @State private var isAddingNew = false
    @State private var showDeleteConfirmation: MCPServerConfig?
    @State private var discoveredSources: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            // Header with explanation.
            VStack(alignment: .leading, spacing: 4) {
                Text("MCP Servers")
                    .font(.system(size: 16, weight: .semibold))
                Text("Add external tool servers using the Model Context Protocol. Tools from enabled servers are available to your agent alongside VibeCoder's built-in tools, namespaced as `server__tool`.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Server list.
            if settings.mcpServers.isEmpty {
                emptyState
            } else {
                VStack(spacing: Theme.Spacing.s) {
                    ForEach(settings.mcpServers) { server in
                        MCPServerRow(
                            server: server,
                            onToggle: { enabled in toggleServer(server, enabled: enabled) },
                            onEdit:   { editingServer = server },
                            onDelete:  { showDeleteConfirmation = server }
                        )
                    }
                }
            }

            // Add button.
            Button {
                editingServer = MCPServerConfig(
                    name: "new-server", transport: .streamableHttp,
                    url: "", enabled: true)
                isAddingNew = true
            } label: {
                Label("Add Server", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            // Config discovery info.
            configDiscoverySection

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.s)
        // Sheet for add/edit.
        .sheet(item: $editingServer) { server in
            MCPServerEditorSheet(
                server: server,
                isNew: isAddingNew,
                onSave: { updated in saveServer(updated) },
                onCancel: {
                    editingServer = nil
                    isAddingNew = false
                }
            )
        }
        // Delete confirmation.
        .alert("Delete \(showDeleteConfirmation?.name ?? "")?", isPresented:
                Binding(get: { showDeleteConfirmation != nil },
                        set: { if !$0 { showDeleteConfirmation = nil } })) {
            Button("Delete", role: .destructive) {
                if let server = showDeleteConfirmation { deleteServer(server) }
                showDeleteConfirmation = nil
            }
            Button("Cancel", role: .cancel) { showDeleteConfirmation = nil }
        } message: {
            Text("This will remove the server from VibeCoder's configuration. If it was discovered from a `.mcp.json` file, that file is not affected.")
        }
        .onAppear { refreshDiscovery() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .center, spacing: Theme.Spacing.s) {
            Image(systemName: "server.rack")
                .font(.system(size: 32))
                .foregroundColor(Theme.Palette.tertiary.opacity(0.5))

            Text("No MCP servers configured")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Palette.tertiary)

            Text("Add a server to connect your agent to external tools via the Model Context Protocol.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
    }

    // MARK: - Config discovery section

    private var configDiscoverySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Discovered Config Sources", systemImage: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Palette.tertiary)

            if discoveredSources.isEmpty {
                Text("No `.mcp.json` files found. VibeCoder walks from the current project's git root to your working directory looking for `.mcp.json` files, plus `~/.vibecoder/mcp.json` for global config.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Palette.tertiary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(discoveredSources, id: \.self) { source in
                    Text(source)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.Palette.tertiary)
                }
            }

            Button("Refresh") { refreshDiscovery() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.system(size: 10))
        }
    }

    // MARK: - Actions

    private func toggleServer(_ server: MCPServerConfig, enabled: Bool) {
        app.updateSettings { settings in
            if let idx = settings.mcpServers.firstIndex(where: { $0.name == server.name }) {
                settings.mcpServers[idx].enabled = enabled
            }
        }
    }

    private func saveServer(_ updated: MCPServerConfig) {
        if isAddingNew {
            // Check for name collision — don't allow duplicates.
            app.updateSettings { settings in
                if !settings.mcpServers.contains(where: { $0.name == updated.name }) {
                    settings.mcpServers.append(updated)
                }
            }
        } else {
            app.updateSettings { settings in
                if let idx = settings.mcpServers.firstIndex(where: { $0.name == updated.name }) {
                    settings.mcpServers[idx] = updated
                }
            }
        }
        editingServer = nil
        isAddingNew = false
    }

    private func deleteServer(_ server: MCPServerConfig) {
        app.updateSettings { settings in
            settings.mcpServers.removeAll { $0.name == server.name }
        }
    }

    private func refreshDiscovery() {
        // Prefer the opened project so project-local `.mcp.json` appears in
        // settings (process cwd is often the app bundle / home, not the repo).
        let cwd = app.openedProject?.url
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        discoveredSources = MCPConfigWalker.describeConfigSources(cwd: cwd)
    }
}

// MARK: - Server row

private struct MCPServerRow: View {
    let server: MCPServerConfig
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isAuthenticated = false
    @State private var authError: String?
    @State private var isProbing = false
    @State private var probeStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.m) {
                // Status dot — green when last probe found tools, else OAuth/enabled.
                Circle()
                    .fill(probeDotColor)
                    .frame(width: 8, height: 8)

                // Server info.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(server.name)
                            .font(.system(size: 12, weight: .semibold))
                        transportBadge
                        if server.oauth != nil {
                            authBadge
                        }
                    }
                    Text(transportDescription)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.Palette.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                // Probe live tools/list (connection status beyond OAuth badge).
                Button(action: { probeConnection() }) {
                    if isProbing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isProbing || !server.enabled)
                .help("Test connection (tools/list)")

                // OAuth sign-in/sign-out button (only for HTTP servers with OAuth).
                if server.oauth != nil, let url = server.url {
                    Button(action: { toggleAuth(url: url) }) {
                        Image(systemName: isAuthenticated
                              ? "checkmark.shield.fill"
                              : "person.badge.key")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help(isAuthenticated
                          ? "Signed in — click to sign out"
                          : "Sign in with OAuth")
                }

                // Toggle.
                Toggle("", isOn: Binding(
                    get: { server.enabled },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .controlSize(.small)

                // Edit / delete buttons.
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Edit")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            .padding(Theme.Spacing.m)

            // OAuth auth status line (when applicable).
            if server.oauth != nil, let url = server.url {
                authStatusLine(url: url)
            }
            if let probeStatus, !probeStatus.isEmpty {
                Text(probeStatus)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.Palette.tertiary)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.bottom, 4)
            }
            if let authError, !authError.isEmpty {
                Text(authError)
                    .font(.system(size: 9))
                    .foregroundColor(Theme.Palette.error)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Palette.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
        .onAppear { refreshAuthStatus(url: server.url) }
    }

    private var statusColor: Color {
        if server.oauth != nil, let url = server.url,
           MCPOAuthCoordinator.shared.isAuthenticated(
                serverName: server.name, serverURL: url) {
            return Theme.Palette.success
        }
        return Theme.Palette.tertiary.opacity(0.5)
    }

    private var probeDotColor: Color {
        if let probeStatus, probeStatus.hasPrefix("OK") {
            return Theme.Palette.success
        }
        if let probeStatus, probeStatus.hasPrefix("Error") {
            return Theme.Palette.error
        }
        return server.enabled ? statusColor : Theme.Palette.tertiary.opacity(0.3)
    }

    private func probeConnection() {
        guard server.enabled else {
            probeStatus = "Error: server disabled"
            return
        }
        isProbing = true
        probeStatus = "Connecting…"
        Task {
            let pool = MCPServerPool(servers: [server])
            await pool.connectAll()
            let tools = await pool.tools()
            let errs = await pool.errors()
            await pool.disconnectAll()
            await MainActor.run {
                isProbing = false
                if let err = errs[server.name] {
                    probeStatus = "Error: \(err)"
                } else {
                    probeStatus = "OK — \(tools.count) tool(s)"
                }
            }
        }
    }

    private var authBadge: some View {
        let isAuth = server.url.map {
            MCPOAuthCoordinator.shared.isAuthenticated(
                serverName: server.name, serverURL: $0)
        } ?? false
        return Text(isAuth ? "OAUTH ✓" : "OAUTH")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(isAuth ? Theme.Palette.success : Theme.Palette.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.Palette.canvas)
            )
    }

    @ViewBuilder
    private func authStatusLine(url: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isAuthenticated
                      ? Theme.Palette.success
                      : Theme.Palette.tertiary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(isAuthenticated
                 ? "Signed in via OAuth"
                 : "Not signed in — click the key icon to authenticate")
                .font(.system(size: 9))
                .foregroundColor(Theme.Palette.tertiary)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.bottom, 6)
    }

    private func refreshAuthStatus(url: String?) {
        guard let url else { return }
        isAuthenticated = MCPOAuthCoordinator.shared.isAuthenticated(
            serverName: server.name, serverURL: url)
    }

    private func toggleAuth(url: String) {
        guard let oauth = server.oauth else { return }
        if isAuthenticated {
            // Sign out.
            MCPOAuthCoordinator.shared.signOut(
                serverName: server.name, serverURL: url)
            isAuthenticated = false
            authError = nil
        } else {
            // Sign in — runs the interactive flow on a background task.
            authError = nil
            Task {
                let ok = await MCPOAuthCoordinator.shared.forceReauthenticate(
                    serverName: server.name,
                    serverURL: url,
                    config: oauth)
                await MainActor.run {
                    isAuthenticated = MCPOAuthCoordinator.shared.isAuthenticated(
                        serverName: server.name, serverURL: url)
                    if !ok {
                        authError = "Sign-in failed or was cancelled. Check OAuth client ID / URLs and try again."
                    }
                }
            }
        }
    }

    private var transportBadge: some View {
        Text(server.transport == .stdio ? "STDIO" : "HTTP")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(Theme.Palette.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.Palette.canvas)
            )
    }

    private var transportDescription: String {
        switch server.transport {
        case .stdio:
            return server.command ?? "(no command)"
        case .streamableHttp:
            return server.url ?? "(no URL)"
        }
    }
}

// MARK: - Editor sheet

private struct MCPServerEditorSheet: View {
    @State var server: MCPServerConfig
    let isNew: Bool
    let onSave: (MCPServerConfig) -> Void
    let onCancel: () -> Void

    @State private var nameError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text(isNew ? "Add MCP Server" : "Edit \(server.name)")
                .font(.system(size: 14, weight: .semibold))

            // Name field.
            VStack(alignment: .leading, spacing: 4) {
                Text("Server Name")
                    .font(.system(size: 11, weight: .medium))
                TextField("my-server", text: $server.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                if let err = nameError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Palette.error)
                }
            }

            // Transport selector.
            Picker("Transport", selection: $server.transport) {
                Text("Streamable HTTP").tag(MCPServerTransport.streamableHttp)
                Text("Stdio (local subprocess)").tag(MCPServerTransport.stdio)
            }
            .pickerStyle(.segmented)

            // Transport-specific fields.
            switch server.transport {
            case .streamableHttp:
                httpFields
            case .stdio:
                stdioFields
            }

            // Common fields.
            commonFields

            Divider()

            // Action buttons.
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Save") { validateAndSave() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(width: 460)
    }

    // MARK: - HTTP fields

    @ViewBuilder
    private var httpFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            labeledField("URL", text: Binding(
                get: { server.url ?? "" },
                set: { server.url = $0 }),
                placeholder: "https://mcp.example.com/sse")

            VStack(alignment: .leading, spacing: 4) {
                Text("Headers (JSON)")
                    .font(.system(size: 11, weight: .medium))
                TextEditorForDict(
                    binding: Binding(
                        get: { server.headers },
                        set: { server.headers = $0 }),
                    placeholder: "{\"Authorization\": \"Bearer ...\"}")
            }

            labeledField("Bearer Token Env Var (optional)",
                         text: Binding(
                            get: { server.bearerTokenEnvVar ?? "" },
                            set: { server.bearerTokenEnvVar = $0.isEmpty ? nil : $0 }),
                         placeholder: "MY_API_TOKEN")

            // OAuth configuration.
            DisclosureGroup("OAuth (optional)", isExpanded: Binding(
                get: { server.oauth != nil },
                set: { expanded in
                    if expanded, server.oauth == nil {
                        // Initialize with empty OAuth config.
                        server.oauth = MCPOAuthConfig(
                            clientID: "",
                            authorizationURL: "",
                            tokenURL: "")
                    } else if !expanded {
                        // Clearing the OAuth config — user opted out.
                        server.oauth = nil
                    }
                })) {
                oauthFields
            }
        }
    }

    /// OAuth configuration fields (shown when the user expands the
    /// DisclosureGroup in the HTTP section).
    @ViewBuilder
    private var oauthFields: some View {
        if server.oauth == nil {
            // Shouldn't happen (the disclosure controls it), but handle
            // gracefully — show a message instead of crashing.
            Text("OAuth configuration cleared.")
                .font(.system(size: 10))
                .foregroundColor(Theme.Palette.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                labeledField("Client ID",
                             text: oauthBinding(\.clientID),
                             placeholder: "your-client-id")

                labeledField("Authorization URL",
                             text: oauthBinding(\.authorizationURL),
                             placeholder: "https://github.com/login/oauth/authorize")

                labeledField("Token URL",
                             text: oauthBinding(\.tokenURL),
                             placeholder: "https://github.com/login/oauth/access_token")

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scopes (space-separated)")
                        .font(.system(size: 11, weight: .medium))
                    TextField("repo issues read:user", text: Binding(
                        get: { server.oauth?.scopes.joined(separator: " ") ?? "" },
                        set: { value in
                            if var oauth = server.oauth {
                                oauth.scopes = value.split(separator: " ")
                                    .map(String.init)
                                server.oauth = oauth
                            }
                        }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }

                // Advanced fields.
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 6) {
                        labeledField("Client Secret (optional)",
                                     text: Binding(
                                        get: { server.oauth?.clientSecret ?? "" },
                                        set: { value in
                                            if var oauth = server.oauth {
                                                oauth.clientSecret = value.isEmpty ? nil : value
                                                server.oauth = oauth
                                            }
                                        }),
                                     placeholder: "confidential-clients-only")

                        HStack(spacing: 8) {
                            Text("Callback Port")
                                .font(.system(size: 11, weight: .medium))
                            TextField("0 = ephemeral", value: Binding(
                                get: { server.oauth?.callbackPort ?? 0 },
                                set: { value in
                                    if var oauth = server.oauth {
                                        oauth.callbackPort = value == 0 ? nil : value
                                        server.oauth = oauth
                                    }
                                }), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        }
                    }
                }

                Text("OAuth uses a loopback redirect (http://127.0.0.1:port/callback) with PKCE — no registered callback URL needed beyond a standard native-app setup.")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Helper to bind a single OAuth config string field.
    private func oauthBinding(_ keyPath: WritableKeyPath<MCPOAuthConfig, String>) -> Binding<String> {
        Binding(
            get: { server.oauth?[keyPath: keyPath] ?? "" },
            set: { value in
                if var oauth = server.oauth {
                    oauth[keyPath: keyPath] = value
                    server.oauth = oauth
                }
            })
    }

    // MARK: - Stdio fields

    @ViewBuilder
    private var stdioFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            labeledField("Command Path",
                         text: Binding(
                            get: { server.command ?? "" },
                            set: { server.command = $0 }),
                         placeholder: "/usr/local/bin/mcp-server")

            VStack(alignment: .leading, spacing: 4) {
                Text("Arguments (one per line)")
                    .font(.system(size: 11, weight: .medium))
                TextEditorForArray(
                    binding: Binding(
                        get: { server.args },
                        set: { server.args = $0 }),
                    placeholder: "--port\n3000")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Environment (JSON)")
                    .font(.system(size: 11, weight: .medium))
                TextEditorForDict(
                    binding: Binding(
                        get: { server.env },
                        set: { server.env = $0 }),
                    placeholder: "{\"API_KEY\": \"...\"}")
            }
        }
    }

    // MARK: - Common fields (timeouts, enabled)

    @ViewBuilder
    private var commonFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Spacing.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Startup Timeout (s)")
                        .font(.system(size: 11, weight: .medium))
                    TextField("30", value: $server.startupTimeout,
                               format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Tool Timeout (s)")
                        .font(.system(size: 11, weight: .medium))
                    TextField("120", value: $server.toolTimeout,
                               format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            Toggle("Enabled", isOn: $server.enabled)
                .font(.system(size: 12))

            // Per-tool timeouts (advanced).
            DisclosureGroup("Per-Tool Timeouts (advanced)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("One `tool_name=seconds` per line. Tool names override the server-level tool timeout.")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Palette.tertiary)
                    TextEditorForDict(
                        binding: Binding(
                            get: { server.toolTimeouts.mapValues { String($0) } },
                            set: { dict in
                                server.toolTimeouts = dict.compactMapValues {
                                    Double($0)
                                }
                            }),
                        placeholder: "expensive_tool=600\nfast_tool=5")
                }
            }
        }
    }

    // MARK: - Validation

    private func validateAndSave() {
        // Validate the server name.
        guard !server.name.isEmpty else {
            nameError = "Name cannot be empty"
            return
        }
        if let err = MCPToolNaming.validate(server.name) {
            nameError = err
            return
        }
        if server.transport == .streamableHttp,
           (server.url ?? "").isEmpty {
            nameError = "HTTP servers require a URL"
            return
        }
        if server.transport == .stdio,
           (server.command ?? "").isEmpty {
            nameError = "Stdio servers require a command path"
            return
        }
        nameError = nil
        onSave(server)
    }

    // MARK: - Helper

    @ViewBuilder
    private func labeledField(_ label: String, text: Binding<String>,
                               placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - Text editor helpers for dict/array

/// Edit a `[String: String]` as newline-separated `key=value` lines.
private struct TextEditorForDict: View {
    @Binding var binding: [String: String]
    let placeholder: String

    @State private var text: String = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 10, design: .monospaced))
            .frame(height: 60)
            .background(Theme.Palette.canvas)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
            .onAppear { syncFromDict() }
            .onChange(of: text) { _, _ in syncToDict() }
    }

    private func syncFromDict() {
        text = binding.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    private func syncToDict() {
        var dict: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                dict[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1])
            }
        }
        binding = dict
    }
}

/// Edit a `[String]` as newline-separated entries.
private struct TextEditorForArray: View {
    @Binding var binding: [String]
    let placeholder: String

    @State private var text: String = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 10, design: .monospaced))
            .frame(height: 40)
            .background(Theme.Palette.canvas)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
            .onAppear { syncFromArray() }
            .onChange(of: text) { _, _ in syncToArray() }
    }

    private func syncFromArray() {
        text = binding.joined(separator: "\n")
    }

    private func syncToArray() {
        binding = text.split(separator: "\n").map(String.init)
    }
}