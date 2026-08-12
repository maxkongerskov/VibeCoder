//
//  SettingsDiscoverabilityCopyTests.swift
//  Polish P2 — honest defaults visible in Settings copy.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class SettingsDiscoverabilityCopyTests: XCTestCase {

    func testAgentToolsCopyStatesDefaultOff() {
        let off = SettingsDiscoverabilityCopy.agentToolsStatus(enabled: false)
        XCTAssertTrue(off.lowercased().contains("default") || off.lowercased().contains("off"))
        XCTAssertTrue(off.lowercased().contains("proxy") || off.lowercased().contains("completions") || off.lowercased().contains("tools"))
        let on = SettingsDiscoverabilityCopy.agentToolsStatus(enabled: true)
        XCTAssertTrue(on.lowercased().contains("on"))
        XCTAssertTrue(on.lowercased().contains("loop") || on.lowercased().contains("capped") || on.lowercased().contains("tool"))
        XCTAssertFalse(on.lowercased().contains("full agent loop inside xcode"))
    }

    func testSeatbeltAutoIsDefaultWording() {
        let auto = SettingsDiscoverabilityCopy.seatbeltCurrent(.auto)
        XCTAssertTrue(auto.lowercased().contains("default") || auto.lowercased().contains("auto"))
        XCTAssertTrue(SettingsDiscoverabilityCopy.seatbeltIntro.lowercased().contains("auto"))
    }

    func testGrantsCopyNotConfusedWithSeatbelt() {
        let intro = SettingsDiscoverabilityCopy.grantsIntro.lowercased()
        XCTAssertTrue(intro.contains("always") || intro.contains("never") || intro.contains("grant"))
        XCTAssertTrue(intro.contains("seatbelt") || intro.contains("permission") || intro.contains("safe mode"))
    }

    func testLocalAPIIntroDoesNotClaimAgentLoopInXcode() {
        let s = SettingsDiscoverabilityCopy.localAPIIntro.lowercased()
        XCTAssertTrue(s.contains("proxy") || s.contains("completions") || s.contains("loopback"))
        XCTAssertFalse(s.contains("cursor-level"))
        XCTAssertFalse(s.contains("full agentic"))
    }
}
