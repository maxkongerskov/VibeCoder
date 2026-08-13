//
//  BugHuntLSPContextUtilTests.swift
//
//  Runtime proofs for confirmed LSP / Context / Util bugs.
//  Each test asserts correct behavior; failure is the proof.
//

import XCTest
@testable import AgentCore

final class BugHuntLSPContextUtilTests: XCTestCase {

    override func tearDown() async throws {
        await CodeNavService.resetTestSeams()
        try await super.tearDown()
    }

    // MARK: - Issue 1: ProcessLSPTransport.run() is invoked twice

    func testProcessLSPTransportInitSucceedsForValidBinary() throws {
        do {
            let transport = try ProcessLSPTransport(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: []
            )
            let exp = expectation(description: "close")
            Task {
                await transport.close()
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5)
        } catch {
            XCTFail(
                "ProcessLSPTransport.init throws on a valid executable because Process.run() is called twice: \(error)"
            )
        }
    }

    func testMakeClientReturnsClientWhenSourceKitLSPIsAvailable() async {
        XCTAssertTrue(SourceKitLSPHost.isAvailable, "fixture: sourcekit-lsp must be installed")
        let before = Self.sourcekitPIDs()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-sk-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            for pid in Self.sourcekitPIDs().subtracting(before) {
                kill(pid, SIGTERM)
            }
        }
        let client = await SourceKitLSPHost.makeClient(projectRoot: root)
        if let client {
            await client.shutdown()
        }
        XCTAssertNotNil(
            client,
            "sourcekit-lsp is installed but makeClient returned nil — ProcessLSPTransport.init throws after the second Process.run()"
        )
    }

    // MARK: - Issue 2: UTF-8 truncation falls back to the full file

    func testAttachmentTruncationDoesNotEmitFullFileOnMidCharacterCut() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-utf8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let body = String(repeating: "é", count: 80) // 160 UTF-8 bytes
        let file = dir.appendingPathComponent("notes.txt")
        try body.write(to: file, atomically: true, encoding: .utf8)

        let maxBytes = 5 // splits a 2-byte é
        let composed = ContextAttachmentFormatter.composeUserMessage(
            text: "see notes",
            attachments: [
                ContextAttachment(path: file.path, displayName: "notes.txt", byteSize: body.utf8.count)
            ],
            maxBytesPerFile: maxBytes
        )

        XCTAssertTrue(composed.contains("```"), composed)
        let fenceParts = composed.components(separatedBy: "```")
        XCTAssertGreaterThanOrEqual(fenceParts.count, 3, composed)
        let included = fenceParts[1].trimmingCharacters(in: .newlines)
        XCTAssertLessThanOrEqual(
            included.utf8.count,
            maxBytes,
            "mid-character UTF-8 cut must not fall back to the full file (\(included.utf8.count) bytes, max \(maxBytes))"
        )
        XCTAssertNotEqual(included, body, "truncation marker present but full multi-byte body was inlined")
    }

    // MARK: - Issue 3: Failed image attachments vanish

    func testMissingImageAttachmentIsNotSilentlyDropped() {
        let missing = "/tmp/bughunt-missing-\(UUID().uuidString).png"
        let composed = ContextAttachmentFormatter.composeMultimodal(
            text: "Look at this",
            attachments: [
                ContextAttachment(path: missing, displayName: "shot.png")
            ]
        )
        let mentioned = composed.text.localizedCaseInsensitiveContains("shot.png")
            || composed.text.localizedCaseInsensitiveContains("missing")
            || composed.text.localizedCaseInsensitiveContains("Attached")
            || !composed.images.isEmpty
        XCTAssertTrue(
            mentioned,
            "image attachment that fails to encode vanished from text and images: \(composed.text)"
        )
    }

    func testCorruptImageAttachmentIsNotSilentlyDropped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-badimg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("broken.png").path
        try Data("this is not a png".utf8).write(to: URL(fileURLWithPath: path))

        let composed = ContextAttachmentFormatter.composeMultimodal(
            text: "Look at this",
            attachments: [
                ContextAttachment(path: path, displayName: "broken.png")
            ]
        )
        let mentioned = composed.text.localizedCaseInsensitiveContains("broken.png")
            || composed.text.localizedCaseInsensitiveContains("Attached")
            || composed.text.localizedCaseInsensitiveContains("image")
            || !composed.images.isEmpty
        XCTAssertTrue(
            mentioned,
            "corrupt PNG vanished from text and images: \(composed.text)"
        )
    }

    // MARK: - Issue 4: inferred LSP column is wrong

    func testInferredDefinitionColumnAccountsForLeadingIndent() async throws {
        try await assertDefinitionCharacter(
            source: "    func ColumnBugSymbolXYZ() {}\n",
            symbol: "ColumnBugSymbolXYZ",
            expectedCharacter: 9
        )
    }

    func testInferredDefinitionColumnUsesUTF16ForEmoji() async throws {
        // 🎉 is one Swift Character / two UTF-16 units. LSP character is UTF-16.
        let source = "🎉 func EmojiColSymXYZ() {}\n"
        let expected = source.utf16.distance(
            from: source.startIndex,
            to: source.range(of: "EmojiColSymXYZ")!.lowerBound
        )
        XCTAssertEqual(expected, 8)
        try await assertDefinitionCharacter(
            source: source,
            symbol: "EmojiColSymXYZ",
            expectedCharacter: expected
        )
    }

    // MARK: - Issue 5: TokenEstimator percent contract

    func testPercentOfContextClampsTo100() {
        let pct = TokenEstimator.percentOfContext(tokens: 9_999, contextSize: 100)
        XCTAssertGreaterThanOrEqual(pct, 0)
        XCTAssertLessThanOrEqual(
            pct,
            100,
            "percentOfContext is documented 0–100 but returned \(pct)"
        )
    }

    // MARK: - Issue 6 / 7: framing overflow trap + timeout double-resume crash

    func testFramingHugeContentLengthDoesNotTrap() {
        var buf = Data("Content-Length: 9223372036854775807\r\n\r\nxxx".utf8)
        let messages = LSPFraming.decode(buffer: &buf)
        XCTAssertTrue(messages.isEmpty)
    }

    func testLSPClientTimeoutDoesNotDoubleResumeWhenWriteThrowsLate() async throws {
        let transport = SlowThrowingLSPTransport(delayNs: 1_500_000_000)
        let client = LSPClient(transport: transport, requestTimeoutSeconds: 1)
        do {
            try await client.initialize(rootURI: URL(fileURLWithPath: "/tmp/bughunt-timeout"))
            XCTFail("initialize should time out, not succeed")
        } catch is LSPError {
            // timeout or transportClosed — must not crash from double-resume
        } catch {
            // any Error is fine; a double-resume would abort the process
        }
        // Write still sleeps ~0.5s after the 1s timeout; wait so a second
        // resume of the request continuation would fire before we return.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        await client.shutdown()
    }

    // MARK: - Helpers

    private func assertDefinitionCharacter(
        source: String,
        symbol: String,
        expectedCharacter: Int
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-col-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("Indented.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let transport = MockLSPTransport()
        let client = LSPClient(transport: transport, requestTimeoutSeconds: 3)
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 1,
            "result": ["capabilities": [String: Any]()],
        ])
        try await client.initialize(rootURI: root)
        try await transport.enqueueJSONResponse([
            "jsonrpc": "2.0", "id": 2,
            "result": [
                "uri": file.absoluteString,
                "range": [
                    "start": ["line": 0, "character": expectedCharacter],
                    "end": ["line": 0, "character": expectedCharacter + symbol.count],
                ],
            ],
        ])

        CodeNavService.testClientProvider = { _ in client }
        let result = await CodeNavService.navigate(
            action: .definition,
            symbol: symbol,
            projectRoot: root,
            filePath: nil,
            line: nil,
            character: nil,
            maxResults: 5
        )
        XCTAssertEqual(result.backend, .lsp, result.note ?? "")

        let bodies = await transport.writtenBodies()
        var sentCharacter: Int?
        for body in bodies {
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  obj["method"] as? String == "textDocument/definition",
                  let params = obj["params"] as? [String: Any],
                  let pos = params["position"] as? [String: Any]
            else { continue }
            sentCharacter = pos["character"] as? Int
        }
        XCTAssertEqual(
            sentCharacter,
            expectedCharacter,
            "inferred LSP column sent \(String(describing: sentCharacter)), want \(expectedCharacter) (UTF-16, untrimmed)"
        )
        await client.shutdown()
    }

    private static func sourcekitPIDs() -> Set<pid_t> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "sourcekit-lsp"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) })
    }
}

/// Write sleeps then throws so a 1s request timeout can resume first.
private actor SlowThrowingLSPTransport: LSPTransport {
    let delayNs: UInt64
    init(delayNs: UInt64) { self.delayNs = delayNs }

    func write(_ data: Data) async throws {
        try await Task.sleep(nanoseconds: delayNs)
        throw LSPError.transportClosed
    }

    func read() async throws -> Data {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return Data()
    }

    func close() async {}
}
