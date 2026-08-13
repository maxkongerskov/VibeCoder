//
//  MCPServerPool.swift
//
//  Manages all user-configured MCP servers (both stdio and Streamable HTTP)
//  for a single agent turn. This is VibeCoder's equivalent of Grok Build's
//  `McpPool` — it connects to each enabled server, discovers tools via
//  `tools/list`, and exposes them as namespaced `server__tool` entries.
//
//  The pool is created fresh per turn by the agent loop. It:
//    1. Reads enabled servers from AppSettings
//    2. Connects to each (stdio or HTTP depending on transport)
//    3. Lists tools from each server
//    4. Returns a flat tool-manifest the agent can invoke
//
//  Tool invocation routes back through the pool so the right client is
//  found by server name. This keeps VibeCoder's ToolRegistry simple —
//  it doesn't need to know about transports, just tool names.
//

import Foundation

/// A discovered MCP tool, ready for the agent loop to invoke.
///
/// `@unchecked Sendable` is required because `inputSchema: [String: Any]`
/// stores JSON values that the compiler cannot statically prove Sendable.
/// The schema comes exclusively from `JSONSerialization` (MCP `tools/list`
/// response) and is never mutated after init, so the runtime values are
/// all immutable Foundation value types (NSString/NSNumber/NSArray/
// NSDictionary) — safe to share across isolation boundaries.
public struct MCPDiscoveredTool: @unchecked Sendable {
    /// Namespaced name: `server__tool` (e.g. "github__create_issue").
    public let namespacedName: String
    /// Human-readable description from the server's `tools/list` response.
    public let description: String
    /// JSON Schema for the tool's input parameters (from `tools/list`).
    public let inputSchema: [String: Any]
    /// Server name this tool belongs to (for routing invocations).
    public let serverName: String

    public init(namespacedName: String, description: String,
                inputSchema: [String: Any], serverName: String) {
        self.namespacedName = namespacedName
        self.description = description
        // `inputSchema` is non-Sendable ([String: Any]) but immutable after
        // init. The enclosing struct uses `@unchecked Sendable` to silence
        // the Swift 6 warning — see the struct declaration above.
        self.inputSchema = inputSchema
        self.serverName = serverName
    }

    /// Equality by namespaced name only (schemas may differ in ways
    /// that don't matter for deduplication).
    public static func == (lhs: MCPDiscoveredTool, rhs: MCPDiscoveredTool) -> Bool {
        lhs.namespacedName == rhs.namespacedName
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(namespacedName)
    }

    /// Convert MCP `inputSchema` into the OpenAI-shaped `ToolSchema` the
    /// agent loop sends on `ChatRequest.tools`. Mirrors XcodeMCPBridge
    /// conversion but keeps the **namespaced** tool name.
    public func toToolSchema() -> ToolSchema {
        let properties = (inputSchema["properties"] as? [String: Any]) ?? [:]
        let rawRequired = (inputSchema["required"] as? [String]) ?? []
        var props: [String: ToolSchema.Property] = [:]
        for (key, raw) in properties {
            guard let prop = raw as? [String: Any] else { continue }
            let type = Self.mapJSONSchemaType(prop)
            var desc = prop["description"] as? String ?? ""
            // Surface nested object shape lightly so the model still sees keys
            // even though ToolSchema.Property cannot nest fully.
            if type == "object",
               let nested = prop["properties"] as? [String: Any],
               !nested.isEmpty {
                let keys = nested.keys.sorted().joined(separator: ", ")
                let nestNote = "object keys: \(keys)"
                desc = desc.isEmpty ? nestNote : "\(desc) (\(nestNote))"
            }
            let enumVals = (prop["enum"] as? [String])
                ?? (prop["enum"] as? [Any])?.compactMap { $0 as? String }
            var items: ToolSchema.ItemSpec?
            if let itemsObj = prop["items"] as? [String: Any] {
                // Prefer mapped type (handles type arrays / missing type).
                let itemType = Self.mapJSONSchemaType(itemsObj)
                items = ToolSchema.ItemSpec(type: itemType)
            }
            props[key] = ToolSchema.Property(
                type: type, description: desc, enum: enumVals, items: items)
        }
        // Drop required entries whose properties failed to map — otherwise the
        // model is told a field is required but never sees its schema.
        let required = rawRequired.filter { props[$0] != nil }
        let desc = description.isEmpty
            ? "MCP tool from server '\(serverName)'."
            : description
        return ToolSchema(
            name: namespacedName,
            description: desc,
            parameters: .init(properties: props, required: required))
    }

