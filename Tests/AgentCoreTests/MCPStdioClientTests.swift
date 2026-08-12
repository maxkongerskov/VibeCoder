import XCTest
@testable import AgentCore

final class MCPStdioClientTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    func testParseSuccessResponse() {
        let line = #"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#
        guard case .success(let id, let payload)? = MCPJSONRPCParser.parse(line: line) else {
            return XCTFail("Expected success parse")
        }
        XCTAssertEqual(id, 1)
        XCTAssertNotNil(payload["tools"])
    }

    func testParseServerErrorResponse() {
        let line = #"{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"bad"}}"#
        guard case .failure(let id, let error)? = MCPJSONRPCParser.parse(line: line) else {
            return XCTFail("Expected failure parse")
        }
        XCTAssertEqual(id, 2)
        if case .serverError(let code, let message) = error {
            XCTAssertEqual(code, -32600)
            XCTAssertEqual(message, "bad")
        } else {
            XCTFail("Expected serverError")
        }
    }

    func testRequestThrowsWhenNotConnected() async {
        let client = MCPStdioClient()
        do {
            _ = try await client.request(method: "tools/list", params: [:])
            XCTFail("Expected notConnected")
        } catch {
            guard let mcpError = error as? MCPClientError else {
                return XCTFail("Expected MCPClientError, got \(error)")
            }
            XCTAssertEqual(mcpError.errorDescription, MCPClientError.notConnected.errorDescription)
        }
    }

    func testParseMultiLineChunkBufferedResponse() {
        let line1 = #"{"jsonrpc":"2.0","id":3,"result":{"partial":true}}"#
        let line2 = #"{"jsonrpc":"2.0","id":4,"result":{"tools":[{"name":"BuildProject"}]}}"#
        guard case .success(let id3, _)? = MCPJSONRPCParser.parse(line: line1) else {
            return XCTFail("Expected first line parse")
        }
        guard case .success(let id4, let payload)? = MCPJSONRPCParser.parse(line: line2) else {
            return XCTFail("Expected second line parse")
        }
        XCTAssertEqual(id3, 3)
        XCTAssertEqual(id4, 4)
        XCTAssertNotNil(payload["tools"])
    }

    func testConnectHandshakeWithMockBridge() async throws {
        let script = fixtureURL("mock_mcp_bridge.py")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw XCTSkip("mock_mcp_bridge.py not executable")
        }

        let client = MCPStdioClient()
        try await client.connect(executable: script)

        let result = try await client.request(method: "tools/list", params: [:]).value
        XCTAssertNotNil(result["tools"])
        let connected = await client.isConnected
        XCTAssertTrue(connected)
        await client.disconnect()
    }

    func testRequestTimesOutWhenBridgeIsSilent() async throws {
        let script = fixtureURL("silent_mcp_bridge.py")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw XCTSkip("silent_mcp_bridge.py not executable")
        }

        let client = MCPStdioClient()
        try await client.connect(executable: script)

        do {
            _ = try await client.request(method: "tools/list", params: [:], timeout: 0.2)
            XCTFail("Expected timeout")
        } catch {
            guard let mcpError = error as? MCPClientError else {
                return XCTFail("Expected MCPClientError, got \(error)")
            }
            if case .timeout(let method) = mcpError {
                XCTAssertEqual(method, "tools/list")
            } else {
                XCTFail("Expected timeout, got \(mcpError)")
            }
        }
        await client.disconnect()
    }
}