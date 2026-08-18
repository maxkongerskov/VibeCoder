//
//  MCPConfigWalkerTests.swift
//
//  Tests for the two-axis config resolution (MCPConfigWalker), per-tool
//  timeout resolution (MCPServerConfig.toolTimeout(for:)), and the .mcp.json
//  entry → MCPServerConfig conversion (entryToConfig).
//
//  These verify the Grok Build patterns we ported:
//    - Project-local .mcp.json replaces same-named servers entirely (no field merge)
//    - The walk is cwd → git root, with nearer files winning
//    - Home-is-dotfiles guard: if git root == $HOME, treat as no-repo
//    - Per-tool timeout map wins over server-level scalar
//    - Global user config (~/.vibecoder/mcp.json) is the base layer
//    - AppSettings servers use fill-if-missing semantics
//

import XCTest
@testable import AgentCore

final class MCPConfigWalkerTests: XCTestCase {

    // MARK: - Timeout resolution (MCPServerConfig.toolTimeout)

    func testPerToolTimeoutOverridesScalar() {
        let config = MCPServerConfig(
            name: "test", transport: .streamableHttp,
            url: "https://example.com",
            toolTimeout: 120,
            toolTimeouts: ["slow_tool": 600, "fast_tool": 5])
        XCTAssertEqual(config.toolTimeout(for: "slow_tool"), 600)
        XCTAssertEqual(config.toolTimeout(for: "fast_tool"), 5)
        // Unspecified tools fall back to the scalar.
        XCTAssertEqual(config.toolTimeout(for: "other_tool"), 120)
    }

    func testNoPerToolMapUsesScalar() {
        let config = MCPServerConfig(
            name: "test", transport: .streamableHttp,
            url: "https://example.com",
            toolTimeout: 90)
        XCTAssertEqual(config.toolTimeout(for: "any_tool"), 90)
    }

    // MARK: - entryToConfig

