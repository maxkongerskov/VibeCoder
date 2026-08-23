//
//  MCPSSEClientTests.swift
//
//  Legacy MCP HTTP+SSE transport: GET /sse, endpoint event, POST /message.
//

import XCTest
@testable import AgentCore

final class MCPSSEClientTests: XCTestCase {

    private var scratch: URL!
    private var childProcesses: [Process] = []

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPSSE-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for proc in childProcesses where proc.isRunning {
            proc.terminateAndWait()
        }
        childProcesses.removeAll()
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        super.tearDown()
    }

    // MARK: - URL resolution

    func testResolveMessageURLRelativeAndAbsolute() {
        let sse = URL(string: "http://127.0.0.1:9999/sse")!
        let rel = MCPSSEClient.resolveMessageURL(endpoint: "/message?session=abc", sseURL: sse)
        XCTAssertEqual(rel?.absoluteString, "http://127.0.0.1:9999/message?session=abc")

        let abs = MCPSSEClient.resolveMessageURL(
            endpoint: "http://127.0.0.1:9999/mcp-post", sseURL: sse)
        XCTAssertEqual(abs?.absoluteString, "http://127.0.0.1:9999/mcp-post")

        XCTAssertNil(MCPSSEClient.resolveMessageURL(endpoint: "   ", sseURL: sse))
    }

    func testConfigCodableRoundTripSSE() throws {
        let server = MCPServerConfig.sse(
            name: "legacy",
            url: "https://example.com/sse",
            headers: ["X-Test": "1"])
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        XCTAssertEqual(decoded.transport, .sse)
        XCTAssertEqual(decoded.url, "https://example.com/sse")
        XCTAssertEqual(decoded.headers["X-Test"], "1")
    }

    func testJSONRPCIDCoercesString() {
        XCTAssertEqual(MCPSSEClient.jsonRPCID(["id": 7]), 7)
        XCTAssertEqual(MCPSSEClient.jsonRPCID(["id": "12"]), 12)
        XCTAssertNil(MCPSSEClient.jsonRPCID([:]))
    }

    // MARK: - Live GET-session

    func testGETSessionInitializeAndToolsList() async throws {
        let base = try startSSEMock(mode: "legacy")
        let sseURL = base.appendingPathComponent("sse")
        var config = MCPServerConfig.sse(name: "legacy", url: sseURL.absoluteString)
        config.startupTimeout = 4
        let client = MCPSSEClient(config: config)
        try await client.connect()
        do {
            let payload = try await client.request(
                method: "tools/list", params: [:], timeout: 5)
            let tools = payload.value["tools"] as? [[String: Any]]
            XCTAssertEqual(tools?.count, 1)
            XCTAssertEqual(tools?.first?["name"] as? String, "echo")
            let eventID = await client.lastSeenEventID()
            XCTAssertNotNil(eventID)
        } catch {
            XCTFail("legacy SSE client must complete initialize + tools/list: \(error)")
        }
        await client.disconnect()
    }

    func testPOSTToSSEPathIsRejectedByMockSoAliasWouldFail() async throws {
        let base = try startSSEMock(mode: "legacy")
        let sseURL = base.appendingPathComponent("sse")
        // Streamable HTTP POSTs JSON-RPC to the configured URL. The mock
        // answers 405 on POST /sse — proving this is not an alias.
        let http = MCPHttpClient(config: .http(name: "wrong", url: sseURL.absoluteString))
        do {
            try await http.connect()
            XCTFail("Streamable HTTP POST to /sse must fail on a legacy SSE server")
        } catch {
            // Expected — GET-session transport is required.
        }
        await http.disconnect()
    }

    func testPoolDiscoversAndInvokesOverSSE() async throws {
        let base = try startSSEMock(mode: "legacy")
        let sseURL = base.appendingPathComponent("sse")
        var cfg = MCPServerConfig.sse(name: "legacy", url: sseURL.absoluteString)
        cfg.startupTimeout = 4
        let pool = MCPServerPool(servers: [cfg])
        await pool.connectAll()
        let errs = await pool.errors()
        XCTAssertTrue(errs.isEmpty, "SSE pool must connect: \(errs)")
        let tools = await pool.tools()
        XCTAssertEqual(tools.map(\.namespacedName), ["legacy__echo"])

        do {
            let payload = try await pool.invokeTool(
                namespacedName: "legacy__echo", arguments: [:], timeout: 5)
            XCTAssertEqual(payload.value["called"] as? String, "echo")
        } catch {
            XCTFail("pool invoke over SSE must succeed: \(error)")
        }
        await pool.disconnectAll()
    }

    func testAbsoluteEndpointEvent() async throws {
        let base = try startSSEMock(mode: "absolute")
        let sseURL = base.appendingPathComponent("sse")
        var config = MCPServerConfig.sse(name: "abs", url: sseURL.absoluteString)
        config.startupTimeout = 4
        let client = MCPSSEClient(config: config)
        try await client.connect()
        let payload = try await client.request(method: "tools/list", params: [:], timeout: 5)
        XCTAssertNotNil(payload.value["tools"])
        await client.disconnect()
    }

    func testEndpointTimeout() async throws {
        let base = try startSSEMock(mode: "no_endpoint")
        let sseURL = base.appendingPathComponent("sse")
        var config = MCPServerConfig.sse(name: "hang", url: sseURL.absoluteString)
        config.startupTimeout = 0.8
        let client = MCPSSEClient(config: config)
        do {
            try await client.connect()
            XCTFail("connect must time out when no endpoint event arrives")
        } catch {
            let text = String(describing: error)
            XCTAssertTrue(
                text.lowercased().contains("endpoint") || text.lowercased().contains("timed"),
                "expected endpoint timeout, got \(text)")
        }
        await client.disconnect()
    }

    func testFingerprintDistinguishesSSEFromHTTP() {
        let url = "https://mcp.example.test/sse"
        let http = MCPServerConfig.http(name: "s", url: url)
        let sse = MCPServerConfig.sse(name: "s", url: url)
        XCTAssertNotEqual(
            MCPSessionHolder.fingerprint(of: [http]),
            MCPSessionHolder.fingerprint(of: [sse]),
            "sse vs streamableHttp must not reuse the same session")
    }

    // MARK: - Mock

    private func startSSEMock(mode: String) throws -> URL {
        let script = try writeScript(Self.sseMockPython, name: "sse_mock_\(mode).py")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-u", script.path, mode]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        childProcesses.append(proc)

        let handle = stdout.fileHandleForReading
        var buf = Data()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty && !proc.isRunning { break }
            buf.append(chunk)
            if let text = String(data: buf, encoding: .utf8),
               let line = text.split(separator: "\n").first,
               let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)),
               port > 0 {
                return URL(string: "http://127.0.0.1:\(port)/")!
            }
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        proc.terminate()
        throw XCTSkip("SSE mock did not print a port")
    }

    private func writeScript(_ body: String, name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static let sseMockPython = """
    #!/usr/bin/env python3
    import json, sys
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from queue import Empty, Queue

    MODE = sys.argv[1] if len(sys.argv) > 1 else "legacy"
    BUS = Queue()
    PORT_HOLDER = {"port": 0}

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            return

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path != "/sse":
                self.send_error(404)
                return
            accept = self.headers.get("Accept") or ""
            if "text/event-stream" not in accept:
                self.send_error(406)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            if MODE != "no_endpoint":
                if MODE == "absolute":
                    data = "http://127.0.0.1:%d/message?session=abc" % PORT_HOLDER["port"]
                else:
                    data = "/message?session=abc"
                self.wfile.write(("id: 1\\nevent: endpoint\\ndata: %s\\n\\n" % data).encode())
                self.wfile.flush()
            while True:
                try:
                    item = BUS.get(timeout=0.25)
                except Empty:
                    try:
                        self.wfile.write(b": keepalive\\n\\n")
                        self.wfile.flush()
                    except Exception:
                        break
                    continue
                if item is None:
                    break
                try:
                    self.wfile.write(item)
                    self.wfile.flush()
                except Exception:
                    break

        def do_POST(self):
            path = self.path.split("?", 1)[0]
            if path == "/sse":
                self.send_error(405, "legacy SSE: POST goes to message endpoint")
                return
            if path != "/message":
                self.send_error(404)
                return
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b"{}"
            try:
                req = json.loads(raw.decode() or "{}")
            except Exception:
                req = {}
            method = req.get("method")
            rid = req.get("id")
            if rid is None:
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if method == "initialize":
                result = {"protocolVersion": "2024-11-05", "capabilities": {},
                          "serverInfo": {"name": "sse-mock", "version": "0"}}
            elif method == "tools/list":
                result = {"tools": [{"name": "echo", "description": "echo",
                                     "inputSchema": {"type": "object", "properties": {}}}]}
            elif method == "tools/call":
                result = {"called": (req.get("params") or {}).get("name")}
            else:
                result = {}
            payload = json.dumps({"jsonrpc": "2.0", "id": rid, "result": result})
            BUS.put(("id: %s\\nevent: message\\ndata: %s\\n\\n" % (rid, payload)).encode())
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()

    if __name__ == "__main__":
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        PORT_HOLDER["port"] = httpd.server_address[1]
        sys.stdout.write(str(PORT_HOLDER["port"]) + "\\n")
        sys.stdout.flush()
        httpd.serve_forever()
    """
}
