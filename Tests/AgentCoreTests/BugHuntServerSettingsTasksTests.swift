//
//  BugHuntServerSettingsTasksTests.swift
//
//  Verification-first hunt: Server / Settings / Tasks / Skills / Hooks /
//  Permissions. Each test asserts intended production behavior.
//

import XCTest
@testable import AgentCore

final class BugHuntServerSettingsTasksTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-sst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    // MARK: - RemoteAccessPasswordStore

    /// `revoke()` / `rotateSessionSecret()` must not invent a password file.
    /// Creating `Stored(hash:"", …)` makes `isSet()` true and locks the gate:
    /// verify() rejects every password, login cannot succeed.
    func testRotateSessionSecretWithoutPasswordDoesNotMarkStoreAsSet() {
        let store = RemoteAccessPasswordStore(
            fileURL: tempDir.appendingPathComponent("rotate-unset.json"))
        XCTAssertFalse(store.isSet())

        store.rotateSessionSecret()

        XCTAssertFalse(
            store.isSet(),
            "rotateSessionSecret with no password must not write a hash file that looks set")
        XCTAssertFalse(store.verify("anything1"))
        XCTAssertTrue(
            store.issueSessionCookie(expiresAt: Date().addingTimeInterval(3600)).isEmpty,
            "no password → no session secret to sign cookies")
    }

    /// setPassword trims; verify must accept the same typed string.
    func testVerifyAcceptsLeadingTrailingWhitespaceMatchingSetPassword() throws {
        let store = RemoteAccessPasswordStore(
            fileURL: tempDir.appendingPathComponent("trim.json"))
        try store.setPassword("  secret12  ")
        XCTAssertTrue(
            store.verify("  secret12  "),
            "verify must use the same normalization as setPassword")
        XCTAssertTrue(store.verify("secret12"))
    }

    /// Persist failure must surface; callers treat a non-throwing set as stored.
    func testSetPasswordThrowsWhenPersistCannotWrite() {
        let blocker = tempDir.appendingPathComponent("not-a-directory")
        try? Data([0x00]).write(to: blocker)
        let store = RemoteAccessPasswordStore(
            fileURL: blocker.appendingPathComponent("password.json"))
        XCTAssertThrowsError(try store.setPassword("abcdef")) { _ in }
        XCTAssertFalse(store.isSet(), "failed persist must not report a password as set")
    }

    // MARK: - RemoteControlServer lifecycle

    /// 2026-08-20: LAN remote control is shut down. `start()` must refuse
    /// (no all-interfaces bind, no session token/URL). Restore by flipping
    /// `RemoteControlServer.isEnabled` — then this test should be replaced
    /// with the previous “invalid-port restart does not kill a live listener”
    /// contract.
    func testRemoteControlStartDoesNotBindListener() async throws {
        XCTAssertFalse(
            RemoteControlServer.isEnabled,
            "LAN remote control must stay off until isEnabled is flipped")
        let server = RemoteControlServer()
        let port = Int.random(in: 24_000...24_999)
        do {
            _ = try await server.start(port: port, lifetime: 120)
            XCTFail("start() must throw .disabled while remote control is shut down")
        } catch let err as RemoteControlServer.ServerError {
            XCTAssertEqual(err, .disabled)
        }
        let running = await server.isRunning()
        let token = await server.currentToken()
        let url = await server.sessionURL(hostAddress: "127.0.0.1")
        XCTAssertFalse(running, "start() must not leave an NWListener")
        XCTAssertNil(token, "start() must not publish a session token")
        XCTAssertNil(url, "start() must not publish a session URL")

        do {
            _ = try await server.start(port: 0, lifetime: 120)
            XCTFail("start(port: 0) must also refuse")
        } catch {
            // .disabled (fail-closed before port check) or .invalidPort
        }
        let runningAfterInvalid = await server.isRunning()
        let tokenAfterInvalid = await server.currentToken()
        XCTAssertFalse(runningAfterInvalid)
        XCTAssertNil(tokenAfterInvalid)
    }

    // MARK: - LocalAPI CORS

    /// Origin allow-list must parse the host, not prefix-match `http://localhost`.
    func testLocalAPIDoesNotEchoSpoofedLocalhostOrigin() async throws {
        let backend = RecordingBackend()
        let server = LocalAPIServer()
        await server.configure(backend: backend, settings: AppSettings())
        let port = try await startLocalAPI(server)
        defer { Task { await server.stopAndWait() } }

        let evil = try await http(
            url: URL(string: "http://127.0.0.1:\(port)/v1/models")!,
            method: "OPTIONS",
            headers: ["Origin": "http://localhost.evil.com"])
        let evilOrigin = header(evil.response, "Access-Control-Allow-Origin")
        XCTAssertTrue(
            evilOrigin == nil || evilOrigin == "",
            "CORS must not allow http://localhost.evil.com (got \(evilOrigin ?? "nil"))")

        let dotted = try await http(
            url: URL(string: "http://127.0.0.1:\(port)/v1/models")!,
            method: "GET",
            headers: ["Origin": "http://127.0.0.1.attacker.example"])
        let dottedOrigin = header(dotted.response, "Access-Control-Allow-Origin")
        XCTAssertTrue(
            dottedOrigin == nil || dottedOrigin == "",
            "CORS must not allow http://127.0.0.1.attacker.example (got \(dottedOrigin ?? "nil"))")

        let ok = try await http(
            url: URL(string: "http://127.0.0.1:\(port)/v1/models")!,
            method: "GET",
            headers: ["Origin": "http://localhost:3000"])
        XCTAssertEqual(
            header(ok.response, "Access-Control-Allow-Origin"),
            "http://localhost:3000",
            "real localhost origins must still be echoed")
    }

    /// L1: default POST /v1/chat/completions is a backend proxy with `tools: []`.
    func testLocalAPIDefaultChatCompletionsSendsEmptyTools() async throws {
        let backend = RecordingBackend()
        let server = LocalAPIServer()
        await server.configure(backend: backend, settings: AppSettings())
        let on = await server.isAgentToolsEnabled()
        let policy = await server.toolsPolicy()
        XCTAssertFalse(on)
        XCTAssertEqual(policy, .proxyOnly)
        let port = try await startLocalAPI(server)
        defer { Task { await server.stopAndWait() } }

        let body = """
        {"model":"scripted","messages":[{"role":"user","content":"hi"}],"stream":true}
        """
        let result = try await http(
            url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8))
        XCTAssertEqual(result.response.statusCode, 200, String(data: result.body, encoding: .utf8) ?? "")
        XCTAssertEqual(
            backend.lastToolsCount(), 0,
            "default LocalAPI proxy must send tools:[] to the backend")
    }

    /// L1: opt-in agent-loop is a different path — tools execute inside AgentLoop.
    func testLocalAPIOptInAgentLoopSendsToolsOnInnerRequest() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let backend = RecordingBackend()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("l1-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = LocalAPIServer()
        await server.configure(
            backend: backend,
            settings: AppSettings(),
            agentToolsEnabled: true,
            agentLoopProjectRoot: root)
        let on = await server.isAgentToolsEnabled()
        let policy = await server.toolsPolicy()
        XCTAssertTrue(on)
        XCTAssertEqual(policy, .agentLoop)
        let port = try await startLocalAPI(server)
        defer { Task { await server.stopAndWait() } }

        let body = """
        {"model":"scripted","messages":[{"role":"user","content":"hi"}],"stream":true}
        """
        let result = try await http(
            url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8))
        XCTAssertEqual(result.response.statusCode, 200, String(data: result.body, encoding: .utf8) ?? "")
        XCTAssertGreaterThan(
            backend.lastToolsCount(), 0,
            "agent-loop inner ChatRequest must carry ToolRegistry schemas, not tools:[]")
    }

    /// L2: opt-in AgentLoop with no usable project must 400, not run the loop.
    func testLocalAPIOptInWithoutUsableProjectReturns400() async throws {
        let backend = RecordingBackend()
        let server = LocalAPIServer()
        await server.configure(
            backend: backend,
            settings: AppSettings(),
            agentToolsEnabled: true)
        let on = await server.isAgentToolsEnabled()
        let policy = await server.toolsPolicy()
        XCTAssertTrue(on)
        XCTAssertEqual(policy, .agentLoop)
        let boundRoot = await server.currentAgentLoopProjectRoot()
        XCTAssertNil(boundRoot)
        let port = try await startLocalAPI(server)
        defer { Task { await server.stopAndWait() } }

        let body = """
        {"model":"scripted","messages":[{"role":"user","content":"hi"}],"stream":true}
        """
        let result = try await http(
            url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8))
        let text = String(data: result.body, encoding: .utf8) ?? ""
        XCTAssertEqual(result.response.statusCode, 400, text)
        XCTAssertTrue(
            text.contains("Agent loop requires a project folder"),
            "L2 400 body must name the missing project: \(text)")
    }

    // MARK: - AgentOSServeServer agent-tools flag

    /// `agentToolsEnabled: true` is documented to attach schemas (or run an
    /// agent loop). Serve currently resolves `.agentLoop` then drops tools
    /// on the proxy path and never runs AgentLoop.
    func testServeAgentToolsEnabledAttachesSchemasOrRunsLoop() async throws {
        let backend = RecordingBackend()
        let serve = AgentOSServeServer()
        await serve.configure(backend: backend, settings: AppSettings(), agentToolsEnabled: true)
        let port = try await startServe(serve)
        defer { Task { await serve.stop() } }

        let body = """
        {"model":"scripted","messages":[{"role":"user","content":"hi"}]}
        """
        let result = try await http(
            url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8))
        XCTAssertEqual(result.response.statusCode, 200, String(data: result.body, encoding: .utf8) ?? "")

        let toolsCount = backend.lastToolsCount()
        XCTAssertGreaterThan(
            toolsCount, 0,
            "agentToolsEnabled must attach ToolRegistry schemas or run AgentLoop (tools were \(toolsCount))")
    }

    // MARK: - Legacy settings first-run

    /// SettingsStore's no-JSON branch uses `AppSettings()` then
    /// `clearLegacyKeys()`. That must not delete unsourced legacy allow-lists.
    func testFirstRunAppSettingsDoesNotDropLegacySafeModePaths() {
        let suite = "bughunt.legacy.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let custom = ["/Users/me/trusted/"]
        LegacySettingsMigration.seedPathsForTesting(custom, in: defaults)
        XCTAssertEqual(LegacySettingsMigration.migrateSafeModePaths(from: defaults), custom)

        // Same sequence as SettingsStore.init when no AppSettings JSON exists.
        let fresh = AppSettings()
        LegacySettingsMigration.clearLegacyKeys(in: defaults)

        let after = LegacySettingsMigration.migrateSafeModePaths(from: defaults)
        XCTAssertEqual(
            after, custom,
            "first-run AppSettings() + clearLegacyKeys wiped unsourced legacy paths (now \(after)); fresh init used \(fresh.safeModeAllowedPaths)")
    }

    // MARK: - ContextBudget

    /// AppSettings documents `min(model, maxContextWindowTokens)` with no 2048 floor.
    func testUserMaxContextWindowBelow2048IsHonored() {
        let window = ContextBudget.cappedWindow(
            modelWindow: 128_000, maxContextWindowTokens: 1_024)
        XCTAssertEqual(
            window, 1_024,
            "user cap of 1024 must not be raised to 2048")

        let budget = ContextBudget.resolve(
            storedContextLength: 128_000,
            advertised: 128_000,
            maxContextWindowTokens: 1_024,
            compactThresholdPercent: 70)
        XCTAssertLessThanOrEqual(budget, 1_024)
    }

    /// Tiny advertised windows must not be inflated past the model length.
    func testTinyAdvertisedWindowIsNotInflatedPastModelLength() {
        let window = ContextBudget.cappedWindow(modelWindow: 512, maxContextWindowTokens: 0)
        XCTAssertEqual(window, 512, "512-token model must not become a 2048 window")

        let budget = ContextBudget.resolve(
            storedContextLength: 512,
            advertised: 512,
            maxContextWindowTokens: 0,
            compactThresholdPercent: 70)
        XCTAssertLessThanOrEqual(
            budget, 512,
            "budget \(budget) exceeds the model's 512-token window")
    }

    // MARK: - ModelSettingsStore filename collision

    func testModelSettingsDoesNotCollideSlashAndDashDashIds() async throws {
        let dir = tempDir.appendingPathComponent("model-settings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelSettingsStore(directoryURL: dir)
        let defaults = AppSettings()

        var slash = ModelSettings.initial(modelId: "foo/bar", from: defaults)
        slash.loadSettings.contextLength = 11_111
        await store.save(slash)

        var dashed = ModelSettings.initial(modelId: "foo--bar", from: defaults)
        dashed.loadSettings.contextLength = 22_222
        await store.save(dashed)

        let loadedSlash = await store.load(modelId: "foo/bar", defaults: defaults)
        let loadedDashed = await store.load(modelId: "foo--bar", defaults: defaults)
        // In-process cache is keyed by modelId, so both may look distinct until reload.
        XCTAssertEqual(loadedDashed.loadSettings.contextLength, 22_222)

        let nameA = await store.filenameForTesting(modelId: "foo/bar")
        let nameB = await store.filenameForTesting(modelId: "foo--bar")
        XCTAssertNotEqual(nameA, nameB, "foo/bar and foo--bar must not share a JSON filename")

        let reloaded = ModelSettingsStore(directoryURL: dir)
        let slashAfterRestart = await reloaded.load(modelId: "foo/bar", defaults: defaults)
        XCTAssertEqual(
            slashAfterRestart.loadSettings.contextLength, 11_111,
            "disk collision: foo/bar reloaded as \(slashAfterRestart.loadSettings.contextLength) (last writer was foo--bar=22222)")
        _ = loadedSlash
    }

    // MARK: - HookDispatcher command + args

    /// Relative hook binaries must still resolve against hooksDir when they
    /// have arguments (`needsShell` currently switches to `sh -c` + PATH).
    func testPreToolCommandWithArgumentsStillRunsHooksDirScript() throws {
        let root = tempDir.appendingPathComponent("hooks-proj", isDirectory: true)
        let hooks = root.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        HookDispatcher.setHooksHomeDirectoryOverride(root)
        defer { HookDispatcher.setHooksHomeDirectoryOverride(nil) }

        let script = hooks.appendingPathComponent("deny-args.sh")
        try """
        #!/bin/sh
        exit 2
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        func writeConfig(command: String) throws {
            let config: [String: Any] = [
                "pre": [
                    ["matcher": "run_shell", "type": "command", "command": command]
                ]
            ]
            try JSONSerialization.data(withJSONObject: config)
                .write(to: hooks.appendingPathComponent("hooks.json"))
        }

        try writeConfig(command: "deny-args.sh")
        let noArgs = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls", projectRoot: root)
        XCTAssertFalse(noArgs.allow, "control: bare script name must deny (\(noArgs.message ?? ""))")

        try writeConfig(command: "deny-args.sh --strict")
        let withArgs = HookDispatcher.preTool(
            toolName: "run_shell", argumentsSummary: "ls", projectRoot: root)
        XCTAssertFalse(
            withArgs.allow,
            "command with arguments must still run the hooksDir script; got allow (\(withArgs.message ?? "nil"))")
    }

    // MARK: - SkillDiscovery allowed-tools

    func testSkillAllowedToolsParsesYAMLBlockList() {
        let md = """
        ---
        name: gated
        description: Tools listed
        allowed-tools:
          - read_file
          - grep_code
        ---
        # Body
        content
        """
        let skill = SkillDiscovery.parse(markdown: md, defaultName: "x")
        XCTAssertEqual(skill?.name, "gated")
        XCTAssertEqual(
            skill?.allowedTools, ["read_file", "grep_code"],
            "YAML block list is the Grok/Claude skill format (got \(skill?.allowedTools ?? []))")
    }

    func testSkillAllowedToolsParsesSpaceSeparatedList() {
        let parsed = SkillDiscovery.parseAllowedTools("read_file write_file")
        XCTAssertEqual(
            parsed, ["read_file", "write_file"],
            "comment claims space-separated allowed-tools (got \(parsed))")
    }

    func testSkillFrontmatterDoesNotSplitOnEmbeddedTripleDash() {
        let md = """
        ---
        name: dash
        description: see --- notes
        ---
        Body only
        """
        let skill = SkillDiscovery.parse(markdown: md, defaultName: "x")
        XCTAssertEqual(skill?.name, "dash")
        XCTAssertEqual(skill?.description, "see --- notes")
        XCTAssertEqual(skill?.body, "Body only")
    }

    // MARK: - HTTP helpers

    private func startLocalAPI(_ server: LocalAPIServer) async throws -> Int {
        var last: Error?
        for _ in 0..<10 {
            let port = Int.random(in: 22_000...22_999)
            do {
                try await server.start(port: port)
                return port
            } catch {
                last = error
            }
        }
        throw last ?? URLError(.cannotConnectToHost)
    }

    private func startServe(_ server: AgentOSServeServer) async throws -> Int {
        var last: Error?
        for _ in 0..<10 {
            let port = Int.random(in: 23_000...23_999)
            do {
                try await server.start(port: port)
                try await Task.sleep(nanoseconds: 80_000_000)
                return port
            } catch {
                last = error
            }
        }
        throw last ?? URLError(.cannotConnectToHost)
    }

    private struct HTTPResult {
        var response: HTTPURLResponse
        var body: Data
    }

    private func http(
        url: URL,
        method: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> HTTPResult {
        var last: Error = URLError(.cannotConnectToHost)
        for attempt in 0..<12 {
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.timeoutInterval = 3
            req.httpBody = body
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                return HTTPResult(response: http, body: data)
            } catch {
                last = error
                try await Task.sleep(nanoseconds: 50_000_000 * UInt64(attempt + 1))
            }
        }
        throw last
    }

    private func header(_ response: HTTPURLResponse, _ name: String) -> String? {
        if let v = response.value(forHTTPHeaderField: name) { return v }
        for (k, v) in response.allHeaderFields {
            if String(describing: k).caseInsensitiveCompare(name) == .orderedSame {
                return String(describing: v)
            }
        }
        return nil
    }
}

// MARK: - Recording backend

private final class RecordingBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .custom
    private let lock = NSLock()
    private var toolsCount = 0

    func lastToolsCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return toolsCount
    }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "scripted", displayName: "scripted", backend: .custom)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        toolsCount = request.tools.count
        lock.unlock()
        return AsyncThrowingStream { cont in
            cont.yield(.contentDelta("ok"))
            cont.yield(.done(finishReason: "stop"))
            cont.finish()
        }
    }

    func cancel(streamID: UUID) async {}
}
