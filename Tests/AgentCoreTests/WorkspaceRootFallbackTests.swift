//
//  WorkspaceRootFallbackTests.swift
//
//  P0.5: CWD `/` must never become a project-tier MCP walk or a durable
//  plan write target (Finder-launched Mac apps often have CWD `/`).
//

import XCTest
@testable import AgentCore

final class WorkspaceRootFallbackTests: XCTestCase {

    private let fsRoot = URL(fileURLWithPath: "/")

    func testUsableWorkspaceRootRejectsFilesystemRoot() {
        XCTAssertNil(PathConfinement.usableWorkspaceRoot(fsRoot))
        XCTAssertNil(PathConfinement.usableWorkspaceRoot(worktree: fsRoot, project: fsRoot))
        XCTAssertNil(PathConfinement.usableWorkspaceRoot(worktree: fsRoot, project: nil))
    }

    func testDiscoverProjectConfigsDoesNotWalkFilesystemRoot() {
        let found = MCPConfigWalker.discoverProjectConfigFiles(cwd: fsRoot)
        XCTAssertTrue(
            found.isEmpty,
            "must not walk /.mcp.json; got \(found.map(\.path))")
    }

    func testResolveMcpServersWithFilesystemRootSkipsProjectTier() {
        let fromRoot = MCPConfigWalker.resolveMcpServers(
            cwd: fsRoot, appSettingsServers: [])
        let fromNil = MCPConfigWalker.resolveMcpServers(
            cwd: nil, appSettingsServers: [])
        XCTAssertEqual(
            fromRoot.map(\.name),
            fromNil.map(\.name),
            "cwd `/` must not add project-tier servers beyond global + AppSettings")
        XCTAssertFalse(fromRoot.contains(where: { $0.name == "root-only" }))
    }

    func testResolveMcpServersNilCwdStillHonorsAppSettings() {
        let app = MCPServerConfig(
            name: "ui-only", transport: .stdio, command: "/usr/bin/true")
        let resolved = MCPConfigWalker.resolveMcpServers(
            cwd: nil, appSettingsServers: [app])
        XCTAssertTrue(resolved.contains(where: { $0.name == "ui-only" }))
    }

    func testToolContextDoesNotInventRootSessionPlan() {
        let convo = UUID()
        let ctx = ToolContext(projectRoot: nil, conversationID: convo)
        XCTAssertNil(ctx.sessionPlanFileURL)
        XCTAssertNil(ctx.usableWorkspaceRoot)
        if let plan = ctx.sessionPlanFileURL {
            XCTAssertFalse(
                plan.path.hasPrefix("/.agentos"),
                "unbound context must not default plan.md under /")
        }
        let invented = ToolAuthorization.sessionPlanURL(
            workingDirectory: fsRoot, conversationID: convo)
        XCTAssertFalse(ToolAuthorization.isSessionPlanPath(invented, context: ctx))
    }

    func testPlanStoreDoesNotWriteDurablePlanAtFilesystemRoot() async {
        let convo = UUID()
        let store = PlanStore()
        let plan = Plan.make(goal: "no root write", todoTexts: ["a"])
        await store.setPlan(plan, for: convo, workingDirectory: fsRoot)

        let file = PlanStore.durableFileURL(workingDirectory: fsRoot, conversation: convo)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "must not create \(file.path)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "/.agentos"),
            "must not create /.agentos")

        let memory = await store.plan(for: convo)
        XCTAssertEqual(memory?.goal, "no root write", "in-memory plan still stored")
    }

    func testCreatePlanToolDoesNotWriteAtFilesystemRoot() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let convo = UUID()
        let ctx = ToolContext(projectRoot: nil, conversationID: convo)
        let result = try await ToolRegistry.shared.execute(
            name: "create_plan",
            arguments: ToolArguments(dictionary: [
                "goal": "unbound",
                "todos": ["one"],
            ]),
            context: ctx)
        XCTAssertFalse(result.isError, result.content)
        let file = PlanStore.durableFileURL(workingDirectory: fsRoot, conversation: convo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/.agentos"))
        await PlanStore.shared.clear(for: convo, workingDirectory: nil)
    }
}
