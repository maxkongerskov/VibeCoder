import CryptoKit
import XCTest
@testable import AgentCore

/// Verification-first MCP bug hunt. Each test asserts correct runtime
/// behavior; a failure is the proof.
final class BugHuntMCPTests: XCTestCase {

    private var scratch: URL!
    private var childProcesses: [Process] = []

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("BugHuntMCP-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Helpers

    private func writeScript(_ body: String, name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func startHTTPMock(mode: String) throws -> (Process, URL) {
        let script = try writeScript(Self.httpMockPython, name: "http_mock_\(mode).py")
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
                return (proc, URL(string: "http://127.0.0.1:\(port)/")!)
            }
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        proc.terminate()
        throw XCTSkip("HTTP mock did not print a port")
    }

    // MARK: - JSON-RPC id coercion

    func testJSONRPCParserAcceptsNumericId() {
        let line = #"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#
        guard case .success(let id, let payload)? = MCPJSONRPCParser.parse(line: line) else {
            return XCTFail("numeric id must parse")
        }
        XCTAssertEqual(id, 7)
        XCTAssertEqual(payload["ok"] as? Bool, true)
    }

    func testJSONRPCParserAcceptsStringId() {
        // JSON-RPC 2.0 ids may be string or number. Servers that echo
        // `"id":"1"` must still fulfill the pending request.
        let line = #"{"jsonrpc":"2.0","id":"1","result":{"ok":true}}"#
        guard case .success(let id, let payload)? = MCPJSONRPCParser.parse(line: line) else {
            return XCTFail("string JSON-RPC id must be coerced and dispatched")
        }
        XCTAssertEqual(id, 1)
        XCTAssertEqual(payload["ok"] as? Bool, true)
    }

    func testJSONRPCParserAcceptsStringIdOnError() {
        let line = #"{"jsonrpc":"2.0","id":"2","error":{"code":-32600,"message":"bad"}}"#
        guard case .failure(let id, let error)? = MCPJSONRPCParser.parse(line: line) else {
            return XCTFail("string JSON-RPC id on error responses must be coerced")
        }
        XCTAssertEqual(id, 2)
        if case .serverError(let code, let message) = error {
            XCTAssertEqual(code, -32600)
            XCTAssertEqual(message, "bad")
        } else {
            XCTFail("expected serverError, got \(error)")
        }
    }

    func testStdioClientFulfillsWhenServerEchoesStringId() async throws {
        let script = try writeScript("""
        #!/usr/bin/env python3
        import json, sys
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            req = json.loads(line)
            rid = req.get("id")
            method = req.get("method")
            if rid is None:
                continue
            # Handshake keeps a numeric id so connect() can finish; tools/list
            # stringifies the id the way several JSON-RPC stacks do.
            echo_id = rid if method == "initialize" else str(rid)
            if method == "initialize":
                result = {"protocolVersion": "2024-11-05", "capabilities": {}}
            elif method == "tools/list":
                result = {"tools": []}
            else:
                result = {}
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": echo_id, "result": result}) + "\\n")
            sys.stdout.flush()
        """, name: "string_id_bridge.py")

        let client = MCPStdioClient()
        try await client.connect(executable: script)
        do {
            let payload = try await client.request(
                method: "tools/list", params: [:], timeout: 2)
            XCTAssertNotNil(payload.value["tools"])
        } catch {
            XCTFail("stdio client must fulfill a response whose id is a string: \(error)")
        }
        await client.disconnect()
    }

    // MARK: - Tool-name splitting

    func testInvokeToolSplitsOnFirstDelimiterWhenToolContainsDunder() async throws {
        XCTAssertNil(MCPToolNaming.validate("foo__bar"),
                     "underscores (including __) are legal in MCP tool names")
        XCTAssertEqual(MCPToolNaming.namespaced(server: "demo", tool: "foo__bar"),
                       "demo__foo__bar")

        let script = try writeScript("""
        #!/usr/bin/env python3
        import json, sys
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            req = json.loads(line)
            rid = req.get("id")
            method = req.get("method")
            if rid is None:
                continue
            if method == "initialize":
                result = {"protocolVersion": "2024-11-05", "capabilities": {}}
            elif method == "tools/list":
                result = {"tools": [{
                    "name": "foo__bar",
                    "description": "dunder tool",
                    "inputSchema": {"type": "object", "properties": {}}
                }]}
            elif method == "tools/call":
                result = {"called": req.get("params", {}).get("name")}
            else:
                result = {}
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\\n")
            sys.stdout.flush()
        """, name: "dunder_tool_bridge.py")

        let pool = MCPServerPool(servers: [
            .stdio(name: "demo", command: script.path)
        ])
        await pool.connectAll()
        let errs = await pool.errors()
        XCTAssertTrue(errs.isEmpty, "mock server must connect: \(errs)")
        let tools = await pool.tools()
        XCTAssertEqual(tools.map(\.namespacedName), ["demo__foo__bar"])

        do {
            let payload = try await pool.invokeTool(
                namespacedName: "demo__foo__bar", arguments: [:], timeout: 5)
            XCTAssertEqual(payload.value["called"] as? String, "foo__bar",
                           "must call tool foo__bar on server demo, not split on the last __")
        } catch {
            XCTFail("invokeTool(demo__foo__bar) must route to server 'demo': \(error)")
        }
        await pool.disconnectAll()
    }

    // MARK: - Token file permissions

    func testTokenStoreOverwriteForces0600WhenDestinationWasWorldReadable() throws {
        let url = scratch.appendingPathComponent("creds.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let beforePerms = (before[.posixPermissions] as? NSNumber)?.int16Value ?? -1
        XCTAssertEqual(beforePerms & 0o777, 0o644, "precondition: world-readable dest")

        let store = MCPTokenStore(fileURL: url)
        store.save(key: "svc:https://example.test",
                   credential: MCPOAuthCredential(clientID: "c", accessToken: "tok"))

        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        let afterPerms = (after[.posixPermissions] as? NSNumber)?.int16Value ?? -1
        XCTAssertEqual(afterPerms & 0o777, 0o600,
                       "replaceItemAt must not preserve destination 0644 on token files")
        XCTAssertEqual(store.load(key: "svc:https://example.test")?.accessToken, "tok")
    }

    // MARK: - PKCE

    func testPKCERFC7636AppendixBChallengeVector() {
        // RFC 7636 Appendix B S256 test vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let digest = SHA256.hash(data: Data(verifier.utf8))
        XCTAssertEqual(
            base64URLEncode(Data(digest)),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertTrue(MCPPKCEPair.generate().isValid())
    }

    func testCallbackServerStartFindsEphemeralLoopbackPort() throws {
        // OAuth/PKCE loopback (RFC 8252) uses preferredPort 0 → findFreeLoopbackPort.
        let server = MCPCallbackServer()
        let uri = try server.start()
        defer { server.stop() }
        XCTAssertTrue(uri.hasPrefix("http://127.0.0.1:"), uri)
        XCTAssertGreaterThan(server.port, 0)
        XCTAssertNotNil(
            MCPCallbackServer.findFreeLoopbackPort(),
            "ephemeral loopback bind must succeed (INADDR_LOOPBACK is host-order; needs htonl)")
    }

    func testCallbackServerReceivesAuthorizationCode() async throws {
        let server = MCPCallbackServer()
        let uri = try server.start()
        defer { server.stop() }

        let url = URL(string: uri + "?code=auth-code-1&state=csrf-state")!
        async let waiter = server.waitForCallback(timeout: 5)
        let (_, response) = try await URLSession.shared.data(from: url)
        let http = response as? HTTPURLResponse
        XCTAssertEqual(http?.statusCode, 200)
        let callback = try await waiter
        XCTAssertEqual(callback.code, "auth-code-1")
        XCTAssertEqual(callback.state, "csrf-state")
    }

    // MARK: - Config walk

    func testDiscoverProjectConfigsWalksNestedDirsRootFirst() throws {
        let root = scratch.appendingPathComponent("repo")
        let mid = root.appendingPathComponent("mid")
        let leaf = mid.appendingPathComponent("leaf")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        try #"{"mcpServers":{}}"#.write(
            to: root.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{}}"#.write(
            to: mid.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{}}"#.write(
            to: leaf.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

        let files = MCPConfigWalker.discoverProjectConfigFiles(cwd: leaf)
        XCTAssertEqual(files.count, 3, "must collect .mcp.json at root, mid, and leaf")
        let resolved = files.map {
            $0.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        }
        XCTAssertEqual(
            resolved.first,
            root.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(
            resolved.last,
            leaf.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func testResolveMcpServersNearerProjectFileReplacesEntirely() throws {
        let root = scratch.appendingPathComponent("repo2")
        let leaf = root.appendingPathComponent("leaf")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        try """
        {"mcpServers":{"walkA":{"type":"http","url":"https://root.example/sse","toolTimeout":10}}}
        """.write(to: root.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try """
        {"mcpServers":{"walkA":{"type":"http","url":"https://leaf.example/sse","toolTimeout":99}}}
        """.write(to: leaf.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

        let resolved = MCPConfigWalker.resolveMcpServers(cwd: leaf, appSettingsServers: [])
        let walkA = resolved.first { $0.name == "walkA" }
        XCTAssertEqual(walkA?.url, "https://leaf.example/sse")
        XCTAssertEqual(walkA?.toolTimeout, 99)
    }

    // MARK: - Stdio framing

    func testStdioClientAcceptsUTF8SplitAcrossReads() async throws {
        let script = try writeScript("""
        #!/usr/bin/env python3
        import json, sys, time

        def send(raw):
            sys.stdout.buffer.write(raw)
            sys.stdout.buffer.flush()

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            req = json.loads(line)
            rid = req.get("id")
            method = req.get("method")
            if rid is None:
                continue
            if method == "initialize":
                send((json.dumps({
                    "jsonrpc": "2.0", "id": rid,
                    "result": {"protocolVersion": "2024-11-05", "capabilities": {}}
                }) + "\\n").encode())
            elif method == "tools/list":
                # Split the euro sign (U+20AC = E2 82 AC) across two flushes so
                # a String(utf8) decoder that does not buffer incomplete
                # sequences drops the response.
                prefix = b'{"jsonrpc":"2.0","id":' + json.dumps(rid).encode() + b',"result":{"msg":"'
                send(prefix + bytes([0xE2]))
                time.sleep(0.4)
                send(bytes([0x82, 0xAC]) + b'"}}\\n')
            else:
                send((json.dumps({"jsonrpc": "2.0", "id": rid, "result": {}}) + "\\n").encode())
        """, name: "utf8_split_bridge.py")

        let client = MCPStdioClient()
        try await client.connect(executable: script)
        do {
            let payload = try await client.request(
                method: "tools/list", params: [:], timeout: 3)
            XCTAssertEqual(payload.value["msg"] as? String, "€")
        } catch {
            XCTFail("stdio framing must reassemble UTF-8 split across reads: \(error)")
        }
        await client.disconnect()
    }

    // MARK: - HTTP session

    func testHTTPClientSendsMcpSessionIdOnSubsequentRequests() async throws {
        let (_, base) = try startHTTPMock(mode: "session")
        let client = MCPHttpClient(config: .http(name: "sess", url: base.absoluteString))
        try await client.connect()
        do {
            let payload = try await client.request(
                method: "tools/list", params: [:], timeout: 5)
            XCTAssertNotNil(payload.value["tools"],
                            "tools/list after initialize must include Mcp-Session-Id")
        } catch {
            XCTFail("HTTP client must replay Mcp-Session-Id from initialize: \(error)")
        }
        await client.disconnect()
    }

    func testHTTPClientParsesPlainJSONContainingDataColon() async throws {
        let (_, base) = try startHTTPMock(mode: "data_colon")
        let client = MCPHttpClient(config: .http(name: "dc", url: base.absoluteString))
        do {
            try await client.connect()
        } catch {
            XCTFail("plain JSON containing the substring 'data:' must not take the SSE path: \(error)")
            return
        }
        await client.disconnect()
    }

    func testHTTPClientAcceptHeaderIncludesApplicationJSON() async throws {
        let (_, base) = try startHTTPMock(mode: "accept")
        let client = MCPHttpClient(config: .http(name: "ac", url: base.absoluteString))
        do {
            try await client.connect()
        } catch {
            XCTFail("Accept must list application/json and text/event-stream: \(error)")
            return
        }
        await client.disconnect()
    }

    func testSessionFingerprintIncludesAuthMaterial() {
        let url = "https://mcp.example.test/sse"
        let a = MCPServerConfig.http(
            name: "s", url: url, headers: ["Authorization": "Bearer one"])
        let b = MCPServerConfig.http(
            name: "s", url: url, headers: ["Authorization": "Bearer two"])
        XCTAssertNotEqual(
            MCPSessionHolder.fingerprint(of: [a]),
            MCPSessionHolder.fingerprint(of: [b]),
            "header changes must invalidate the reused HTTP session")

        let envA = MCPServerConfig.stdio(
            name: "t", command: "/bin/echo", env: ["TOKEN": "1"])
        let envB = MCPServerConfig.stdio(
            name: "t", command: "/bin/echo", env: ["TOKEN": "2"])
        XCTAssertNotEqual(
            MCPSessionHolder.fingerprint(of: [envA]),
            MCPSessionHolder.fingerprint(of: [envB]),
            "stdio env changes must invalidate the reused session")

        var oauthA = MCPServerConfig.http(name: "o", url: url)
        oauthA.oauth = MCPOAuthConfig(
            clientID: "c1",
            authorizationURL: "https://auth.example/a",
            tokenURL: "https://auth.example/t")
        var oauthB = MCPServerConfig.http(name: "o", url: url)
        oauthB.oauth = MCPOAuthConfig(
            clientID: "c2",
            authorizationURL: "https://auth.example/a",
            tokenURL: "https://auth.example/t")
        XCTAssertNotEqual(
            MCPSessionHolder.fingerprint(of: [oauthA]),
            MCPSessionHolder.fingerprint(of: [oauthB]),
            "oauth client changes must invalidate the reused session")
    }

    // MARK: - HTTP mock

    private static let httpMockPython = """
    #!/usr/bin/env python3
    import json, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer

    MODE = sys.argv[1] if len(sys.argv) > 1 else "session"

    class H(BaseHTTPRequestHandler):
        def log_message(self, *args):
            return

        def _send(self, code, obj, extra=None):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            if extra:
                for k, v in extra.items():
                    self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b"{}"
            try:
                req = json.loads(raw.decode() or "{}")
            except Exception:
                req = {}
            method = req.get("method")
            rid = req.get("id")
            accept = self.headers.get("Accept") or ""

            if MODE == "accept":
                if "application/json" not in accept:
                    self._send(406, {"error": "Accept must include application/json"})
                    return
                if method == "initialize":
                    self._send(200, {"jsonrpc": "2.0", "id": rid, "result": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {},
                        "serverInfo": {"name": "accept-mock", "version": "0"}
                    }})
                    return
                self._send(200, {"jsonrpc": "2.0", "id": rid, "result": {}})
                return

            if MODE == "data_colon":
                if method == "initialize":
                    self._send(200, {"jsonrpc": "2.0", "id": rid, "result": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {},
                        "serverInfo": {"name": "data: colon-server", "version": "0"}
                    }})
                    return
                self._send(200, {"jsonrpc": "2.0", "id": rid, "result": {
                    "note": "payload may mention data: safely"
                }})
                return

            # session mode
            if method == "initialize":
                self._send(200, {"jsonrpc": "2.0", "id": rid, "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "serverInfo": {"name": "session-mock", "version": "0"}
                }}, extra={"Mcp-Session-Id": "sess-1"})
                return
            if method == "notifications/initialized":
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.headers.get("Mcp-Session-Id") != "sess-1":
                self._send(400, {"error": "missing or invalid Mcp-Session-Id"})
                return
            if method == "tools/list":
                self._send(200, {"jsonrpc": "2.0", "id": rid, "result": {"tools": []}})
                return
            self._send(200, {"jsonrpc": "2.0", "id": rid, "result": {}})

    if __name__ == "__main__":
        httpd = HTTPServer(("127.0.0.1", 0), H)
        sys.stdout.write(str(httpd.server_address[1]) + "\\n")
        sys.stdout.flush()
        httpd.serve_forever()
    """
}
