//
//  MCPSessionHolder.swift
//
//  Session-scoped MCP pool reuse so consecutive turns do not re-spawn
//  stdio servers and re-run tools/list every send.
//

import Foundation

/// Holds a live `MCPServerPool` keyed by a stable config fingerprint.
/// Disconnect only when config changes or the app explicitly tears down.
public actor MCPSessionHolder {
    public static let shared = MCPSessionHolder()

    private var pool: MCPServerPool?
    private var fingerprint: String = ""
    private var lastSchemas: [ToolSchema] = []

    /// Fingerprint for resolved server configs (order-insensitive).
    public static func fingerprint(of servers: [MCPServerConfig]) -> String {
        servers
            .map { s in
                let cmd = s.command ?? ""
                let url = s.url ?? ""
                let args = s.args.joined(separator: " ")
                return "\(s.name)|\(s.transport.rawValue)|\(cmd)|\(url)|\(args)|\(s.enabled)"
            }
            .sorted()
            .joined(separator: "\n")
    }

    /// Borrow (or create) a connected pool for these servers.
    /// - Returns: (pool, schemas) — pool is already connected when non-nil.
    public func acquire(servers: [MCPServerConfig]) async -> (pool: MCPServerPool?, schemas: [ToolSchema]) {
        let enabled = servers.filter(\.enabled)
        guard !enabled.isEmpty else {
            await release()
            return (nil, [])
        }
        let fp = Self.fingerprint(of: enabled)
        if let pool, fingerprint == fp {
            return (pool, lastSchemas)
        }
        await release()
        let newPool = MCPServerPool(servers: enabled)
        await newPool.connectAll()
        let schemas = await newPool.toolSchemas()
        let errs = await newPool.errors()
        if !errs.isEmpty {
            Diagnostics.warn(
                "MCP connect errors: \(errs.map { "\($0.key): \($0.value)" }.joined(separator: "; "))")
        }
        self.pool = newPool
        self.fingerprint = fp
        self.lastSchemas = schemas
        return (newPool, schemas)
    }

    /// Disconnect and clear the cached pool (app quit / settings change).
    public func release() async {
        if let pool {
            await pool.disconnectAll()
        }
        pool = nil
        fingerprint = ""
        lastSchemas = []
    }

    /// Force reconnect next acquire (e.g. user edited MCP settings).
    public func invalidate() async {
        await release()
    }
}
