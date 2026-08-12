//
//  MCPServerConfig.swift
//
//  Configuration types for MCP server connections, ported from Grok Build's
//  xai-grok-config-types/src/mcp.rs. Two transports are supported:
//
//    stdio          — local subprocess speaking JSON-RPC over stdin/stdout
//                     (VibeCoder's existing path; Apple's mcpbridge, etc.)
//
//    streamableHttp — remote HTTP server implementing the MCP Streamable
//                     HTTP transport (POST JSON-RPC, SSE responses). This
//                     is what most cloud MCP servers (GitHub, Slack,
//                     databases) use. Prior to this file VibeCoder could
//                     only talk to local stdio servers; now both paths are
//                     first-class.
//
//  The config shape mirrors z.code / Grok Build's TOML schema so users
//  coming from either tool can reuse their server definitions. We keep
//  it Codable for JSON persistence in AppSettings (VibeCoder's existing
//  settings store is JSON, not TOML).
//

import Foundation

/// How an MCP server is reached.
public enum MCPServerTransport: String, Codable, Sendable {
    /// Local subprocess speaking JSON-RPC over stdin/stdout.
    case stdio
    /// Remote HTTP server using the MCP Streamable HTTP transport.
    case streamableHttp
}

/// One user-configured MCP server definition. Stored in AppSettings and
/// surfaced to the agent loop at turn start so tools from all enabled
/// servers are registered alongside VibeCoder's builtins.
public struct MCPServerConfig: Codable, Sendable, Identifiable, Equatable {

    /// Stable identifier (the server name, e.g. "github"). Used as the
    /// tool-name namespace: tools are exposed as `"<server>__<tool>"`.
    public var id: String { name }

    /// Human-readable server name. Also the tool namespace prefix.
    public var name: String

    /// Which transport this server uses.
    public var transport: MCPServerTransport

    // ── stdio fields (only meaningful when transport == .stdio) ───────

    /// Executable path for stdio servers (e.g. `/usr/local/bin/mcpbridge`).
    public var command: String?
    /// Arguments passed to the stdio executable.
    public var args: [String]
    /// Environment overrides for the subprocess. Keys not present here
    /// are inherited from the parent process.
    public var env: [String: String]

    // ── streamableHttp fields (only meaningful when transport == .http) ─

    /// Base URL for the HTTP server (e.g. `https://mcp.github.com/sse`).
    /// All JSON-RPC requests are POSTed to this URL.
    public var url: String?
    /// Custom headers sent with every request (e.g. `Authorization`).
    public var headers: [String: String]
    /// Name of an env var holding a bearer token. When set, the client
    /// sends `Authorization: Bearer <$env_var_value>` on every request.
    /// (Matches Grok Build's `bearer_token_env_var` field.)
    public var bearerTokenEnvVar: String?

    // ── shared lifecycle fields ───────────────────────────────────────

    /// When false, the server is registered but not started. The user can
    /// toggle this in Settings → MCP without deleting the definition.
    public var enabled: Bool

    /// Seconds to wait for the initial `initialize` handshake before
    /// giving up. Defaults to 30 (matches Grok Build).
    public var startupTimeout: TimeInterval

    /// Per-request timeout for tool calls. Defaults to 120s.
    public var toolTimeout: TimeInterval

    /// Per-tool timeout overrides (seconds), keyed by tool name. When
    /// a tool is present here, its value wins over `toolTimeout`.
    /// Mirrors Grok Build's `[mcp_servers.X].tool_timeouts` field.
    /// Empty = all tools use `toolTimeout`.
    public var toolTimeouts: [String: TimeInterval]

    /// Optional OAuth configuration for this server. When present, the
    /// MCP HTTP client uses `MCPOAuthCoordinator` to obtain a bearer token
    /// via the Authorization Code + PKCE flow (see MCPOAuthCoordinator).
    ///
    /// Only meaningful for `streamableHttp` servers — stdio servers don't
    /// make HTTP requests and have no use for OAuth.
    public var oauth: MCPOAuthConfig?

