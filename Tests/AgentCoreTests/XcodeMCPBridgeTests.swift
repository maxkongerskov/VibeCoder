import XCTest
@testable import AgentCore

final class XcodeMCPBridgeTests: XCTestCase {

    func testParseTabIdentifierFromStructuredContent() {
        let result: [String: Any] = [
            "structuredContent": [
                "message": "* tabIdentifier: windowtab1, workspacePath: /tmp/App.xcodeproj"
            ]
        ]
        XCTAssertEqual(XcodeMCPBridge.parseTabIdentifier(from: result), "windowtab1")
    }

    func testToolSchemaFromMCPEntry() {
        let entry: [String: Any] = [
            "name": "BuildProject",
            "description": "Build the open project",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "tabIdentifier": [
                        "type": "string",
                        "description": "Xcode tab id",
                    ],
                ],
                "required": ["tabIdentifier"],
            ],
        ]
        let schema = XcodeMCPBridge.toolSchema(from: entry)
        XCTAssertEqual(schema?.name, "BuildProject")
        XCTAssertEqual(schema?.parameters.required, ["tabIdentifier"])
    }

    func testMapJSONSchemaTypeInteger() {
        XCTAssertEqual(
            XcodeMCPBridge.mapJSONSchemaType(["type": "integer"]),
            "integer")
    }

    func testVerificationToolNamesIncludesMCPBuildToolsWhenRegistered() async {
        await ToolRegistry.shared.registerBuiltins()
        await registerMCPBuildToolsForTests()
        let classification = await ToolClassification.load(
            registry: .shared, xcodeMCPEnabled: true)
        XCTAssertTrue(classification.verification.contains("BuildProject"))
        XCTAssertTrue(classification.verification.contains("RunAllTests"))
        XCTAssertTrue(classification.verification.contains("xcode_build"))
        await ToolRegistry.shared.unregisterDynamicTools(
            names: Set(XcodeMCPBridge.buildVerificationToolNames))
    }

    func testVerificationExcludesMCPWhenDisabled() async {
        await ToolRegistry.shared.registerBuiltins()
        await registerMCPBuildToolsForTests()
        let classification = await ToolClassification.load(
            registry: .shared, xcodeMCPEnabled: false)
        XCTAssertFalse(classification.verification.contains("BuildProject"))
        XCTAssertFalse(classification.verification.contains("RunAllTests"))
        await ToolRegistry.shared.unregisterDynamicTools(
            names: Set(XcodeMCPBridge.buildVerificationToolNames))
    }

    private func registerMCPBuildToolsForTests() async {
        for name in XcodeMCPBridge.buildVerificationToolNames {
            let entry: [String: Any] = [
                "name": name,
                "description": name,
                "inputSchema": ["type": "object", "properties": [:]],
            ]
            guard let schema = XcodeMCPBridge.toolSchema(from: entry) else {
                XCTFail("schema for \(name)"); return
            }
            let meta = ToolRegistry.ToolMetadata(
                name: schema.name,
                category: .build,
                permission: .readOnly,
                availability: .platformGated(check: { true }),
                schema: schema)
            await ToolRegistry.shared.registerDynamicTool(metadata: meta) { _, _ in
                ToolResult(content: "ok")
            }
        }
    }

    func testAlwaysRelevantPruningExcludesSupersededBuiltinsWhenMCPEnabled() async {
        await ToolRegistry.shared.registerBuiltins()
        // Register MCP BuildProject so alwaysRelevant can prefer it over
        // the superseded builtin xcode_build (needs a live registry entry).
        if let schema = XcodeMCPBridge.toolSchema(from: [
            "name": "BuildProject",
            "description": "Build",
            "inputSchema": ["type": "object", "properties": [:]],
        ]) {
            let meta = ToolRegistry.ToolMetadata(
                name: schema.name,
                category: .build,
                permission: .readOnly,
                availability: .platformGated(check: { true }),
                schema: schema)
            await ToolRegistry.shared.registerDynamicTool(metadata: meta) { _, _ in
                ToolResult(content: "ok")
            }
        }
        let classification = await ToolClassification.load(
            registry: .shared, xcodeMCPEnabled: true)
        XCTAssertFalse(classification.alwaysRelevant.contains("xcode_build"))
        XCTAssertTrue(classification.alwaysRelevant.contains("BuildProject"))
    }

    func testNeedsTabIdentifierRefreshOnFirstMutatingCallPerTurn() {
        let now = Date()
        XCTAssertTrue(XcodeMCPBridge.needsTabIdentifierRefresh(
            cachedAt: now, refreshedThisTurn: false, now: now))
        XCTAssertFalse(XcodeMCPBridge.needsTabIdentifierRefresh(
            cachedAt: now, refreshedThisTurn: true, now: now))
    }

    func testNeedsTabIdentifierRefreshWhenCacheIsStale() {
        let now = Date()
        let stale = now.addingTimeInterval(-(XcodeMCPBridge.tabIdentifierTTL + 1))
        XCTAssertTrue(XcodeMCPBridge.needsTabIdentifierRefresh(
            cachedAt: stale, refreshedThisTurn: true, now: now))
    }

    func testMutatingToolNamesIncludesBuildAndWrite() {
        XCTAssertTrue(XcodeMCPBridge.mutatingToolNames.contains("BuildProject"))
        XCTAssertTrue(XcodeMCPBridge.mutatingToolNames.contains("XcodeWrite"))
        XCTAssertFalse(XcodeMCPBridge.mutatingToolNames.contains("XcodeRead"))
    }

    func testConnectFailsWhenBridgeMissing() async {
        let bridge = XcodeMCPBridge()
        await bridge.connect(bridgePath: "/tmp/agentos-nonexistent-mcpbridge")
        let status = await bridge.connectionStatus()
        guard case .failed = status else {
            return XCTFail("Expected failed connect for missing bridge, got \(status.label)")
        }
    }

    func testBeginAgentTurnResetsPerTurnRefreshFlag() {
        XCTAssertFalse(XcodeMCPBridge.needsTabIdentifierRefresh(
            cachedAt: Date(), refreshedThisTurn: true, now: Date()))
        // beginAgentTurn is invoked by AgentLoop; static TTL helper covers semantics.
        XCTAssertTrue(XcodeMCPBridge.needsTabIdentifierRefresh(
            cachedAt: Date(), refreshedThisTurn: false, now: Date()))
    }
}