//
//  ParityHookConfigStoreTests.swift
//  Wave U1 hooks-ui — store schema matches HookDispatcher.loadConfig.
//

import XCTest
@testable import AgentCore

final class ParityHookConfigStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    // MARK: - Codable

    func testHookEntryEncodeDecodeRoundTripEquality() throws {
        let entry = HookEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID(),
            event: HookDispatcher.eventPreToolUse,
            matcher: "Write",
            command: "echo 'Hello from hook'",
            args: ["--strict", "path"],
            timeoutSeconds: 12,
            background: true,
            enabled: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        let decoded = try JSONDecoder().decode(HookEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    func testEntriesJSONRoundTripPreservesPayload() throws {
        let original = [
            HookEntry(
                event: HookDispatcher.eventSessionStart,
                command: "setup.sh",
                args: [],
                timeoutSeconds: nil,
                background: false,
                enabled: true
            ),
            HookEntry(
                event: HookDispatcher.eventPreToolUse,
                matcher: "Write, Edit, Bash",
                command: "lint.sh",
                args: ["--fix"],
                timeoutSeconds: 30,
                background: true,
                enabled: true
            ),
        ]
        let data = try HookConfigStore.prettyJSONData(
            HookConfigStore.encodeEntriesObject(original)
        )
        let decoded = try HookConfigStore.decodeEntries(from: data)
        XCTAssertEqual(decoded.count, original.count)
        for (lhs, rhs) in zip(decoded, original) {
            assertPayloadEqual(lhs, rhs)
        }
    }

    // MARK: - Dispatcher load path

    func testSaveThenLoadThroughDispatcher() throws {
        let config = HookConfigFile(
            pre: [
                HookMatcherGroup(
                    matcher: "run_shell",
                    handlers: [
                        HookHandlerSpec(
                            type: "command",
                            command: "block.sh",
                            timeoutSeconds: 8,
                            name: "block"
                        )
                    ]
                )
            ],
            userPromptSubmit: [
                HookMatcherGroup(
                    handlers: [
                        HookHandlerSpec(
                            type: "command",
                            command: "guard.sh",
                            timeoutSeconds: 5,
                            name: "guard"
                        )
                    ]
                )
            ],
            permissionRequest: [
                HookMatcherGroup(
                    matcher: "Write",
                    handlers: [
                        HookHandlerSpec(
                            type: "command",
                            command: "ask.sh",
                            timeoutSeconds: 5,
                            name: "ask"
                        )
                    ]
                )
            ],
            postToolUseFailure: [
                HookMatcherGroup(
                    handlers: [
                        HookHandlerSpec(
                            type: "command",
                            command: "fail.sh",
                            timeoutSeconds: 5,
                            name: "fail"
                        )
                    ]
                )
            ]
        )

        try HookConfigStore.save(config, projectRoot: root)

        let dir = try XCTUnwrap(HookDispatcher.projectHooksDir(projectRoot: root))
        let loaded = HookDispatcher.loadConfig(hooksDir: dir)
        XCTAssertEqual(loaded, config)

        let viaStore = HookConfigStore.load(projectRoot: root)
        XCTAssertEqual(viaStore, config)
    }

    func testSaveEntriesThenDispatcherSeesCommandAndMatcher() throws {
        let entries = [
            HookEntry(
                event: HookDispatcher.eventPostToolUse,
                matcher: "edit_file",
                command: "lint.sh",
                args: ["--quiet"],
                timeoutSeconds: 20,
                background: false,
                enabled: true
            ),
            HookEntry(
                event: HookDispatcher.eventStop,
                command: "notify.sh",
                timeoutSeconds: nil,
                background: true,
                enabled: true
            ),
        ]
        try HookConfigStore.saveEntries(entries, projectRoot: root)

        let dir = try XCTUnwrap(HookDispatcher.projectHooksDir(projectRoot: root))
        let loaded = HookDispatcher.loadConfig(hooksDir: dir)
        XCTAssertEqual(loaded.post.count, 1)
        XCTAssertEqual(loaded.post[0].matcher, "edit_file")
        XCTAssertEqual(loaded.post[0].handlers[0].command, "lint.sh")
        XCTAssertEqual(loaded.post[0].handlers[0].timeoutSeconds, 20)
        XCTAssertEqual(loaded.stop.count, 1)
        XCTAssertEqual(loaded.stop[0].handlers[0].command, "notify.sh")
        XCTAssertEqual(loaded.stop[0].handlers[0].timeoutSeconds, 5)
    }

    func testDisabledHookIsOmittedFromDispatcherHooks() throws {
        let entries = [
            HookEntry(
                event: HookDispatcher.eventPreToolUse,
                command: "live.sh",
                enabled: true
            ),
            HookEntry(
                event: HookDispatcher.eventPreToolUse,
                command: "off.sh",
                enabled: false
            ),
        ]
        try HookConfigStore.saveEntries(entries, projectRoot: root)

        let dir = try XCTUnwrap(HookDispatcher.projectHooksDir(projectRoot: root))
        let loaded = HookDispatcher.loadConfig(hooksDir: dir)
        XCTAssertEqual(loaded.pre.count, 1)
        XCTAssertEqual(loaded.pre[0].handlers.map(\.command), ["live.sh"])

        let roundTrip = HookConfigStore.loadEntries(projectRoot: root)
        XCTAssertEqual(roundTrip.count, 2)
        XCTAssertEqual(Set(roundTrip.map(\.command)), ["live.sh", "off.sh"])
        XCTAssertEqual(roundTrip.first(where: { $0.command == "off.sh" })?.enabled, false)
    }

    // MARK: - Unknown events / extra keys

    func testUnknownEventPreservedByStoreDroppedByDispatcher() throws {
        let url = HookConfigStore.configURL(projectRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let raw: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "setup.sh"]]]
                ],
                "CustomLocaleEvent": [
                    ["hooks": [["type": "command", "command": "i18n.sh"]]]
                ],
            ]
        ]
        try HookConfigStore.writePrettyJSON(raw, to: url)

        let stored = HookConfigStore.loadEntries(projectRoot: root)
        XCTAssertTrue(stored.contains { $0.event == "CustomLocaleEvent" && $0.command == "i18n.sh" })
        XCTAssertTrue(stored.contains { $0.event == HookDispatcher.eventSessionStart })

        let dir = try XCTUnwrap(HookDispatcher.projectHooksDir(projectRoot: root))
        let dispatched = HookDispatcher.loadConfig(hooksDir: dir)
        XCTAssertEqual(dispatched.sessionStart.count, 1)
        XCTAssertEqual(dispatched.pre.count, 0)
        XCTAssertEqual(dispatched.stop.count, 0)

        try HookConfigStore.save(HookConfigStore.config(from: stored), projectRoot: root)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let hooks = after?["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks?["CustomLocaleEvent"], "unknown event keys must survive HookConfigFile save")
        XCTAssertNotNil(hooks?["SessionStart"])
    }

    func testUnknownTopLevelKeysPreservedOnSave() throws {
        let url = HookConfigStore.configURL(projectRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let raw: [String: Any] = [
            "$schema": "https://example.invalid/hooks.schema.json",
            "version": 2,
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "done.sh"]]]
                ]
            ]
        ]
        try HookConfigStore.writePrettyJSON(raw, to: url)

        let entries = HookConfigStore.loadEntries(projectRoot: root)
        try HookConfigStore.saveEntries(entries, projectRoot: root)

        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(obj?["$schema"] as? String, "https://example.invalid/hooks.schema.json")
        XCTAssertEqual(obj?["version"] as? Int, 2)
        let hooks = obj?["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks?["Stop"])
    }

    // MARK: - Pretty print / paths

    func testPrettyPrintedOutputStable() throws {
        let entries = [
            HookEntry(
                event: HookDispatcher.eventUserPromptSubmit,
                command: "echo 'Hello from hook'",
                args: ["one"],
                timeoutSeconds: 7,
                background: false,
                enabled: true
            )
        ]
        try HookConfigStore.saveEntries(entries, projectRoot: root)
        let url = HookConfigStore.configURL(projectRoot: root)
        let first = try Data(contentsOf: url)
        try HookConfigStore.saveEntries(
            try HookConfigStore.decodeEntries(from: first),
            projectRoot: root
        )
        let second = try Data(contentsOf: url)
        XCTAssertEqual(first, second)

        let text = String(data: first, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\n"), text)
        XCTAssertTrue(text.contains("\"hooks\""), text)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: first))
    }

    func testSaveCreatesVibecoderHooksDir() throws {
        XCTAssertNil(HookDispatcher.projectHooksDir(projectRoot: root))
        try HookConfigStore.save(.empty, projectRoot: root)
        let dir = try XCTUnwrap(HookDispatcher.projectHooksDir(projectRoot: root))
        XCTAssertTrue(dir.path.hasSuffix(".vibecoder/hooks"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: HookConfigStore.configURL(projectRoot: root).path))
    }

    func testLoadNilProjectIsEmpty() {
        XCTAssertEqual(HookConfigStore.load(projectRoot: nil), .empty)
        XCTAssertTrue(HookConfigStore.loadEntries(projectRoot: nil).isEmpty)
    }

    func testSaveNilProjectThrows() {
        XCTAssertThrowsError(try HookConfigStore.save(.empty, projectRoot: nil)) { error in
            XCTAssertEqual(error as? HookConfigStoreError, .noProjectRoot)
        }
        XCTAssertThrowsError(try HookConfigStore.saveEntries([], projectRoot: nil)) { error in
            XCTAssertEqual(error as? HookConfigStoreError, .noProjectRoot)
        }
    }

    func testUserConfigURLIsHomeVibecoderHooksJSON() {
        let url = HookConfigStore.userConfigURL
        XCTAssertEqual(url.lastPathComponent, "hooks.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ".vibecoder")
        XCTAssertEqual(
            url.deletingLastPathComponent().deletingLastPathComponent().path,
            FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    func testExistingConfigJsonIsUpdatedInPlace() throws {
        let hooks = root.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let configURL = hooks.appendingPathComponent("config.json")
        try """
        { "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "old.sh" }] }] } }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(HookConfigStore.configURL(projectRoot: root), configURL)
        try HookConfigStore.saveEntries([
            HookEntry(event: HookDispatcher.eventStop, command: "new.sh")
        ], projectRoot: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: hooks.appendingPathComponent("hooks.json").path
            )
        )
        let loaded = HookDispatcher.loadConfig(hooksDir: hooks)
        XCTAssertEqual(loaded.stop.first?.handlers.first?.command, "new.sh")
    }

    // MARK: - Helpers

    private func assertPayloadEqual(_ lhs: HookEntry, _ rhs: HookEntry, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.event, rhs.event, file: file, line: line)
        XCTAssertEqual(lhs.matcher, rhs.matcher, file: file, line: line)
        XCTAssertEqual(lhs.command, rhs.command, file: file, line: line)
        XCTAssertEqual(lhs.args, rhs.args, file: file, line: line)
        XCTAssertEqual(lhs.timeoutSeconds, rhs.timeoutSeconds, file: file, line: line)
        XCTAssertEqual(lhs.background, rhs.background, file: file, line: line)
        XCTAssertEqual(lhs.enabled, rhs.enabled, file: file, line: line)
    }
}
