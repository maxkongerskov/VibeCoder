//
//  ComputerUseHonestyTests.swift
//
//  Slice 1 — Mira honesty: computer-use is this Mac + permission each time,
//  not CloudBots, not LAN RemoteControlServer. Tests do not invent screenshot
//  or mouse APIs. If those tools are unregistered, copy must not claim they
//  ship without permission.
//

import XCTest
@testable import AgentCore

final class ComputerUseHonestyTests: XCTestCase {

    /// Desktop screenshot / click / type / scroll — not `ocr_image`.
    private func isComputerUseToolName(_ name: String) -> Bool {
        let n = name.lowercased()
        let slice = Set(["screenshot", "click", "type", "scroll"])
        if slice.contains(n) { return true }
        if n.contains("ocr") { return false }
        if n.contains("computer_use") || n.contains("computer-use") { return true }
        if n.contains("screenshot") { return true }
        return false
    }

    func testRemoteControlServerStaysOffAndIsNotComputerUse() async throws {
        XCTAssertFalse(
            RemoteControlServer.isEnabled,
            "LAN RemoteControlServer must stay OFF; computer-use is this Mac, not phone/LAN remote")
        do {
            _ = try await RemoteControlServer.shared.start()
            XCTFail("start() must throw .disabled (no bind, no session URL)")
        } catch let error as RemoteControlServer.ServerError {
            XCTAssertEqual(error, .disabled)
        }
        let off = (RemoteControlServer.ServerError.disabled.errorDescription ?? "").lowercased()
        XCTAssertTrue(off.contains("off") || off.contains("disabled") || off.contains("turned off"))
        XCTAssertFalse(off.contains("screenshot"))
        XCTAssertFalse(off.contains("computer-use"))
    }

    func testRegisteredBuiltinsDoNotShipComputerUseWithoutPermission() async {
        await ToolRegistry.shared.registerBuiltins()
        let live = await ToolRegistry.shared.registeredNames()
        let hits = live.filter { isComputerUseToolName($0) }.sorted()

        if hits.isEmpty {
            XCTAssertFalse(live.contains("screenshot"))
            XCTAssertFalse(live.contains("computer_use"))
            return
        }

        for name in hits {
            let readOnly = await ToolRegistry.shared.isReadOnlyTool(name)
            XCTAssertFalse(
                readOnly,
                "\(name) must not auto-approve as read-only (permission each time; deny = no click/type)")
            let meta = await ToolRegistry.shared.metadata(for: name)
            XCTAssertNotNil(meta, "\(name) registered without metadata")
            guard let meta else { continue }
            XCTAssertNotEqual(
                meta.permission,
                .readOnly,
                "\(name) computer-use must require permission, not readOnly")
            let desc = meta.schema.description.lowercased()
            XCTAssertFalse(desc.contains("unattended"), "\(name) must not claim unattended control")
            XCTAssertFalse(desc.contains("cloudbot"), "\(name) is this Mac, not a CloudBot path")
            XCTAssertFalse(desc.contains("remotecontrol"), "\(name) is not RemoteControlServer")
            let needsPermission =
                desc.contains("permission") || desc.contains("ask") || desc.contains("approv")
            XCTAssertTrue(
                needsPermission,
                "\(name) schema must say user permission is required: \(meta.schema.description)")
        }
    }

    func testArchitectureV2SliceRequiresPermissionNotCloudOrLANRemote() throws {
        let text = try readRepoFile("ARCHITECTURE-v2.md")
        let lower = text.lowercased()
        XCTAssertTrue(lower.contains("computer-use"))
        XCTAssertTrue(lower.contains("permission"))
        XCTAssertTrue(lower.contains("this mac"))
        XCTAssertTrue(lower.contains("not cloud"))
        XCTAssertTrue(lower.contains("remotecontrolserver"))
        XCTAssertTrue(lower.contains("off"))
        XCTAssertTrue(lower.contains("not a cloudbot"))
    }

    func testSettingsCatalogDoesNotListUnregisteredComputerUseTools() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let live = await ToolRegistry.shared.registeredNames()
        let liveHits = live.filter { isComputerUseToolName($0) }
        let catalog = try readRepoFile("App/Views/Settings/ToolsSettingsView.swift")
        var catalogHits: [String] = []
        for line in catalog.split(separator: "\n") {
            let s = String(line)
            guard s.contains(".init(name:") else { continue }
            let name = extractQuotedName(from: s)
            if isComputerUseToolName(name) {
                catalogHits.append(name)
            }
        }
        if liveHits.isEmpty {
            XCTAssertTrue(
                catalogHits.isEmpty,
                "Settings lists computer-use tools that AgentCore does not register: \(catalogHits)")
        } else {
            for name in catalogHits {
                XCTAssertTrue(
                    liveHits.contains(name),
                    "Settings lists \(name) but it is not in ToolRegistry")
            }
        }
    }

    // MARK: - helpers

    private func extractQuotedName(from line: String) -> String {
        guard let start = line.range(of: "\""),
              let end = line[start.upperBound...].range(of: "\"") else { return "" }
        return String(line[start.upperBound..<end.lowerBound])
    }

    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir.deleteLastPathComponent()
            let pkg = dir.appendingPathComponent("Package.swift")
            let v2 = dir.appendingPathComponent("ARCHITECTURE-v2.md")
            if FileManager.default.fileExists(atPath: pkg.path),
               FileManager.default.fileExists(atPath: v2.path) {
                return dir
            }
        }
        XCTFail("repo root not found from \(#filePath)")
        struct RootNotFound: Error {}
        throw RootNotFound()
    }

    private func readRepoFile(_ relative: String) throws -> String {
        let url = try repoRoot().appendingPathComponent(relative)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "missing \(relative)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
