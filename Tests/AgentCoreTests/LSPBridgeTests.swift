//
//  LSPBridgeTests.swift
//  PB3 — framing, mock JSON-RPC client, find_symbol fallback + LSP path.
//

import XCTest
@testable import AgentCore

final class LSPBridgeTests: XCTestCase {

    override func tearDown() async throws {
        await CodeNavService.resetTestSeams()
        try await super.tearDown()
    }

    // MARK: - Framing

    func testFramingRoundTrip() {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)
        let framed = LSPFraming.encode(body)
        var buf = framed
        let decoded = LSPFraming.decode(buffer: &buf)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0], body)
        XCTAssertTrue(buf.isEmpty)
    }

    func testFramingPartialBuffer() {
        let body = Data(#"{"a":1}"#.utf8)
        let framed = LSPFraming.encode(body)
        var buf = framed.prefix(framed.count / 2)
        var mutable = Data(buf)
        XCTAssertTrue(LSPFraming.decode(buffer: &mutable).isEmpty)
        mutable.append(framed.suffix(from: framed.index(framed.startIndex, offsetBy: framed.count / 2)))
        let decoded = LSPFraming.decode(buffer: &mutable)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0], body)
    }

    // MARK: - Mock LSP client

    func testMockClientWorkspaceSymbol() async throws {
        let transport = MockLSPTransport()
        let client = LSPClient(transport: transport, requestTimeoutSeconds: 3)

        // Pre-queue initialize + workspace/symbol responses.
        // initialize is id=1, workspace/symbol id=2.
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "capabilities": [String: Any](),
            ],
        ])
        // initialized is a notify — no response. initialize() starts the reader.
        try await client.initialize(rootURI: URL(fileURLWithPath: "/tmp/proj"))

        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0",
            "id": 2,
            "result": [
                [
                    "name": "AgentLoop",
                    "kind": 5,
                    "location": [
                        "uri": "file:///tmp/proj/AgentLoop.swift",
                        "range": [
                            "start": ["line": 9, "character": 0],
                            "end": ["line": 9, "character": 10],
                        ],
                    ],
                ],
            ],
        ])

        let symbols = try await client.workspaceSymbol(query: "AgentLoop")
        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols[0].name, "AgentLoop")
        XCTAssertEqual(symbols[0].location.displayLine, 10)
        await client.shutdown()
    }

    func testMockClientDefinitionAndReferences() async throws {
        let transport = MockLSPTransport()
        let client = LSPClient(transport: transport, requestTimeoutSeconds: 3)
        // initialize
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 1,
            "result": ["capabilities": [String: Any]()],
        ])
        try await client.initialize(rootURI: URL(fileURLWithPath: "/tmp/p"))

        // didOpen is notify; definition request id=2
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 2,
            "result": [
                "uri": "file:///tmp/p/Foo.swift",
                "range": [
                    "start": ["line": 3, "character": 7],
                    "end": ["line": 3, "character": 10],
                ],
            ],
        ])
        let file = URL(fileURLWithPath: "/tmp/p/Foo.swift")
        // Create temp file so didOpen can read (may fail silently with empty)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "struct Foo {}\n".write(to: file, atomically: true, encoding: .utf8)

        let defs = try await client.definition(file: file, line: 0, character: 7)
        XCTAssertEqual(defs.count, 1)
        XCTAssertEqual(defs[0].displayLine, 4)

        // references id=3
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 3,
            "result": [
                [
                    "uri": "file:///tmp/p/Bar.swift",
                    "range": [
                        "start": ["line": 1, "character": 0],
                        "end": ["line": 1, "character": 3],
                    ],
                ],
                [
                    "uri": "file:///tmp/p/Baz.swift",
                    "range": [
                        "start": ["line": 5, "character": 0],
                        "end": ["line": 5, "character": 3],
                    ],
                ],
            ],
        ])
        let refs = try await client.references(file: file, line: 0, character: 7)
        XCTAssertEqual(refs.count, 2)
        await client.shutdown()
    }

    // MARK: - CodeNavService + FindSymbolTool

    func testTextIndexFallbackWhenLSPForcedOff() async {
        CodeNavService.forceTextIndexOnly = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb3-text-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Demo.swift")
        try! "struct UniquePB3SymbolXYZ { }\n".write(to: file, atomically: true, encoding: .utf8)

        let result = await CodeNavService.navigate(
            action: .workspaceSymbol,
            symbol: "UniquePB3SymbolXYZ",
            projectRoot: root,
            filePath: nil,
            line: nil,
            character: nil,
            maxResults: 10
        )
        XCTAssertEqual(result.backend, .textIndex)
        XCTAssertFalse(result.hits.isEmpty)
        XCTAssertEqual(result.hits[0].source, .textIndex)
        XCTAssertTrue(result.hits[0].snippet.contains("UniquePB3SymbolXYZ"))
        let formatted = result.formatToolOutput(symbol: "UniquePB3SymbolXYZ")
        XCTAssertTrue(formatted.contains("backend: text-index"), formatted)
        XCTAssertTrue(formatted.contains("honesty:"), formatted)
    }

    func testCodeNavUsesTestLSPClientForWorkspaceSymbol() async throws {
        let transport = MockLSPTransport()
        let client = LSPClient(transport: transport, requestTimeoutSeconds: 3)
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 1,
            "result": ["capabilities": [String: Any]()],
        ])
        try await client.initialize(rootURI: URL(fileURLWithPath: "/tmp/nav"))

        CodeNavService.testClientProvider = { _ in client }

        // workspace/symbol will be id=2
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 2,
            "result": [
                [
                    "name": "FromLSP",
                    "kind": 12,
                    "location": [
                        "uri": "file:///tmp/nav/FromLSP.swift",
                        "range": [
                            "start": ["line": 0, "character": 0],
                            "end": ["line": 0, "character": 7],
                        ],
                    ],
                ],
            ],
        ])

        let result = await CodeNavService.navigate(
            action: .workspaceSymbol,
            symbol: "FromLSP",
            projectRoot: URL(fileURLWithPath: "/tmp/nav"),
            filePath: nil,
            line: nil,
            character: nil,
            maxResults: 5
        )
        XCTAssertEqual(result.backend, .lsp, result.note ?? "")
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertEqual(result.hits[0].source, .lsp)
        XCTAssertTrue(result.hits[0].path.contains("FromLSP.swift"))
        let formatted = result.formatToolOutput(symbol: "FromLSP")
        XCTAssertTrue(formatted.contains("backend: lsp"), formatted)
        XCTAssertTrue(formatted.contains("honesty:"), formatted)
        XCTAssertTrue(formatted.contains("Not full IDE navigation"), formatted)
    }

    func testFindSymbolToolReportsBackend() async throws {
        CodeNavService.forceTextIndexOnly = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb3-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "func findSymbolToolMarkerFn() {}\n".write(
            to: root.appendingPathComponent("M.swift"),
            atomically: true,
            encoding: .utf8
        )

        await ToolRegistry.shared.registerBuiltins()
        let ctx = ToolContext(
            projectRoot: root,
            worktreeRoot: nil,
            safeMode: nil,
            conversationID: UUID()
        )
        let result = try await ToolRegistry.shared.execute(
            name: "find_symbol",
            arguments: ToolArguments(dictionary: [
                "symbol": "findSymbolToolMarkerFn",
                "action": "workspace_symbol",
            ]),
            context: ctx
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("backend: text-index"), result.content)
        XCTAssertTrue(result.content.contains("honesty:"), result.content)
        XCTAssertTrue(result.content.contains("findSymbolToolMarkerFn"), result.content)
        XCTAssertTrue(result.content.contains("action: workspace_symbol"), result.content)
        // Schema must not oversell full IDE.
        XCTAssertTrue(
            FindSymbolTool.schema.description.localizedCaseInsensitiveContains("not full IDE")
                || FindSymbolTool.schema.description.localizedCaseInsensitiveContains("not a full IDE")
                || FindSymbolTool.schema.description.contains("not full IDE"),
            FindSymbolTool.schema.description
        )
    }

    /// P5 string contract: empty results still label backend + honesty.
    func testFormatToolOutputEmptyAlwaysLabelsBackend() {
        let empty = CodeNavResult(
            action: .workspaceSymbol,
            hits: [],
            backend: .textIndex,
            note: "nothing found"
        )
        let text = empty.formatToolOutput(symbol: "MissingSymXYZ")
        XCTAssertTrue(text.contains("No hits for MissingSymXYZ"), text)
        XCTAssertTrue(text.contains("backend: text-index"), text)
        XCTAssertTrue(text.contains("action: workspace_symbol"), text)
        XCTAssertTrue(text.contains("honesty:"), text)
        XCTAssertTrue(text.contains("note: nothing found"), text)
        // Only allow the two canonical backend tokens in the backend line.
        let backendLines = text.split(separator: "\n").filter { $0.hasPrefix("backend:") }
        XCTAssertEqual(backendLines.count, 1)
        XCTAssertTrue(
            backendLines[0] == "backend: text-index" || backendLines[0] == "backend: lsp",
            String(backendLines[0])
        )
    }

    func testFindSymbolActionParse() {
        XCTAssertEqual(CodeNavAction.parse(nil), .workspaceSymbol)
        XCTAssertEqual(CodeNavAction.parse("definition"), .definition)
        XCTAssertEqual(CodeNavAction.parse("REFERENCES"), .references)
        XCTAssertEqual(CodeNavAction.parse("workspace_symbol"), .workspaceSymbol)
    }

    func testSourceKitAvailabilityDoesNotCrash() {
        // Honesty: may be true on dev Macs, false in some CI — just call the API.
        _ = SourceKitLSPHost.isAvailable
        _ = SourceKitLSPHost.resolveBinary()
    }

    func testParseLocationsLocationLink() {
        let link: [String: Any] = [
            "targetUri": "file:///a.swift",
            "targetSelectionRange": [
                "start": ["line": 2, "character": 1],
                "end": ["line": 2, "character": 4],
            ],
        ]
        let locs = LSPClient.parseLocations(link)
        XCTAssertEqual(locs.count, 1)
        XCTAssertEqual(locs[0].displayLine, 3)
    }

    // MARK: - D2 persistent pool + didChange

    func testPoolReusesClientAcrossSequentialNavigate() async throws {
        await CodeNavService.resetTestSeams()
        let root = URL(fileURLWithPath: "/tmp/d2-pool-\(UUID().uuidString)")
        let transport = MockLSPTransport()
        let client = LSPClient(transport: transport, requestTimeoutSeconds: 3)
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 1,
            "result": ["capabilities": [String: Any]()],
        ])
        try await client.initialize(rootURI: root)

        let id = client.objectID
        CodeNavService.testClientProvider = { _ in client }

        // workspace/symbol for first navigate — next request id is 2
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 2,
            "result": [
                [
                    "name": "ReuseMe",
                    "kind": 5,
                    "location": [
                        "uri": "file://\(root.path)/R.swift",
                        "range": [
                            "start": ["line": 0, "character": 0],
                            "end": ["line": 0, "character": 1],
                        ],
                    ],
                ],
            ],
        ])
        let r1 = await CodeNavService.navigate(
            action: .workspaceSymbol,
            symbol: "ReuseMe",
            projectRoot: root,
            filePath: nil,
            line: nil,
            character: nil,
            maxResults: 5
        )
        XCTAssertEqual(r1.backend, .lsp, r1.note ?? "")

        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 3,
            "result": [
                [
                    "name": "ReuseMe",
                    "kind": 5,
                    "location": [
                        "uri": "file://\(root.path)/R.swift",
                        "range": [
                            "start": ["line": 0, "character": 0],
                            "end": ["line": 0, "character": 1],
                        ],
                    ],
                ],
            ],
        ])
        let r2 = await CodeNavService.navigate(
            action: .workspaceSymbol,
            symbol: "ReuseMe",
            projectRoot: root,
            filePath: nil,
            line: nil,
            character: nil,
            maxResults: 5
        )
        XCTAssertEqual(r2.backend, .lsp, r2.note ?? "")

        let stats = await LSPClientSessionPool.shared.stats()
        XCTAssertEqual(stats.createCount, 1, "pool must create once")
        XCTAssertGreaterThanOrEqual(stats.reuseCount, 1, "second navigate must reuse")
        XCTAssertEqual(stats.sessionCount, 1)

        // Same actor instance
        let again = await LSPClientSessionPool.shared.client(for: root)
        XCTAssertEqual(again?.objectID, id)
    }

    func testDidChangeIncrementsVersionAndSyncCount() async throws {
        let transport = MockLSPTransport()
        let client = LSPClient(transport: transport, requestTimeoutSeconds: 3)
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 1,
            "result": ["capabilities": [String: Any]()],
        ])
        try await client.initialize(rootURI: URL(fileURLWithPath: "/tmp/d2-change"))

        let file = URL(fileURLWithPath: "/tmp/d2-change/Foo.swift")
        try await client.notifyDocumentDidChange(file: file, text: "struct Foo {}\n")
        let open1 = await client.openDocumentCount
        let sync1 = await client.documentSyncEventCount
        XCTAssertEqual(open1, 1)
        XCTAssertEqual(sync1, 1) // didOpen

        try await client.notifyDocumentDidChange(file: file, text: "struct Foo { var x = 1 }\n")
        let sync2 = await client.documentSyncEventCount
        XCTAssertEqual(sync2, 2) // didChange

        // Inspect written methods for didChange
        let bodies = await transport.writtenBodies()
        var sawDidOpen = false
        var sawDidChange = false
        for body in bodies {
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let method = obj["method"] as? String else { continue }
            if method == "textDocument/didOpen" { sawDidOpen = true }
            if method == "textDocument/didChange" {
                sawDidChange = true
                if let params = obj["params"] as? [String: Any],
                   let td = params["textDocument"] as? [String: Any],
                   let version = td["version"] as? Int {
                    XCTAssertEqual(version, 2)
                }
            }
        }
        XCTAssertTrue(sawDidOpen)
        XCTAssertTrue(sawDidChange)
        await client.shutdown()
    }

    func testDefinitionSyncsDiskEditsViaDidChange() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("d2-disk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Bar.swift")
        try "struct Bar {}\n".write(to: file, atomically: true, encoding: .utf8)

        let transport = MockLSPTransport()
        let client = LSPClient(transport: transport, requestTimeoutSeconds: 3)
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 1,
            "result": ["capabilities": [String: Any]()],
        ])
        try await client.initialize(rootURI: dir)

        // definition → didOpen + request id=2
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 2,
            "result": [
                "uri": file.absoluteString,
                "range": [
                    "start": ["line": 0, "character": 7],
                    "end": ["line": 0, "character": 10],
                ],
            ],
        ])
        _ = try await client.definition(file: file, line: 0, character: 7)
        let afterOpen = await client.documentSyncEventCount
        XCTAssertEqual(afterOpen, 1)

        // Edit on disk then definition again → didChange + request id=3
        try "struct Bar { var y = 2 }\n".write(to: file, atomically: true, encoding: .utf8)
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 3,
            "result": [
                "uri": file.absoluteString,
                "range": [
                    "start": ["line": 0, "character": 7],
                    "end": ["line": 0, "character": 10],
                ],
            ],
        ])
        _ = try await client.definition(file: file, line: 0, character: 7)
        let afterChange = await client.documentSyncEventCount
        XCTAssertEqual(afterChange, 2, "disk edit must trigger didChange")
        await client.shutdown()
    }

    func testIdleEvictionRemovesSession() async throws {
        await LSPClientSessionPool.shared.resetForTests()
        let root = URL(fileURLWithPath: "/tmp/d2-idle-\(UUID().uuidString)")
        let transport = MockLSPTransport()
        let client = LSPClient(transport: transport, requestTimeoutSeconds: 2)
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 1,
            "result": ["capabilities": [String: Any]()],
        ])
        try await client.initialize(rootURI: root)

        await LSPClientSessionPool.shared.setClientFactory { _ in client }
        _ = await LSPClientSessionPool.shared.client(for: root)
        var stats = await LSPClientSessionPool.shared.stats()
        XCTAssertEqual(stats.sessionCount, 1)

        await LSPClientSessionPool.shared.setIdleTimeout(0.01)
        // Force lastUsed into the past via touch + sleep + evict
        try await Task.sleep(nanoseconds: 30_000_000)
        await LSPClientSessionPool.shared.evictIdleSessions(now: Date().addingTimeInterval(10))
        stats = await LSPClientSessionPool.shared.stats()
        XCTAssertEqual(stats.sessionCount, 0)
        XCTAssertGreaterThanOrEqual(stats.idleEvictCount, 1)
        await LSPClientSessionPool.shared.resetForTests()
    }

    func testTextIndexFallbackStillWorksWithPool() async {
        await CodeNavService.resetTestSeams()
        CodeNavService.forceTextIndexOnly = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("d2-text-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try! "func D2TextOnlySymbolQQQ() {}\n".write(
            to: root.appendingPathComponent("T.swift"), atomically: true, encoding: .utf8)
        let result = await CodeNavService.navigate(
            action: .workspaceSymbol,
            symbol: "D2TextOnlySymbolQQQ",
            projectRoot: root,
            filePath: nil,
            line: nil,
            character: nil,
            maxResults: 5
        )
        XCTAssertEqual(result.backend, .textIndex)
        XCTAssertFalse(result.hits.isEmpty)
    }
}
