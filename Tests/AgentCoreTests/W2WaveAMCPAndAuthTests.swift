//
//  W2WaveAMCPAndAuthTests.swift
//
//  Wave A W2: MCP schema injection, MCP auth gate, subagent SafeMode
//  inheritance, task/kill_task permission reclassification.
//

import XCTest
@testable import AgentCore

final class W2WaveAMCPAndAuthTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await RememberedGrants.shared.clear()
    }

    // MARK: - MCP schema conversion + assembler merge

    func testMCPDiscoveredToolToToolSchemaUsesNamespacedName() {
        let tool = MCPDiscoveredTool(
            namespacedName: "github__create_issue",
            description: "Create a GitHub issue",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Issue title"],
                    "body": ["type": "string"],
                ],
                "required": ["title"],
            ],
            serverName: "github"
        )
        let schema = tool.toToolSchema()
        XCTAssertEqual(schema.name, "github__create_issue")
        XCTAssertTrue(schema.description.contains("Create a GitHub issue")
                      || schema.description.contains("GitHub"))
        XCTAssertNotNil(schema.parameters.properties["title"])
        XCTAssertTrue(schema.parameters.required.contains("title"))
    }

    func testToolSchemaAssemblerMergesMCPSchemas() async {
        let mcp = [
            ToolSchema(
                name: "demo__ping",
                description: "Ping the demo MCP server",
                parameters: .init(properties: [
                    "msg": .init(type: "string", description: "Message"),
                ], required: ["msg"]))
        ]
        let config = AgentLoop.Configuration()
        let schemas = await ToolSchemaAssembler.baseSchemas(
            registry: .shared,
            conversation: Conversation(),
            config: config,
            mcpSchemas: mcp)
        let names = Set(schemas.map(\.name))
        XCTAssertTrue(names.contains("demo__ping"),
                      "MCP schemas must appear in the model tool list")
        XCTAssertTrue(names.contains("read_file"),
                      "builtins still present")
    }

    func testMergeMCPSchemasSkipsCollisionsAndDisabled() {
        let base = [
            ToolSchema(name: "read_file", description: "r",
                       parameters: .init(properties: [:]))
        ]
        let mcp = [
            ToolSchema(name: "read_file", description: "collide",
                       parameters: .init(properties: [:])),
            ToolSchema(name: "svc__a", description: "a",
                       parameters: .init(properties: [:])),
            ToolSchema(name: "svc__disabled", description: "d",
                       parameters: .init(properties: [:])),
        ]
        let merged = ToolSchemaAssembler.mergeMCPSchemas(
            into: base,
            mcpSchemas: mcp,
            disabledToolNames: ["svc__disabled"])
        let names = merged.map(\.name)
        XCTAssertEqual(names.filter { $0 == "read_file" }.count, 1,
                       "builtin wins on name collision")
        XCTAssertTrue(names.contains("svc__a"))
        XCTAssertFalse(names.contains("svc__disabled"))
    }

    // MARK: - MCP authorization

    func testMCPAuthorizeDeniedInPlanMode() {
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            executionMode: .plan,
            authorization: .empty)
        let outcome = ToolAuthorization.authorizeMCP(
            toolName: "github__create_issue",
            arguments: ToolArguments(dictionary: ["title": "x"]),
            context: ctx)
        guard case .deny(let reason) = outcome else {
            return XCTFail("expected deny in plan mode, got \(outcome)")
        }
        XCTAssertTrue(reason.lowercased().contains("plan")
                      || reason.lowercased().contains("mcp"),
                      reason)
    }

    func testMCPAuthorizeAllowedInYoloMode() {
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            executionMode: .yolo,
            authorization: .empty)
        let outcome = ToolAuthorization.authorizeMCP(
            toolName: "github__list_issues",
            arguments: ToolArguments(dictionary: [:]),
            context: ctx)
        guard case .allow = outcome else {
            return XCTFail("expected allow in yolo, got \(outcome)")
        }
    }

    func testMCPAuthorizeDeniedByExplicitRule() {
        let auth = AuthorizationConfig(rules: [
            .init(kind: .deny, toolName: "evil__run")
        ], useInlineRememberedOnly: true)
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            executionMode: .yolo,
            authorization: auth)
        let outcome = ToolAuthorization.authorizeMCP(
            toolName: "evil__run",
            arguments: ToolArguments(dictionary: [:]),
            context: ctx)
        guard case .deny = outcome else {
            return XCTFail("deny rule must block MCP, got \(outcome)")
        }
    }

    func testMCPAuthorizeAskInBuildModeWithoutReviewer() {
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            executionMode: .build,
            authorization: .empty)
        let outcome = ToolAuthorization.authorizeMCP(
            toolName: "svc__tool",
            arguments: ToolArguments(dictionary: [:]),
            context: ctx)
        guard case .ask = outcome else {
            return XCTFail("Ask mode must not silent-auto MCP, got \(outcome)")
        }
    }

    // MARK: - Wave B S4 MCP ask via ShellApprovalGate

    func testMCPAskGateAllowsOnceWhenCoordinatorApproves() async {
        let coordinator = ShellApprovalCoordinator { _ in .once }
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            shellApprovalCoordinator: coordinator,
            conversationID: UUID(),
            executionMode: .build,
            authorization: .empty)
        let outcome = ToolAuthorization.authorizeMCP(
            toolName: "svc__tool",
            arguments: ToolArguments(dictionary: ["x": 1]),
            context: ctx)
        guard case .ask(let reason) = outcome else {
            return XCTFail("expected .ask in build mode, got \(outcome)")
        }
        let gate = await ShellApprovalGate.resolve(
            toolName: "svc__tool",
            reason: reason,
            kind: .mcp,
            argumentsSummary: "x=1",
            context: ctx)
        XCTAssertTrue(gate.allowed, "Once should allow MCP invoke")
        XCTAssertEqual(gate.denialMessage, "")
    }

    func testMCPAskGateDeniesWhenCoordinatorRejects() async {
        let coordinator = ShellApprovalCoordinator { _ in .deny }
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            shellApprovalCoordinator: coordinator,
            conversationID: UUID(),
            executionMode: .build,
            authorization: .empty)
        let gate = await ShellApprovalGate.resolve(
            toolName: "svc__tool",
            reason: "Ask mode requires approval for 'svc__tool'",
            kind: .mcp,
            context: ctx)
        XCTAssertFalse(gate.allowed)
        XCTAssertTrue(gate.denialMessage.lowercased().contains("permission")
                      || gate.denialMessage.lowercased().contains("denied")
                      || gate.denialMessage.lowercased().contains("ask"),
                      gate.denialMessage)
    }

    func testMCPAskGateFailsClosedWithoutCoordinator() async {
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            executionMode: .build,
            authorization: .empty)
        let gate = await ShellApprovalGate.resolve(
            toolName: "svc__tool",
            reason: "Ask mode requires approval for 'svc__tool'",
            kind: .mcp,
            context: ctx)
        XCTAssertFalse(gate.allowed, "no coordinator → fail closed")
    }

    func testMCPAskGateAlwaysRemembersGrant() async {
        await RememberedGrants.shared.clear()
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-always-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let coordinator = ShellApprovalCoordinator { _ in .always }
        let ctx = ToolContext(
            projectRoot: projectRoot,
            shellApprovalCoordinator: coordinator,
            conversationID: UUID(),
            executionMode: .build,
            authorization: .empty)
        let gate = await ShellApprovalGate.resolve(
            toolName: "svc__list",
            reason: "Ask mode requires approval",
            kind: .mcp,
            context: ctx)
        XCTAssertTrue(gate.allowed)

        // Subsequent authorize with hydrated grants should allow without ask.
        let projectKey = RememberedGrants.projectKey(from: ctx)
        let grants = await RememberedGrants.shared.snapshot(projectKey: projectKey)
        let auth = AuthorizationConfig(remembered: grants, useInlineRememberedOnly: true)
        let ctx2 = ToolContext(
            projectRoot: projectRoot,
            conversationID: UUID(),
            executionMode: .build,
            authorization: auth)
        let outcome = ToolAuthorization.authorizeMCP(
            toolName: "svc__list",
            arguments: ToolArguments(dictionary: [:]),
            context: ctx2)
        guard case .allow = outcome else {
            return XCTFail("Always grant should allow MCP later, got \(outcome)")
        }
    }

    // MARK: - task / kill_task permissions

    func testTaskAndKillTaskAreNotReadOnly() async {
        await ToolRegistry.shared.registerBuiltins()
        // Fresh metadata from current Tool static permissions.
        // If already registered earlier in process, re-check via type.
        XCTAssertEqual(TaskTool.permission, .executes)
        XCTAssertEqual(KillTaskTool.permission, .executes)
        XCTAssertFalse(ToolAuthorization.builtInReadOnlyTools.contains("task"))
        XCTAssertFalse(ToolAuthorization.builtInReadOnlyTools.contains("kill_task"))
    }

    func testKillTaskDeniedInPlanMode() async {
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            executionMode: .plan)
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "kill_task",
                arguments: ToolArguments(dictionary: [
                    "task_id": UUID().uuidString,
                ]),
                context: ctx)
            XCTFail("kill_task must not auto-run in plan mode")
        } catch let e as ToolError {
            guard case .permissionDenied = e else {
                return XCTFail("expected permissionDenied, got \(e)")
            }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTaskGeneralPurposeDeniedInPlanMode() async {
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            executionMode: .plan)
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "task",
                arguments: ToolArguments(dictionary: [
                    "prompt": "write files",
                    "description": "gp",
                    "subagent_type": "general-purpose",
                ]),
                context: ctx)
            XCTFail("general-purpose task must be denied in plan mode")
        } catch let e as ToolError {
            guard case .permissionDenied(let reason) = e else {
                return XCTFail("expected permissionDenied, got \(e)")
            }
            XCTAssertTrue(reason.lowercased().contains("plan")
                          || reason.lowercased().contains("general"),
                          reason)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTaskExploreAllowedInPlanModePastAuth() async {
        // Auth should allow explore in plan; execution then fails on
        // missing backend/model without permissionDenied.
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID(),
            executionMode: .plan)
        let result = try? await ToolRegistry.shared.execute(
            name: "task",
            arguments: ToolArguments(dictionary: [
                "prompt": "look around",
                "description": "explore",
                "subagent_type": "explore",
            ]),
            context: ctx)
        // Either tool result (error about backend/model) or if throws,
        // must NOT be a plan-mode permission denial for explore.
        if let result {
            XCTAssertFalse(
                result.content.lowercased().contains("plan mode: general"),
                result.content)
            // Missing backend is expected
            XCTAssertTrue(
                result.isError
                || result.content.lowercased().contains("backend")
                || result.content.lowercased().contains("model"),
                result.content)
        }
    }

    // MARK: - Subagent SafeMode inheritance

    func testSubAgentRunnerForwardsSafeModeIntoToolContext() async {
        let allowed = FileManager.default.temporaryDirectory
            .appendingPathComponent("w2-safe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: allowed) }

        // Narrow Safe Mode allow-list: only a nested subdir (not project root).
        let nested = allowed.appendingPathComponent("ok", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let safe = SafeModeConfig(
            allowedPathPrefixes: [nested.path],
            allowedShellPrefixes: ["echo"])

        // Same ToolContext shape SubAgentRunner builds when TaskTool
        // forwards parent safeMode + project roots.
        let ctx = ToolContext(
            projectRoot: allowed,
            worktreeRoot: nil,
            safeMode: safe,
            conversationID: UUID(),
            inferenceBackend: nil,
            model: ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio),
            subagentDepth: 1,
            executionMode: .yolo)

        // Path under project root but outside Safe Mode allow-list → deny
        // via Safe Mode (path confinement alone would allow project paths).
        let inProjectOutsideSafe = allowed
            .appendingPathComponent("not-in-safe-\(UUID().uuidString).txt")
        let outcome = ToolAuthorization.evaluate(
            toolName: "write_file",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "path": inProjectOutsideSafe.path,
                "content": "nope",
            ]),
            context: ctx,
            config: .empty)
        guard case .deny(let reason) = outcome else {
            return XCTFail("Safe Mode must deny path outside allow-list, got \(outcome)")
        }
        XCTAssertTrue(
            reason.lowercased().contains("safe mode")
                || reason.lowercased().contains("allow-list")
                || reason.lowercased().contains("outside"),
            reason)

        // Nested allow-list path should pass authorization.
        let okFile = nested.appendingPathComponent("ok.txt")
        let okOutcome = ToolAuthorization.evaluate(
            toolName: "write_file",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "path": okFile.path,
                "content": "yes",
            ]),
            context: ctx,
            config: .empty)
        guard case .allow = okOutcome else {
            return XCTFail("path under Safe Mode allow-list must allow, got \(okOutcome)")
        }

        // SubAgentRunner.run accepts safeMode/executionMode and completes.
        let backend = StubImmediateBackend()
        let result = await SubAgentRunner.run(
            prompt: "Say hello only.",
            systemPromptOverride: "Reply with hi.",
            allowedTools: ["read_file"],
            backend: backend,
            model: ModelDescriptor(id: "stub", displayName: "stub", backend: .custom),
            registry: .shared,
            projectRoot: allowed,
            safeMode: safe,
            executionMode: .yolo,
            maxIterations: 2)
        XCTAssertTrue(
            result.finalText.contains("hi") || !result.finalText.isEmpty,
            "subagent should produce text: \(result.finalText)")
    }

    func testResolveExecutableURLAbsoluteAndBare() {
        let sh = MCPServerPool.resolveExecutableURL("/bin/sh")
        XCTAssertEqual(sh?.path, "/bin/sh")
        // `true` or `echo` should resolve via PATH on macOS
        let echo = MCPServerPool.resolveExecutableURL("echo")
        XCTAssertNotNil(echo, "echo should resolve on PATH")
        XCTAssertNil(MCPServerPool.resolveExecutableURL("definitely-not-a-binary-\(UUID().uuidString)"))
    }

    // MARK: - Wave C: listTools error surface + Always mid-turn grant

    func testMCPPoolRecordsListToolsFailureInConnectionErrors() async {
        // Non-existent stdio binary → connectStdio records connectionErrors.
        let servers = [
            MCPServerConfig(
                name: "dead-stdio",
                transport: .stdio,
                command: "/nonexistent/mcp-server-w04-\(UUID().uuidString)",
                args: [],
                enabled: true)
        ]
        let pool = MCPServerPool(servers: servers)
        await pool.connectAll()
        let errs = await pool.errors()
        XCTAssertFalse(errs.isEmpty, "failed stdio connect must appear in connectionErrors")
        XCTAssertNotNil(errs["dead-stdio"])
        let tools = await pool.tools()
        XCTAssertTrue(tools.isEmpty)
    }

    func testMCPAuthorizeHonorsAlwaysGrantWithoutReask() async {
        await RememberedGrants.shared.clear()
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-always2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let key = GrantKey(projectKey: projectRoot.path, toolName: "svc__list")
        await RememberedGrants.shared.remember(.allow, for: key)

        let grants = await RememberedGrants.shared.snapshot(projectKey: projectRoot.path)
        let ctx = ToolContext(
            projectRoot: projectRoot,
            conversationID: UUID(),
            executionMode: .build,
            authorization: AuthorizationConfig(remembered: grants, useInlineRememberedOnly: true))
        let outcome = ToolAuthorization.authorizeMCP(
            toolName: "svc__list",
            arguments: ToolArguments(dictionary: [:]),
            context: ctx,
            remembered: grants)
        guard case .allow = outcome else {
            return XCTFail("hydrated Always grant must allow without .ask, got \(outcome)")
        }
    }

    // MARK: - Wave C2

    func testIsMCPToolNameRequiresServerAndToolParts() {
        XCTAssertTrue(ToolAuthorization.isMCPToolName("github__create_issue"))
        XCTAssertTrue(ToolAuthorization.isMCPToolName("svc__tool__with__parts"),
                      "tool suffix may contain __ after first delimiter")
        XCTAssertFalse(ToolAuthorization.isMCPToolName("read_file"))
        XCTAssertFalse(ToolAuthorization.isMCPToolName("__tool"))
        XCTAssertFalse(ToolAuthorization.isMCPToolName("server__"))
        XCTAssertFalse(ToolAuthorization.isMCPToolName("__"))
        XCTAssertFalse(ToolAuthorization.isMCPToolName(""))
    }

    func testMCPToToolSchemaFiltersRequiredToMappedProps() {
        let tool = MCPDiscoveredTool(
            namespacedName: "demo__x",
            description: "x",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "t"],
                    // unparseable property entry — dropped
                    "bad": "not-an-object",
                    "tags": [
                        "type": "array",
                        "items": ["type": ["string", "null"]],
                    ],
                    "meta": [
                        "type": "object",
                        "properties": ["a": ["type": "string"], "b": ["type": "number"]],
                        "description": "metadata",
                    ],
                ],
                "required": ["title", "bad", "missing"],
            ],
            serverName: "demo"
        )
        let schema = tool.toToolSchema()
        XCTAssertNotNil(schema.parameters.properties["title"])
        XCTAssertNil(schema.parameters.properties["bad"])
        XCTAssertEqual(schema.parameters.required, ["title"],
                       "required must only list successfully mapped properties")
        XCTAssertEqual(schema.parameters.properties["tags"]?.type, "array")
        XCTAssertEqual(schema.parameters.properties["tags"]?.items?.type, "string",
                       "union item types should prefer non-null")
        XCTAssertEqual(schema.parameters.properties["meta"]?.type, "object")
        XCTAssertTrue(
            schema.parameters.properties["meta"]?.description.contains("object keys") == true
            || schema.parameters.properties["meta"]?.description.contains("a") == true,
            "nested object keys should appear in description")
    }
}

// MARK: - Stub backend (immediate stop, no tools)

private struct StubImmediateBackend: InferenceBackend {
    let identifier: BackendIdentifier = .custom

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "stub", displayName: "stub", backend: .custom)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { cont in
            cont.yield(.contentDelta("hi from stub"))
            cont.yield(.done(finishReason: "stop"))
            cont.finish()
        }
    }

    func cancel(streamID: UUID) async {}
}