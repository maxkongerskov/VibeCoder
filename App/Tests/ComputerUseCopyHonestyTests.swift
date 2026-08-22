//
//  ComputerUseCopyHonestyTests.swift
//
//  Slice 1 — Mira honesty (App copy). Computer-use is controlling this Mac
//  with permission each time. Not CloudBots. Not RemoteControlServer.
//  Does not duplicate Sable's SettingsDiscoverability ComputerUseCopy tests.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class ComputerUseCopyHonestyTests: XCTestCase {

    func testCloudBotCopyIsNotComputerUseOnThisMac() {
        let strings = [
            CloudBotCopy.intro,
            CloudBotCopy.honesty,
            CloudBotCopy.privacyBlurb,
            CloudBotCopy.chipHelp,
            CloudBotCopy.chipAccessibility,
            CloudBotCopy.status(enabled: false),
            CloudBotCopy.status(enabled: true),
        ]
        for raw in strings {
            let lower = raw.lowercased()
            XCTAssertFalse(
                lower.contains("screenshot of the desktop"),
                "CloudBots copy must not claim desktop screenshot: \(raw)")
            XCTAssertFalse(
                lower.contains("click, type, scroll"),
                "CloudBots copy must not claim click/type/scroll: \(raw)")
            XCTAssertFalse(
                lower.contains("computer-use") || lower.contains("computer use"),
                "CloudBots copy is cloud, not computer-use: \(raw)")
        }
        XCTAssertEqual(CloudBotCopy.cloudLabel, "Cloud")
        XCTAssertNotEqual(ComputerUseCopy.macLabel, CloudBotCopy.cloudLabel)
        XCTAssertFalse(AppSettings().cloudBotsEnabled)
    }

    func testComputerUseCopyRequiresPermissionAndIsThisMacNotLANRemote() {
        let intro = ComputerUseCopy.intro.lowercased()
        XCTAssertTrue(intro.contains("this mac"))
        XCTAssertTrue(intro.contains("permission"))
        XCTAssertTrue(intro.contains("not cloud"))
        XCTAssertTrue(intro.contains("not a cloudbot") || intro.contains("not a cloud bot"))
        XCTAssertTrue(intro.contains("not phone") || intro.contains("not lan"))
        XCTAssertFalse(intro.contains("remotecontrolserver"))
        XCTAssertFalse(intro.contains("unattended"))
        XCTAssertFalse(intro.contains("nothing leaves"))

        let on = ComputerUseCopy.status(enabled: true).lowercased()
        XCTAssertTrue(on.contains("this mac"))
        XCTAssertTrue(on.contains("permission"))
        XCTAssertFalse(on.contains("cloudbot"))
        XCTAssertFalse(on.contains("remotecontrol"))

        let off = ComputerUseCopy.status(enabled: false).lowercased()
        XCTAssertTrue(off.contains("off") || off.contains("default"))
        XCTAssertTrue(
            off.contains("does not screenshot") || off.contains("not screenshot"),
            "denied/off must not click or screenshot: \(off)")
        XCTAssertFalse(AppSettings().computerUseEnabled)

        XCTAssertEqual(ComputerUseCopy.macLabel, "This Mac")
        XCTAssertFalse(
            ComputerUseCopy.chipHelp.lowercased().contains("remotecontrol"))
        XCTAssertFalse(
            ComputerUseCopy.honesty.lowercased().contains("remotecontrolserver"))
    }

    func testCatalogDoesNotAdvertiseComputerUseToolsWithoutRegisteringThem() {
        let slice = ["screenshot", "click", "type", "scroll"]
        for name in slice {
            let inSettings = BuiltinToolCatalog.settingsNames.contains(name)
            let inRegistered = BuiltinToolCatalog.registeredBuiltinNames.contains(name)
            if inSettings {
                XCTAssertTrue(
                    inRegistered,
                    "Settings lists \(name) but AgentCore catalog set does not — would claim it ships")
            }
        }
    }

    func testSettingsCopyCannotClaimComputerUseShipsWithoutPermission() throws {
        let files = try copySources()
        XCTAssertFalse(files.isEmpty, "expected App copy sources")
        for (path, text) in files {
            assertHonestComputerUseCopy(in: text, file: path)
        }
    }

    // MARK: - helpers

    private func assertHonestComputerUseCopy(in text: String, file: String) {
        let lower = text.lowercased()
        let talksComputerUse =
            lower.contains("computer-use")
            || lower.contains("computer use")
            || lower.contains("screenshot, click")
        guard talksComputerUse else { return }

        XCTAssertTrue(
            lower.contains("permission"),
            "\(file) talks computer-use without permission")
        XCTAssertTrue(
            lower.contains("this mac"),
            "\(file) computer-use copy must be this Mac, not cloud/LAN")
        XCTAssertFalse(
            lower.contains("unattended"),
            "\(file) must not claim unattended computer-use")
        XCTAssertFalse(
            lower.contains("remotecontrolserver"),
            "\(file) must not label computer-use as RemoteControlServer")
    }

    private func copySources() throws -> [(String, String)] {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent() // Tests
        dir.deleteLastPathComponent() // App
        let utilities = dir.appendingPathComponent("Utilities")
        var out: [(String, String)] = []
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: utilities,
            includingPropertiesForKeys: nil) else { return out }
        for url in items where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            out.append((url.lastPathComponent, text))
        }
        return out
    }
}