    func testEntryToConfigHTTP() {
        let entry = MCPFileServerEntry(
            type: "http", url: "https://mcp.example.com/sse",
            headers: ["Authorization": "Bearer token"],
            enabled: true, startupTimeout: 45, toolTimeout: 300,
            toolTimeouts: ["heavy": 600])
        let config = MCPConfigWalker.entryToConfig(name: "test-server", entry: entry)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.transport, .streamableHttp)
        XCTAssertEqual(config?.url, "https://mcp.example.com/sse")
        XCTAssertEqual(config?.headers["Authorization"], "Bearer token")
        XCTAssertEqual(config?.startupTimeout, 45)
        XCTAssertEqual(config?.toolTimeout, 300)
        XCTAssertEqual(config?.toolTimeouts["heavy"], 600)
    }

    /// `.mcp.json` `type: "sse"` is the legacy GET /sse transport, not Streamable HTTP.
    func testEntryToConfigSSEUsesSSETransport() {
        let lower = MCPFileServerEntry(
            type: "sse", url: "https://legacy.example.com/sse")
        let lowerConfig = MCPConfigWalker.entryToConfig(name: "legacy-sse", entry: lower)
        XCTAssertNotNil(lowerConfig)
        XCTAssertEqual(lowerConfig?.transport, .sse)
        XCTAssertNotEqual(lowerConfig?.transport, .streamableHttp)
        XCTAssertEqual(lowerConfig?.url, "https://legacy.example.com/sse")

        let upper = MCPFileServerEntry(
            type: "SSE", url: "https://legacy.example.com/events")
        let upperConfig = MCPConfigWalker.entryToConfig(name: "legacy-SSE", entry: upper)
        XCTAssertEqual(upperConfig?.transport, .sse)

        let missingURL = MCPFileServerEntry(type: "sse")
        XCTAssertNil(MCPConfigWalker.entryToConfig(name: "no-url", entry: missingURL))
    }

    func testEntryToConfigStdio() {
        let entry = MCPFileServerEntry(
            type: "stdio", command: "/usr/local/bin/mcp-server",
            args: ["--port", "3000"],
            env: ["API_KEY": "secret"])
        let config = MCPConfigWalker.entryToConfig(name: "local", entry: entry)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.transport, .stdio)
        XCTAssertEqual(config?.command, "/usr/local/bin/mcp-server")
        XCTAssertEqual(config?.args, ["--port", "3000"])
        XCTAssertEqual(config?.env["API_KEY"], "secret")
    }

    func testEntryToConfigInvalidName() {
        let entry = MCPFileServerEntry(type: "http", url: "https://x.com")
        // Name with invalid characters should be rejected.
        let config = MCPConfigWalker.entryToConfig(name: "invalid name!", entry: entry)
        XCTAssertNil(config)
    }

    func testEntryToConfigMissingRequiredFields() {
        // HTTP without URL.
        let badHTTP = MCPFileServerEntry(type: "http")
        XCTAssertNil(MCPConfigWalker.entryToConfig(name: "bad", entry: badHTTP))

        // Stdio without command.
        let badStdio = MCPFileServerEntry(type: "stdio")
        XCTAssertNil(MCPConfigWalker.entryToConfig(name: "bad2", entry: badStdio))
    }

    // MARK: - Config file loading (JSON parsing)

    func testLoadConfigFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configFile = tempDir.appendingPathComponent(".mcp.json")
        let json = """
        {
          "mcpServers": {
            "github": {
              "type": "http",
              "url": "https://mcp.github.com/sse",
              "toolTimeout": 600
            },
            "local-helper": {
              "type": "stdio",
              "command": "/usr/local/bin/helper"
            }
          }
        }
        """
        try json.write(to: configFile, atomically: true,
                       encoding: .utf8)

        let loaded = MCPConfigWalker.loadConfigFile(at: configFile)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.mcpServers.count, 2)
        XCTAssertNotNil(loaded?.mcpServers["github"])
        XCTAssertEqual(loaded?.mcpServers["github"]?.url,
                       "https://mcp.github.com/sse")
    }

    func testLoadConfigFileMalformed() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir,
                                                   withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let badFile = tempDir.appendingPathComponent(".mcp.json")
        try? "{ not valid json }".write(to: badFile, atomically: true,
                                           encoding: .utf8)
        // Should return nil, not crash.
        XCTAssertNil(MCPConfigWalker.loadConfigFile(at: badFile))
    }

    // MARK: - discoverGitRoot

    func testDiscoverGitRootFindsParent() throws {
        // Create a temp git repo with a nested directory.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("subdir/nested"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("subdir/nested")
        let foundRoot = MCPConfigWalker.discoverGitRoot(from: nested)
        XCTAssertNotNil(foundRoot)
        XCTAssertEqual(foundRoot?.standardizedFileURL.path,
                       root.standardizedFileURL.path)
    }

    func testDiscoverGitRootNoRepo() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // No .git anywhere — should return nil.
        XCTAssertNil(MCPConfigWalker.discoverGitRoot(from: tempDir))
    }

    // MARK: - resolveMcpServers (full merge)

    func testResolveMcpServersProjectOverridesGlobal() throws {
        // Create a temp directory structure:
        //   root/.git
        //   root/.mcp.json (defines "github" with 600s timeout)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectConfig = """
        {
          "mcpServers": {
            "github": {
              "type": "http",
              "url": "https://project.mcp.github.com/sse",
              "toolTimeout": 600
            }
          }
        }
        """
        try projectConfig.write(
            to: root.appendingPathComponent(".mcp.json"),
            atomically: true, encoding: .utf8)

        // AppSettings has a different "github" server (should be
        // overridden by the project .mcp.json).
        let appSettingsServer = MCPServerConfig(
            name: "github", transport: .streamableHttp,
            url: "https://appsettings.mcp.github.com/sse",
            toolTimeout: 120)

        let resolved = MCPConfigWalker.resolveMcpServers(
            cwd: root,
            appSettingsServers: [appSettingsServer])

        // Project .mcp.json should win — URL matches the project config.
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.url,
                       "https://project.mcp.github.com/sse")
        XCTAssertEqual(resolved.first?.toolTimeout, 600)
    }

    func testResolveMcpServersFillIfMissing() throws {
        // When AppSettings has a server NOT in any .mcp.json file,
        // it should be included (fill-if-missing semantics).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // No .mcp.json file — just AppSettings servers.
        let appServer = MCPServerConfig(
            name: "my-custom", transport: .streamableHttp,
            url: "https://custom.example.com")
        let resolved = MCPConfigWalker.resolveMcpServers(
            cwd: root,
            appSettingsServers: [appServer])

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.name, "my-custom")
    }

    func testResolveMcpServersNoGitRoot() throws {
        // When cwd is not in a git repo, only AppSettings servers
        // are used (no project walk).
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let server = MCPServerConfig(
            name: "standalone", transport: .stdio,
            command: "/usr/local/bin/mcp")
        let resolved = MCPConfigWalker.resolveMcpServers(
            cwd: tempDir,
            appSettingsServers: [server])

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.name, "standalone")
    }

    // MARK: - Backward compat (MCPServerConfig decode without toolTimeouts)

    func testDecodeOldConfigWithoutToolTimeouts() throws {
        // Simulate an old AppSettings JSON that doesn't have the
        // toolTimeouts field (backward compat).
        let oldJSON = """
        {
          "name": "legacy",
          "transport": "streamableHttp",
          "url": "https://legacy.example.com"
        }
        """
        let data = oldJSON.data(using: .utf8)!
        let config = try JSONDecoder().decode(MCPServerConfig.self, from: data)

        XCTAssertEqual(config.name, "legacy")
        XCTAssertEqual(config.toolTimeouts, [:]) // default empty
        XCTAssertEqual(config.toolTimeout, 120)  // default scalar
    }
}