    private static func mapJSONSchemaType(_ prop: [String: Any]) -> String {
        if let type = prop["type"] as? String {
            return normalizeJSONSchemaType(type)
        }
        // JSON Schema union: "type": ["string", "null"]
        if let types = prop["type"] as? [String] {
            let preferred = types.first { $0 != "null" } ?? types.first ?? "string"
            return normalizeJSONSchemaType(preferred)
        }
        return "string"
    }

    private static func normalizeJSONSchemaType(_ type: String) -> String {
        switch type {
        case "integer": return "integer"
        case "number": return "number"
        case "boolean": return "boolean"
        case "array": return "array"
        case "object": return "object"
        default: return "string"
        }
    }
}

/// Manages connections to all enabled MCP servers for one agent turn.
///
/// Created by `AgentLoop` at turn start. Connects to each server in
/// parallel, lists tools, and exposes a unified manifest. Tool calls
/// route back through `invokeTool()` which finds the right client.
public actor MCPServerPool {

    /// All servers we're managing this turn (config snapshots).
    private let servers: [MCPServerConfig]
    /// Active connections, keyed by server name.
    private var stdioClients: [String: MCPStdioClient] = [:]
    private var httpClients: [String: MCPHttpClient] = [:]
    /// Tools discovered from each server, keyed by namespaced name.
    private(set) var discoveredTools: [MCPDiscoveredTool] = []
    /// Connection errors, keyed by server name (for diagnostics).
    private(set) var connectionErrors: [String: String] = [:]

    public init(servers: [MCPServerConfig]) {
        self.servers = servers.filter { $0.enabled }
    }

    /// Snapshot of tools discovered so far (after `connectAll`).
    public func tools() -> [MCPDiscoveredTool] { discoveredTools }

    /// OpenAI-shaped schemas for every discovered MCP tool (`server__tool`).
    public func toolSchemas() -> [ToolSchema] {
        discoveredTools.map { $0.toToolSchema() }
    }

    /// Connection failures keyed by server name (empty when all OK).
    public func errors() -> [String: String] { connectionErrors }

    /// Connect to all enabled servers in parallel and discover tools.
    ///
    /// Each server connects independently — a failure on one doesn't block
    /// the others. We collect errors so the user can see which servers
    /// failed (displayed in the MCP settings UI).
    public func connectAll() async {
        // Tear down any prior clients first — re-entrant connectAll used to
        // leak stdio processes (cleared tool list but left old clients open).
        if !stdioClients.isEmpty || !httpClients.isEmpty {
            await disconnectAll()
        }
        discoveredTools = []
        connectionErrors = [:]
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask { [weak self] in
                    await self?.connectOne(server)
                }
            }
        }
    }

    /// Connect to a single server and discover its tools.
    private func connectOne(_ server: MCPServerConfig) async {
        switch server.transport {
        case .stdio:
            await connectStdio(server)
        case .streamableHttp:
            await connectHTTP(server)
        }
    }

    // MARK: - Stdio connection

    private func connectStdio(_ server: MCPServerConfig) async {
        guard let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            connectionErrors[server.name] = "Missing or invalid command path"
            return
        }
        // Prefer file-path resolution: MCP configs use absolute paths or
        // bare commands (npx, uvx). `URL(string:)` mis-handles bare names.
        let url = Self.resolveExecutableURL(command)
        guard let url else {
            connectionErrors[server.name] = "Missing or invalid command path: \(command)"
            return
        }

        let client = MCPStdioClient()
        do {
            // Pass the server's env overrides so per-server environment
            // (API keys, PATH additions) are applied to the subprocess.
            try await client.connect(executable: url,
                                     arguments: server.args,
                                     env: server.env)
            let tools = await listTools(client: .stdio(client), serverName: server.name)
            discoveredTools.append(contentsOf: tools)
            stdioClients[server.name] = client
        } catch {
            connectionErrors[server.name] = "stdio connect failed: \(error.localizedDescription)"
        }
    }

    // MARK: - HTTP connection

    private func connectHTTP(_ server: MCPServerConfig) async {
        let client = MCPHttpClient(config: server)

        // If the server has an OAuth config, wire up a token provider
        // before connecting. The provider is non-interactive here — if no
        // token exists yet, the connect will fail with a 401 and the user
        // can trigger an explicit sign-in from the settings UI.
        //
        // The interactive flow (browser) is only triggered on explicit
        // user action, not automatically at turn start — matches Grok
        // Build's "fail closed in non-interactive mode" pattern.
        if let oauth = server.oauth, let urlStr = server.url {
            let serverName = server.name
            let provider = MCPOAuthCoordinator.shared.tokenProvider(
                serverName: serverName,
                serverURL: urlStr,
                config: oauth)
            await client.setOAuthTokenProvider(provider)
            // On HTTP 401, mark access expired so the next provider call
            // runs tryRefresh instead of re-sending the same token.
            await client.setOAuthOnUnauthorized {
                MCPOAuthCoordinator.shared.invalidateAccessToken(
                    serverName: serverName, serverURL: urlStr)
            }

            // Try to ensure we have a token (non-interactive — refresh only,
            // no browser). If this fails, connect() will likely 401.
            _ = try? await MCPOAuthCoordinator.shared.ensureAuthenticated(
                serverName: serverName,
                serverURL: urlStr,
                config: oauth,
                interactive: false)
        }

        do {
            try await client.connect()
            let tools = await listTools(client: .http(client), serverName: server.name)
            discoveredTools.append(contentsOf: tools)
            httpClients[server.name] = client
        } catch {
            connectionErrors[server.name] = "HTTP connect failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Tool discovery

    /// Call `tools/list` on a connected server and map the results to
    /// our `MCPDiscoveredTool` type. Tools are namespaced `server__tool`.
    private func listTools(client: MCPClientRef, serverName: String) async -> [MCPDiscoveredTool] {
        do {
            let payload = try await client.request(method: "tools/list", params: [:], timeout: 30)
            guard let tools = payload.value["tools"] as? [[String: Any]] else {
                // Connected but unusable for the agent — surface like connect failure.
                connectionErrors[serverName] =
                    "tools/list returned no tools array (server connected but discovery failed)"
                Diagnostics.warn("MCP \(serverName): tools/list missing tools array")
                return []
            }
            var skipped = 0
            let mapped: [MCPDiscoveredTool] = tools.compactMap { tool -> MCPDiscoveredTool? in
                guard let name = tool["name"] as? String else {
                    skipped += 1
                    return nil
                }
                // Validate the tool name (cross-provider safety).
                if let validationError = MCPToolNaming.validate(name) {
                    skipped += 1
                    Diagnostics.warn(
                        "MCP \(serverName): skipping invalid tool name: \(validationError)")
                    return nil
                }
                let namespaced = MCPToolNaming.namespaced(server: serverName, tool: name)
                let description = (tool["description"] as? String) ?? ""
                let schema = (tool["inputSchema"] as? [String: Any]) ?? [:]
                return MCPDiscoveredTool(
                    namespacedName: namespaced,
                    description: description,
                    inputSchema: schema,
                    serverName: serverName
                )
            }
            if mapped.isEmpty && !tools.isEmpty {
                connectionErrors[serverName] =
                    "tools/list returned \(tools.count) tool(s) but none passed name validation"
            } else if skipped > 0 {
                Diagnostics.warn(
                    "MCP \(serverName): skipped \(skipped) invalid/unnamed tool(s); kept \(mapped.count)")
            }
            return mapped
        } catch {
            // Previously swallowed — left schemas empty with no connectionErrors entry.
            connectionErrors[serverName] =
                "tools/list failed: \(error.localizedDescription)"
            Diagnostics.warn(
                "MCP \(serverName): tools/list failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Tool invocation

    /// Invoke a tool by its namespaced name. Routes to the right server's
    /// client (stdio or HTTP) based on the `server__` prefix.
    ///
    /// Timeout resolution (per Grok Build's `tool_timeout_for`):
    ///   1. If the tool name has a per-tool override in `server.toolTimeouts`,
    ///      use that.
    ///   2. Otherwise fall back to `server.toolTimeout` (the server-level scalar).
    /// The caller's explicit `timeout:` parameter, when non-default,
    /// wins over both — it lets the loop force a tighter deadline for
    /// headless runs or when a doom-loop is detected.
    public func invokeTool(namespacedName: String, arguments: [String: Any],
                           timeout: TimeInterval = 120) async throws -> MCPJSONPayload {
        // Split on the FIRST `__` so it matches `isMCPToolName` / publish:
        // `demo__foo__bar` → server `demo`, tool `foo__bar`.
        guard let sep = namespacedName.range(of: MCPToolNaming.delimiter) else {
            throw MCPClientError.invalidResponse("Tool name '\(namespacedName)' is not namespaced")
        }
        let server = String(namespacedName[..<sep.lowerBound])
        let tool = String(namespacedName[sep.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else {
            throw MCPClientError.invalidResponse(
                "Tool name '\(namespacedName)' has empty server or tool part")
        }

        // Resolve the per-tool timeout from the server config. If the
        // caller passed an explicit non-default value, honor it; otherwise
        // use config-driven resolution (per-tool map → server scalar).
        let resolvedTimeout: TimeInterval
        if timeout != 120 {
            // Caller override (e.g. headless mode, doom-loop backoff).
            resolvedTimeout = timeout
        } else if let serverConfig = servers.first(where: { $0.name == server }) {
            resolvedTimeout = serverConfig.toolTimeout(for: tool)
        } else {
            resolvedTimeout = timeout
        }

        let method = "tools/call"
        let params: [String: Any] = ["name": tool, "arguments": arguments]

        if let client = stdioClients[server] {
            return try await client.request(method: method, params: params,
                                             timeout: resolvedTimeout)
        }
        if let client = httpClients[server] {
            return try await client.request(method: method, params: params,
                                             timeout: resolvedTimeout)
        }
        throw MCPClientError.notConnected
    }

    // MARK: - Disconnect

    public func disconnectAll() async {
        // Prefer async teardown so stdio read loops finish before we drop refs
        // (sync disconnect alone races the readability handler).
        for (_, client) in stdioClients {
            await client.teardownSession(failPendingWith: MCPClientError.notConnected)
        }
        for (_, client) in httpClients {
            await client.disconnect()
        }
        stdioClients.removeAll()
        httpClients.removeAll()
        discoveredTools = []
    }

    // MARK: - Helpers

    /// Resolve a stdio `command` to a file URL for `Process.executableURL`.
    /// Absolute/tilde paths use `fileURLWithPath`; bare names search PATH
    /// then common locations (`/usr/bin`, `/usr/local/bin`, Homebrew).
    static func resolveExecutableURL(_ command: String) -> URL? {
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        // Bare command — search PATH.
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        let dirs = pathEnv.split(separator: ":").map(String.init)
            + ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        let fm = FileManager.default
        var seen = Set<String>()
        for dir in dirs {
            guard seen.insert(dir).inserted else { continue }
            let candidate = URL(fileURLWithPath: dir)
                .appendingPathComponent(expanded).path
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Merge the server's env overrides with the current process environment.
    private func MergeEnv(_ overrides: [String: String]) -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in overrides { merged[k] = v }
        return merged
    }

    /// Internal enum to abstract over stdio vs HTTP clients when listing
    /// tools (both expose the same `request` method via MCPStdioClient).
    private enum MCPClientRef {
        case stdio(MCPStdioClient)
        case http(MCPHttpClient)

        func request(method: String, params: [String: Any],
                     timeout: TimeInterval) async throws -> MCPJSONPayload {
            // Deep-copy via JSON so we don't transfer caller-isolated
            // `[String: Any]` into actor-isolated client methods (Swift 6).
            let safeParams: [String: Any]
            if JSONSerialization.isValidJSONObject(params),
               let data = try? JSONSerialization.data(withJSONObject: params),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                safeParams = obj
            } else {
                safeParams = [:]
            }
            switch self {
            case .stdio(let c):
                return try await c.request(method: method, params: safeParams, timeout: timeout)
            case .http(let c):
                return try await c.request(method: method, params: safeParams, timeout: timeout)
            }
        }
    }
}