//
//  AuditFixRegressionTests.swift
//
//  Regression tests for the confirmed audit fixes (safety, tool_search
//  unlock, git secrets, stall signatures, job ownership).
//

import XCTest
@testable import AgentCore

final class AuditFixRegressionTests: XCTestCase {

    // MARK: - Canonical tool signatures

    func testCanonicalJSONArgumentsSortsKeys() {
        let a = ChatLoop.canonicalJSONArguments(#"{"b":1,"a":2}"#)
        let b = ChatLoop.canonicalJSONArguments(#"{"a":2,"b":1}"#)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.contains("\"a\"") && a.contains("\"b\""))
    }

    func testTurnToolSignatureIgnoresKeyOrder() {
        let msg = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                ToolCallInvocation(id: "1", name: "read_file", arguments: #"{"path":"A","offset":1}"#),
                ToolCallInvocation(id: "2", name: "read_file", arguments: #"{"offset":1,"path":"A"}"#),
            ])
        // Two calls with same args different key order → same signature components
        let sig = ChatLoop.turnToolSignature(messages: [msg])
        XCTAssertNotNil(sig)
        // Signature is sorted join of both; both should canonicalize identically
        let parts = sig!.components(separatedBy: " + ")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], parts[1])
    }

    func testGovernorSnapshotCanonicalizesArgs() {
        let a = ToolCallSnapshot(tool: "edit_file", arguments: #"{"path":"x","old":"a"}"#)
        let b = ToolCallSnapshot(tool: "edit_file", arguments: #"{"old":"a","path":"x"}"#)
        XCTAssertEqual(a.arguments, b.arguments)
        let signal = Governor.checkIdenticalRepetition(
            [a, a, a, a, a, b], threshold: 6)
        XCTAssertNotNil(signal)
    }

    // MARK: - tool_search unlock extras

    func testToolSearchMarksDeferredUnlocks() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let tool = ToolSearchTool()
        let ctx = ToolContext(
            projectRoot: FileManager.default.temporaryDirectory,
            conversationID: UUID())
        let result = try await tool.execute(
            arguments: ToolArguments(dictionary: ["query": "plan"]),
            context: ctx)
        XCTAssertFalse(result.isError)
        // revise_plan is deferred and should match "plan"
        if result.content.lowercased().contains("revise_plan") {
            let unlocked = result.extras["unlocked_deferred"] ?? ""
            XCTAssertTrue(
                unlocked.contains("revise_plan"),
                "expected revise_plan in unlock extras, got \(unlocked)")
        }
    }

    // MARK: - Git secret refuse

    func testSecretPathsInPorcelainDetectsEnv() {
        let porcelain = """
        M  README.md
         M .env
        ?? secrets/id_rsa
        """
        let hits = GitWorkflow.secretPathsInPorcelain(porcelain)
        XCTAssertTrue(hits.contains { $0.contains(".env") })
        XCTAssertTrue(hits.contains { $0.contains("id_rsa") })
    }

    func testSecretPathsIgnoresNormalSources() {
        let porcelain = """
        M  Sources/App.swift
        A  Tests/FooTests.swift
        """
        XCTAssertTrue(GitWorkflow.secretPathsInPorcelain(porcelain).isEmpty)
    }

    // MARK: - Parallel-safe RO

    func testPlanToolsNotParallelSafe() async {
        await ToolRegistry.shared.registerBuiltins()
        let createRO = await ToolRegistry.shared.isReadOnlyTool("create_plan")
        let createParallel = await ToolRegistry.shared.isParallelSafeReadOnlyTool("create_plan")
        let searchParallel = await ToolRegistry.shared.isParallelSafeReadOnlyTool("tool_search")
        let readParallel = await ToolRegistry.shared.isParallelSafeReadOnlyTool("read_file")
        XCTAssertTrue(createRO)
        XCTAssertFalse(createParallel)
        XCTAssertFalse(searchParallel)
        XCTAssertTrue(readParallel)
    }

    // MARK: - Turn metrics cap

    func testHitIterationCapUsesConfiguredMax() {
        let m = TurnMetrics(
            duration: 1, iterations: 10, toolCalls: 0, compactions: 0, maxIterations: 10)
        XCTAssertTrue(m.hitIterationCap)
        let m2 = TurnMetrics(
            duration: 1, iterations: 10, toolCalls: 0, compactions: 0, maxIterations: 30)
        XCTAssertFalse(m2.hitIterationCap)
    }

    // MARK: - Checkpoint tools include memory / pbxproj editor

    func testCheckpointSnapshotToolNamesIncludeSoftMutators() {
        XCTAssertTrue(CheckpointStore.snapshotToolNames.contains("memory"))
        XCTAssertTrue(CheckpointStore.snapshotToolNames.contains("xcode_project_editor"))
    }
}