    /// Resolve the timeout for a specific tool on this server.
    ///
    /// Precedence (matches Grok Build's `tool_timeout_for`):
    ///   1. `toolTimeouts[toolName]` (per-tool override)
    ///   2. `toolTimeout` (server-level scalar)
    public func toolTimeout(for toolName: String) -> TimeInterval {
        if let per = toolTimeouts[toolName] { return per }
        return toolTimeout
    }

    public init(name: String,
                transport: MCPServerTransport,
                command: String? = nil,
                args: [String] = [],
                env: [String: String] = [:],
                url: String? = nil,
                headers: [String: String] = [:],
                bearerTokenEnvVar: String? = nil,
                enabled: Bool = true,
                startupTimeout: TimeInterval = 30,
                toolTimeout: TimeInterval = 120,
                toolTimeouts: [String: TimeInterval] = [:],
                oauth: MCPOAuthConfig? = nil) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.bearerTokenEnvVar = bearerTokenEnvVar
        self.enabled = enabled
        self.startupTimeout = startupTimeout
        self.toolTimeout = toolTimeout
        self.toolTimeouts = toolTimeouts
        self.oauth = oauth
    }

    /// Convenience for a stdio server definition.
    public static func stdio(name: String,
                             command: String,
                             args: [String] = [],
                             env: [String: String] = [:]) -> MCPServerConfig {
        MCPServerConfig(name: name, transport: .stdio,
                        command: command, args: args, env: env)
    }

    /// Convenience for an HTTP server definition.
    public static func http(name: String,
                            url: String,
                            headers: [String: String] = [:],
                            bearerTokenEnvVar: String? = nil) -> MCPServerConfig {
        MCPServerConfig(name: name, transport: .streamableHttp,
                        url: url, headers: headers,
                        bearerTokenEnvVar: bearerTokenEnvVar)
    }

    // MARK: - Codable (custom decode for backward compat)

    enum CodingKeys: String, CodingKey {
        case name, transport, command, args, env, url, headers,
             bearerTokenEnvVar, enabled, startupTimeout, toolTimeout,
             toolTimeouts, oauth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.transport = try c.decode(MCPServerTransport.self, forKey: .transport)
        self.command = try c.decodeIfPresent(String.self, forKey: .command)
        self.args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        self.env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.bearerTokenEnvVar = try c.decodeIfPresent(String.self, forKey: .bearerTokenEnvVar)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.startupTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .startupTimeout) ?? 30
        self.toolTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .toolTimeout) ?? 120
        self.toolTimeouts = try c.decodeIfPresent([String: TimeInterval].self, forKey: .toolTimeouts) ?? [:]
        self.oauth = try c.decodeIfPresent(MCPOAuthConfig.self, forKey: .oauth)
    }
}

/// Validates an MCP tool name against the strictest cross-provider LLM
/// requirements (ported from Grok Build's `validate_tool_name`).
///
/// Pattern: `^[a-zA-Z_][a-zA-Z0-9_-]{0,63}$`
/// - Must start with a letter or underscore (Gemini requirement)
/// - Only letters, digits, underscores, hyphens allowed
/// - Maximum 64 characters
public enum MCPToolNaming {
    /// Tool name namespace delimiter: `server__tool`.
    public static let delimiter = "__"

    /// Validate a tool name matches cross-provider requirements.
    /// Returns `nil` on success, or an error message string on failure.
    public static func validate(_ name: String) -> String? {
        guard !name.isEmpty else {
            return "tool name cannot be empty"
        }
        let pattern = "^[a-zA-Z_][a-zA-Z0-9_-]{0,63}$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        else {
            return "tool name '\(name)' is invalid — must match \(pattern) (start with letter/underscore, max 64 chars)"
        }
        return nil
    }

    /// Build a namespaced tool name: `server__tool`.
    public static func namespaced(server: String, tool: String) -> String {
        "\(server)\(delimiter)\(tool)"
    }
}