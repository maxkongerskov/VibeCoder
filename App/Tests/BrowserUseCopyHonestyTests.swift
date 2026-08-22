//
//  BrowserUseCopyHonestyTests.swift
//
//  Isolated this-Mac browser. Not CloudBots. Not RemoteControlServer.
//  Not desktop computer-use.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class BrowserUseCopyHonestyTests: XCTestCase {

    func testBrowserCopyIsThisMacNotCloudOrDesktopComputerUse() {
        let intro = BrowserUseCopy.intro.lowercased()
        XCTAssertTrue(intro.contains("this mac"))
        XCTAssertTrue(intro.contains("permission") || intro.contains("opt-in"))
        XCTAssertTrue(intro.contains("not a cloudbot") || intro.contains("not a cloud bot"))
        XCTAssertTrue(intro.contains("not phone") || intro.contains("not lan"))
        XCTAssertFalse(intro.contains("remotecontrolserver"))
        XCTAssertFalse(intro.contains("unattended"))
        XCTAssertFalse(intro.contains("nothing leaves"))
        XCTAssertFalse(AppSettings().browserUseEnabled)
        XCTAssertEqual(BrowserUseCopy.macLabel, "This Mac")
        let off = BrowserUseCopy.status(enabled: false).lowercased()
        XCTAssertTrue(off.contains("off") || off.contains("default"))
        XCTAssertTrue(off.contains("does not drive a browser") || off.contains("not drive"))
    }
}
