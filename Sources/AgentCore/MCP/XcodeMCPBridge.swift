//
//  XcodeMCPBridge.swift
//
//  Connects AgentOS to Xcode's built-in MCP server via `mcpbridge`,
//  discovers the 20 native Xcode tools, and registers them as dynamic
//  proxies in ToolRegistry. Same integration path Claude Code, Codex,
//  and Cursor use — AgentOS becomes an MCP client, Xcode stays the host.
//
//  Prerequisites (user-side):
//    • Xcode running with a project/workspace open
//    • Xcode → Settings → Intelligence → MCP → "Xcode Tools" ON
//    • Approve the permission dialog on first connect
//

import Foundation

public enum XcodeMCPConnectionStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(toolCount: Int, tabIdentifier: String?)
    case failed(String)

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected(let n, _): return "Connected (\(n) tools)"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public actor XcodeMCPBridge {

    public static let shared = XcodeMCPBridge()

    /// Known Xcode MCP tool names (Xcode 26.3+). Used for agent-loop
    /// tool-pruning — these stay in the always-relevant set.
    /// MCP tools that verify builds/tests — counted by edit-verification gate.
    public static let buildVerificationToolNames: Set<String> = [
        "BuildProject", "GetBuildLog", "RunAllTests", "RunSomeTests", "GetTestList",
    ]

    public static let knownToolNames: Set<String> = [
        "BuildProject", "GetBuildLog", "RunAllTests", "RunSomeTests", "GetTestList",
        "XcodeRead", "XcodeWrite", "XcodeUpdate", "XcodeGlob", "XcodeGrep",
        "XcodeLS", "XcodeMakeDir", "XcodeRM", "XcodeMV",
        "XcodeListNavigatorIssues", "XcodeRefreshCodeIssuesInFile",
        // Live Xcode 26 names (tools/list); keep legacy aliases for pruning.
        "ExecuteSnippet", "RunCodeSnippet", "RenderPreview", "DocumentationSearch",
        "XcodeListWindows", "XcodeGetCurrentFile",
    ]

    /// MCP tools that mutate Xcode state — refresh `tabIdentifier` before dispatch.
    public static let mutatingToolNames: Set<String> = [
        "XcodeWrite", "XcodeUpdate", "XcodeRM", "XcodeMV", "XcodeMakeDir",
        "BuildProject", "RunAllTests", "RunSomeTests",
        "ExecuteSnippet", "RunCodeSnippet",
    ]

    /// Seconds before a cached tab id is considered stale (window/project switch).
    public static let tabIdentifierTTL: TimeInterval = 30

    private let client = MCPStdioClient()
    private(set) var status: XcodeMCPConnectionStatus = .disconnected
    private var registeredToolNames: Set<String> = []
    private var cachedTabIdentifier: String?
    private var tabIdentifierCachedAt: Date?
    private var refreshedTabThisTurn = false
    private var bridgePath: String = XcodeMCPBridge.defaultBridgePath()
    /// Coalesce concurrent connect() callers onto one in-flight attempt.
    private var connectTask: Task<Void, Never>?

    public init() {}

    public static func defaultBridgePath() -> String {
        if let xcodeSelect = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            let candidate = (xcodeSelect as NSString).appendingPathComponent("usr/bin/mcpbridge")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        let fallback = "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge"
        if FileManager.default.isExecutableFile(atPath: fallback) { return fallback }
        return fallback
    }

    public func connectionStatus() -> XcodeMCPConnectionStatus { status }

    public func isConnected() -> Bool { status.isConnected }

    public func activeToolNames() -> Set<String> { registeredToolNames }

    /// System-prompt block injected when Xcode MCP tools are live.
    public static let systemPromptBlock = """
    # Xcode MCP tools (live connection to Xcode)

    You have native Xcode tools proxied over MCP — prefer these over shell/`xcodebuild` when Xcode has the project open:
      • Call `XcodeListWindows` first if you don't have a `tabIdentifier` yet.
      • File ops: `XcodeRead`, `XcodeWrite`, `XcodeUpdate`, `XcodeGlob`, `XcodeGrep`, `XcodeLS` (project-navigator paths, not raw filesystem paths).
      • Build/test: `BuildProject`, `GetBuildLog`, `RunAllTests`, `RunSomeTests`, `GetTestList`.
      • Diagnostics: `XcodeListNavigatorIssues`, `XcodeRefreshCodeIssuesInFile`.
      • Intelligence: `RenderPreview` (SwiftUI snapshot), `ExecuteSnippet`, `DocumentationSearch` (Apple docs + WWDC transcripts).

    Do NOT use `xcode_build`, `run_shell xcodebuild`, or filesystem tools for
    project-navigator paths when these MCP tools are available (P0 overlap fix).
    """

    // MARK: - Lifecycle

    public func connect(bridgePath: String? = nil) async {
        // Coalesce concurrent connects (settings toggle + app launch race).
        if let existing = connectTask {
            await existing.value
            return
        }
        let path = bridgePath ?? Self.defaultBridgePath()
        let task = Task { await self.performConnect(bridgePath: path) }
        connectTask = task
        await task.value
        connectTask = nil
    }

    private func performConnect(bridgePath: String) async {
        if case .connected = status, await client.isHealthy() {
            return
        }
        status = .connecting
        self.bridgePath = bridgePath

        guard FileManager.default.isExecutableFile(atPath: self.bridgePath) else {
            let msg = "mcpbridge not found at \(self.bridgePath). Install Xcode 26.3+ and enable Xcode Tools MCP in Settings → Intelligence."
            status = .failed(msg)
            Diagnostics.error("XcodeMCP: \(msg)")
            return
        }

        if !Self.isXcodeRunning() {
            let msg = "Xcode is not running. Open Xcode with a project, enable Settings → Intelligence → MCP → Xcode Tools, then Reconnect."
            status = .failed(msg)
            Diagnostics.error("XcodeMCP: \(msg)")
            return
        }

        await unregisterTools()

        // Retry: first connect after Xcode launch often races the MCP service.
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let url = URL(fileURLWithPath: self.bridgePath)
                try await client.connect(executable: url)
                let tools = try await fetchTools()
                guard !tools.isEmpty else {
                    throw MCPClientError.invalidResponse("tools/list returned zero tools")
                }
                // Tab refresh is best-effort — missing tab still leaves tools usable.
                try? await refreshTabIdentifier()
                try await registerTools(tools)
                status = .connected(toolCount: registeredToolNames.count,
                                    tabIdentifier: cachedTabIdentifier)
                Diagnostics.info("XcodeMCP connected — \(registeredToolNames.count) tools, tab=\(cachedTabIdentifier ?? "none")")
                return
            } catch {
                lastError = error
                await client.teardownSession(failPendingWith: error)
                Diagnostics.warn("XcodeMCP connect attempt \(attempt)/3 failed: \(error.localizedDescription)")
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
                }
            }
        }

        await unregisterTools()
        let msg = lastError?.localizedDescription ?? "Unknown connect failure"
        status = .failed(msg)
        Diagnostics.error("XcodeMCP connect failed: \(msg)")
    }

    public func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        await unregisterTools()
        await client.teardownSession(failPendingWith: MCPClientError.notConnected)
        cachedTabIdentifier = nil
        tabIdentifierCachedAt = nil
        refreshedTabThisTurn = false
        status = .disconnected
        Diagnostics.info("XcodeMCP disconnected")
    }

    public func reconnect() async {
        await disconnect()
        await connect(bridgePath: bridgePath)
    }

    /// Ensure the bridge is healthy before a turn. Reconnects when the
    /// subprocess died or tools were never registered.
    @discardableResult
    public func ensureConnected() async -> Bool {
        if case .connected = status, await client.isHealthy(), !registeredToolNames.isEmpty {
            return true
        }
        await connect(bridgePath: bridgePath)
        return status.isConnected
    }

    /// Reset per-iteration tab refresh state. Call at the start of each
    /// agent-loop tool-dispatch phase so the first mutating MCP call per
    /// turn re-validates the active Xcode window.
    public func beginAgentTurn() async {
        refreshedTabThisTurn = false
        // Heal a dead bridge so the model still has tools mid-session.
        if case .connected = status, !(await client.isHealthy()) {
            Diagnostics.warn("XcodeMCP bridge died mid-session — reconnecting")
            await ensureConnected()
        }
    }

    /// True when at least one Xcode process is running (mcpbridge requires it).
    public static func isXcodeRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "Xcode"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return true // if pgrep fails, don't block connect
        }
    }

    /// Whether `tabIdentifier` should be re-fetched before a mutating call.
    static func needsTabIdentifierRefresh(
        cachedAt: Date?,
        refreshedThisTurn: Bool,
        now: Date = Date(),
        ttl: TimeInterval = tabIdentifierTTL
    ) -> Bool {
        if !refreshedThisTurn { return true }
        guard let cachedAt else { return true }
        return now.timeIntervalSince(cachedAt) > ttl
    }

    // MARK: - Tool sync

    private func fetchTools() async throws -> [[String: Any]] {
        let result = try await client.request(method: "tools/list", params: [:]).value
        guard let tools = result["tools"] as? [[String: Any]] else {
            throw MCPClientError.invalidResponse("tools/list missing tools array")
        }
        return tools
    }

    private func registerTools(_ mcpTools: [[String: Any]]) async throws {
        var names: Set<String> = []
        for entry in mcpTools {
            guard let schema = Self.toolSchema(from: entry) else { continue }
            let permission: ToolPermission = Self.mutatingToolNames.contains(schema.name)
                ? .mutates
                : .readOnly
            let meta = ToolRegistry.ToolMetadata(
                name: schema.name,
                category: Self.category(for: schema.name),
                permission: permission,
                availability: .platformGated(check: { true }),
                schema: schema
            )
            let toolName = schema.name
            await ToolRegistry.shared.registerDynamicTool(metadata: meta) { args, _ in
                _ = await XcodeMCPBridge.shared.ensureConnected()
                return try await XcodeMCPBridge.shared.callTool(name: toolName, arguments: args)
            }
            names.insert(toolName)
        }
        registeredToolNames = names
    }

    private func unregisterTools() async {
        guard !registeredToolNames.isEmpty else { return }
        await ToolRegistry.shared.unregisterDynamicTools(names: registeredToolNames)
        registeredToolNames = []
    }

    // MARK: - Tool dispatch

    public func callTool(name: String, arguments: ToolArguments) async throws -> ToolResult {
        if Self.mutatingToolNames.contains(name) {
            try await ensureFreshTabIdentifier()
        }

        var args = arguments.raw
        if args["tabIdentifier"] == nil, let tab = cachedTabIdentifier {
            args["tabIdentifier"] = tab
        }

        let result = try await client.request(
            method: "tools/call",
            params: ["name": name, "arguments": args],
            timeout: name == "BuildProject" || name.hasPrefix("Run") ? 600 : 180
        ).value

        if name == "XcodeListWindows" {
            if let tab = Self.parseTabIdentifier(from: result) {
                cachedTabIdentifier = tab
                tabIdentifierCachedAt = Date()
            }
        }

        let isError = (result["isError"] as? Bool) ?? false
        let text = Self.formatToolResult(result)
        let mutated = Self.mutatedPaths(from: result, toolName: name)
        return ToolResult(content: text, isError: isError, mutatedPaths: mutated)
    }

    private func ensureFreshTabIdentifier() async throws {
        guard Self.needsTabIdentifierRefresh(
            cachedAt: tabIdentifierCachedAt,
            refreshedThisTurn: refreshedTabThisTurn
        ) else { return }
        try await refreshTabIdentifier()
        refreshedTabThisTurn = true
    }

    private func refreshTabIdentifier() async throws {
        let result = try await client.request(method: "tools/call", params: [
            "name": "XcodeListWindows",
            "arguments": [:] as [String: Any],
        ]).value
        if let tab = Self.parseTabIdentifier(from: result) {
            cachedTabIdentifier = tab
            tabIdentifierCachedAt = Date()
            if case .connected(let count, _) = status {
                status = .connected(toolCount: count, tabIdentifier: tab)
            }
        }
    }

    // MARK: - Parsing helpers

    static func parseTabIdentifier(from toolResult: [String: Any]) -> String? {
        if let structured = toolResult["structuredContent"] as? [String: Any],
           let message = structured["message"] as? String,
           let tab = extractTabIdentifier(from: message) {
            return tab
        }
        if let content = toolResult["content"] as? [[String: Any]] {
            for item in content {
                guard (item["type"] as? String) == "text",
                      let text = item["text"] as? String else { continue }
                if let tab = extractTabIdentifier(from: text) { return tab }
                if let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                   let message = nested["message"] as? String,
                   let tab = extractTabIdentifier(from: message) {
                    return tab
                }
            }
        }
        return nil
    }

    private static func extractTabIdentifier(from text: String) -> String? {
        // "* tabIdentifier: windowtab1, workspacePath: …"
        guard let range = text.range(of: "tabIdentifier:") else { return nil }
        let tail = text[range.upperBound...]
        let token = tail.split(separator: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else { return nil }
        return String(token)
    }

    static func formatToolResult(_ result: [String: Any]) -> String {
        if let structured = result["structuredContent"] {
            if let data = try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
        }
        if let content = result["content"] as? [[String: Any]] {
            let parts = content.compactMap { item -> String? in
                guard (item["type"] as? String) == "text" else { return nil }
                return item["text"] as? String
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    static func mutatedPaths(from result: [String: Any], toolName: String) -> [String] {
        guard ["XcodeWrite", "XcodeUpdate", "XcodeRM", "XcodeMV", "XcodeMakeDir"].contains(toolName)
        else { return [] }
        if let structured = result["structuredContent"] as? [String: Any] {
            if let path = structured["filePath"] as? String { return [path] }
            if let path = structured["absolutePath"] as? String { return [path] }
            if let path = structured["removedPath"] as? String { return [path] }
        }
        return []
    }

    // MARK: - Schema conversion

    static func toolSchema(from mcpTool: [String: Any]) -> ToolSchema? {
        guard let name = mcpTool["name"] as? String,
              let description = mcpTool["description"] as? String,
              let inputSchema = mcpTool["inputSchema"] as? [String: Any]
        else { return nil }

        let properties = inputSchema["properties"] as? [String: Any] ?? [:]
        let required = inputSchema["required"] as? [String] ?? []
        var props: [String: ToolSchema.Property] = [:]

        for (key, raw) in properties {
            guard let prop = raw as? [String: Any] else { continue }
            let type = mapJSONSchemaType(prop)
            let desc = prop["description"] as? String ?? ""
            let enumVals = (prop["enum"] as? [String])
                ?? (prop["enum"] as? [Any])?.compactMap { $0 as? String }
            var items: ToolSchema.ItemSpec?
            if let itemsObj = prop["items"] as? [String: Any],
               let itemType = itemsObj["type"] as? String {
                items = ToolSchema.ItemSpec(type: itemType)
            }
            props[key] = ToolSchema.Property(type: type, description: desc,
                                             enum: enumVals, items: items)
        }

        return ToolSchema(name: name, description: description,
                          parameters: .init(properties: props, required: required))
    }

    static func mapJSONSchemaType(_ prop: [String: Any]) -> String {
        if let type = prop["type"] as? String {
            switch type {
            case "integer": return "integer"
            case "number": return "number"
            case "boolean": return "boolean"
            case "array": return "array"
            case "object": return "object"
            default: return "string"
            }
        }
        return "string"
    }

    static func category(for name: String) -> ToolCategory {
        switch name {
        case "BuildProject", "GetBuildLog", "RunAllTests", "RunSomeTests", "GetTestList":
            return .build
        case "DocumentationSearch":
            return .search
        case "ExecuteSnippet", "RunCodeSnippet", "RenderPreview":
            return .debug
        case "XcodeListNavigatorIssues", "XcodeRefreshCodeIssuesInFile", "XcodeListWindows",
             "XcodeGetCurrentFile":
            return .debug
        default:
            if name.hasPrefix("Xcode") { return .filesystem }
            return .debug
        }
    }
}