//
//  PC2SettingsTogglesTests.swift
//  Settings toggles: seatbelt preference + LocalAPI agentTools defaults.
//

import XCTest
@testable import AgentCore

final class PC2SettingsTogglesTests: XCTestCase {

    func testDefaultsAreHonest() {
        let s = AppSettings()
        XCTAssertFalse(s.localAPIAgentToolsEnabled,
                       "LocalAPI agent tools must default off (PB7/PC2 honesty)")
        XCTAssertEqual(s.shellSeatbeltPreference, .auto,
                       "Seatbelt default is Auto-mode behavior (PB8)")
    }

    func testSeatbeltEnvironmentValueMapping() {
        XCTAssertNil(ShellSeatbeltPreference.auto.environmentValue)
        XCTAssertEqual(ShellSeatbeltPreference.always.environmentValue, "1")
        XCTAssertEqual(ShellSeatbeltPreference.never.environmentValue, "0")
    }

    func testSeatbeltAlwaysMatchesSafeBashEnvOn() {
        var env = ProcessInfo.processInfo.environment
        env["VIBECODER_SHELL_SEATBELT"] = ShellSeatbeltPreference.always.environmentValue!
        XCTAssertTrue(SafeBash.isSeatbeltEnabled(environment: env, executionMode: .yolo))
        XCTAssertTrue(SafeBash.isSeatbeltEnabled(environment: env, executionMode: .plan))
    }

    func testSeatbeltNeverMatchesSafeBashEnvOff() {
        var env = ProcessInfo.processInfo.environment
        env["VIBECODER_SHELL_SEATBELT"] = ShellSeatbeltPreference.never.environmentValue!
        XCTAssertFalse(SafeBash.isSeatbeltEnabled(environment: env, executionMode: .edit))
    }

    func testSeatbeltAutoLeavesModeDefault() {
        // Unset env → Auto only (edit) enables seatbelt.
        let env: [String: String] = [:]
        XCTAssertTrue(SafeBash.isSeatbeltEnabled(environment: env, executionMode: .edit))
        XCTAssertFalse(SafeBash.isSeatbeltEnabled(environment: env, executionMode: .yolo))
    }

    func testAppSettingsRoundTripNewFields() throws {
        var s = AppSettings()
        s.localAPIAgentToolsEnabled = true
        s.shellSeatbeltPreference = .always
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.localAPIAgentToolsEnabled)
        XCTAssertEqual(decoded.shellSeatbeltPreference, .always)
    }

    func testAppSettingsMissingKeysDefault() throws {
        // Minimal JSON without PC2 keys still decodes with honest defaults.
        let json = """
        {
          "backend": "ollama",
          "localAPIEnabled": false,
          "localAPIPort": 11435
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.localAPIAgentToolsEnabled)
        XCTAssertEqual(decoded.shellSeatbeltPreference, .auto)
        XCTAssertFalse(decoded.computerUseEnabled)
        XCTAssertFalse(decoded.browserUseEnabled)
    }

    func testLocalAPICompletionToolsProxyHelperEmptyInBothModes() async {
        // D1: opt-in runs AgentLoop; proxy helper never attaches schemas.
        let off = await LocalAPIServer.completionTools(agentToolsEnabled: false)
        XCTAssertTrue(off.isEmpty)
        await ToolRegistry.shared.registerBuiltins()
        let on = await LocalAPIServer.completionTools(agentToolsEnabled: true)
        XCTAssertTrue(on.isEmpty, "agent-loop mode loads tools inside AgentLoop")
        XCTAssertEqual(ServeToolsPolicy.resolve(agentToolsEnabled: true), .agentLoop)
    }
}
