//
//  AgentDefinitionAllowlistTests.swift
//
//  Phase B PB5 — agent frontmatter tool allowlist + runner scrub.
//

import XCTest
@testable import AgentCore

final class AgentDefinitionAllowlistTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
    }

    // MARK: - Frontmatter parse

    func testParseToolsCommaList() {
        let md = """
        ---
        name: code-reviewer
        description: Reviews carefully
        tools: read_file, grep_code
        ---
        You review code.
        """
        let def = AgentDefinitionDiscovery.parse(markdown: md)
        XCTAssertEqual(def?.name, "code-reviewer")
        XCTAssertEqual(def?.tools, ["read_file", "grep_code"])
    }

    func testParseAllowedToolsAlias() {
        let md = """
        ---
        name: gated
        description: d
        allowed-tools: read_file, "grep_code", edit_file
        ---
        Body prompt.
        """
        let def = AgentDefinitionDiscovery.parse(markdown: md)
        XCTAssertEqual(def?.name, "gated")
        XCTAssertEqual(def?.tools, ["read_file", "grep_code", "edit_file"])
    }

    func testParseAllowedToolsUnderscoreAndBrackets() {
        let md = """
        ---
        name: bracket
        description: d
        allowed_tools: [run_shell, git_diff]
        ---
        Shell scout.
        """
        let def = AgentDefinitionDiscovery.parse(markdown: md)
        XCTAssertEqual(def?.tools, ["run_shell", "git_diff"])
    }

    func testParseToolsYamlBlockList() {
        let md = """
        ---
        name: blocky
        description: list form
        tools:
          - read_file
          - list_directory
        ---
        Explore only.
        """
        let def = AgentDefinitionDiscovery.parse(markdown: md)
        XCTAssertEqual(def?.name, "blocky")
        XCTAssertEqual(def?.tools, ["read_file", "list_directory"])
    }

    func testParseToolsKeyPreferredOverAllowedTools() {
        let md = """
        ---
        name: prefer
        description: d
        tools: read_file
        allowed-tools: write_file, edit_file
        ---
        Prefer tools key.
        """
        let def = AgentDefinitionDiscovery.parse(markdown: md)
        XCTAssertEqual(def?.tools, ["read_file"])
    }

    func testDiscoverByNameFromProjectAgentsDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb5-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(".vibecoder/agents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = """
        ---
        name: scout
        description: ro
        tools: read_file, not_a_real_tool
        ---
        Scout the tree.
        """
        try md.write(to: dir.appendingPathComponent("scout.md"), atomically: true, encoding: .utf8)
        let def = AgentDefinitionDiscovery.byName("scout", projectRoot: root)
        XCTAssertEqual(def?.name, "scout")
        XCTAssertEqual(def?.tools, ["read_file", "not_a_real_tool"])
    }

    // MARK: - Allowlist resolve / scrub

    func testScrubDropsUnknownAndTask() {
        let known: Set<String> = ["read_file", "grep_code", "write_file", "task"]
        let out = AgentToolAllowlist.scrub(
            declared: ["read_file", "not_real", "task", "grep_code"],
            known: known)
        XCTAssertEqual(out, ["read_file", "grep_code"])
        XCTAssertFalse(out.contains("task"))
        XCTAssertFalse(out.contains("not_real"))
    }

    func testScrubReportSurfacesUnknownAndBanned() {
        let known: Set<String> = ["read_file", "grep_code", "task"]
        let report = AgentToolAllowlist.scrubReport(
            declared: ["read_file", "not_real", "task", "also_fake"],
            known: known)
        XCTAssertEqual(report.allowed, ["read_file"])
        XCTAssertEqual(report.strippedBanned, ["task"])
        XCTAssertEqual(Set(report.strippedUnknown), Set(["not_real", "also_fake"]))
        XCTAssertTrue(report.didStrip)
        XCTAssertTrue(report.diagnosticMessage.contains("unknown:"))
        XCTAssertTrue(report.diagnosticMessage.contains("banned:"))
    }

    func testApplyReportPreservesStripDiagnostics() {
        let known: Set<String> = ["read_file", "list_directory"]
        let report = AgentToolAllowlist.applyReport(
            requested: ["read_file", "ghost_tool", "task"],
            known: known,
            fallback: SubagentCatalog.readOnlyTools)
        XCTAssertTrue(report.allowed.contains("read_file"))
        XCTAssertTrue(report.strippedUnknown.contains("ghost_tool"))
        XCTAssertTrue(report.strippedBanned.contains("task"))
        // Logging is best-effort; ensure it does not crash when stripping.
        AgentToolAllowlist.logStripDiagnostics(report, context: "unit-test")
    }

    func testScrubReportNoStripIsQuiet() {
        let known: Set<String> = ["read_file", "grep_code"]
        let report = AgentToolAllowlist.scrubReport(
            declared: ["read_file"],
            known: known)
        XCTAssertFalse(report.didStrip)
        XCTAssertEqual(report.diagnosticMessage, "no tools stripped")
    }

    func testResolveCustomEmptyFailsClosedToReadOnly() {
        let known = SubagentCatalog.readOnlyTools.union(SubagentCatalog.writeTools)
        let out = AgentToolAllowlist.resolveCustom(
            declaredTools: [],
            known: known,
            capability: nil)
        XCTAssertTrue(out.contains("read_file"))
        XCTAssertFalse(out.contains("write_file"))
        XCTAssertFalse(out.contains("run_shell"))
        XCTAssertFalse(out.contains("task"))
    }

    func testResolveCustomStripsUnknownKeepsKnown() {
        let known: Set<String> = ["read_file", "grep_code", "write_file"]
        let out = AgentToolAllowlist.resolveCustom(
            declaredTools: ["read_file", "bogus_tool", "write_file"],
            known: known)
        XCTAssertEqual(out, ["read_file", "write_file"])
    }

    func testResolveCustomIntersectsCapabilityMode() {
        let known = SubagentCatalog.readOnlyTools.union(SubagentCatalog.writeTools)
        let out = AgentToolAllowlist.resolveCustom(
            declaredTools: ["read_file", "write_file", "edit_file"],
            known: known,
            capability: .readOnly)
        XCTAssertTrue(out.contains("read_file"))
        XCTAssertFalse(out.contains("write_file"))
        XCTAssertFalse(out.contains("edit_file"))
    }

    func testDiscoveredDefinitionResolvedToolAllowlist() {
        let def = DiscoveredAgentDefinition(
            name: "x",
            description: "",
            systemPrompt: "hi",
            tools: ["read_file", "nope", "task"])
        let known: Set<String> = ["read_file", "list_directory"]
        let allowed = def.resolvedToolAllowlist(known: known)
        XCTAssertEqual(allowed, ["read_file"])
    }

    // MARK: - SubAgentRunner intersection

    func testSubAgentRunnerScrubsUnknownToolsFromSchemas() async {
        await ToolRegistry.shared.registerBuiltins()
        let known = await ToolRegistry.shared.registeredNames()
        XCTAssertTrue(known.contains("read_file"))

        // Apply the same path SubAgentRunner uses.
        let allowed = AgentToolAllowlist.apply(
            requested: ["read_file", "totally_fake_tool", "task"],
            known: known,
            fallback: SubAgentRunner.safeDefault)
        XCTAssertTrue(allowed.contains("read_file"))
        XCTAssertFalse(allowed.contains("totally_fake_tool"))
        XCTAssertFalse(allowed.contains("task"))

        let schemas = await ToolRegistry.shared.schemas(activeNames: allowed, includeDeferred: true)
        let names = Set(schemas.map(\.name))
        XCTAssertEqual(names, allowed)
        XCTAssertFalse(names.contains("totally_fake_tool"))
    }

    func testBuiltinExplorePresetUnchangedByAllowlistHelpers() {
        // Document honesty: explore/plan/GP still use SubagentType.allowedTools.
        let explore = SubagentType.explore.allowedTools(capability: nil)
        XCTAssertEqual(explore, SubagentCatalog.exploreTools.subtracting(["task"]))
        XCTAssertTrue(explore.isSubset(of: SubagentCatalog.readOnlyTools.union(SubagentCatalog.exploreTools)))
        // AgentToolAllowlist is for custom defs; scrubbing explore against
        // known builtins must not invent write tools.
        let scrubbed = AgentToolAllowlist.apply(
            requested: explore,
            known: SubagentCatalog.allToolsExceptTask.union(explore),
            fallback: SubAgentRunner.safeDefault)
        XCTAssertEqual(scrubbed, explore)
        XCTAssertFalse(scrubbed.contains("write_file"))
    }

    func testApplyEmptyRequestedFallsBackToSafeDefault() {
        let known = SubagentCatalog.readOnlyTools
        let out = AgentToolAllowlist.apply(
            requested: ["ghost_tool"],
            known: known,
            fallback: SubAgentRunner.safeDefault)
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.isSubset(of: known))
        XCTAssertFalse(out.contains("ghost_tool"))
    }
}
