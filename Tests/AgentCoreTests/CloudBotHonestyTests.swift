//
//  CloudBotHonestyTests.swift
//
//  Slice 0 — Mira honesty: CloudBots cannot read as local-first, and CI
//  does not phone home. Copy assertions for Settings/chrome live in App
//  SettingsDiscoverabilityCopyTests (Sable). Host stub: CloudBotHostTests
//  (Atlas).
//

import XCTest
@testable import AgentCore

final class CloudBotHonestyTests: XCTestCase {

    func testCloudBotsDecodeDefaultsOff() throws {
        let data = Data("{}".utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(settings.cloudBotsEnabled)
        XCTAssertFalse(AppSettings().cloudBotsEnabled)
    }

    func testCloudBotHostErrorCopyIsNotOnDevice() {
        let off = (CloudBotHostError.disabled.errorDescription ?? "").lowercased()
        XCTAssertFalse(off.contains("nothing leaves"))
        XCTAssertFalse(off.contains("on-device"))
        XCTAssertFalse(off.contains("on device"))
        XCTAssertFalse(off.contains("local-first"))
        XCTAssertTrue(off.contains("byo http") || off.contains("agentloop"))

        let stub = (CloudBotHostError.stubNotImplemented.errorDescription ?? "").lowercased()
        XCTAssertFalse(stub.contains("nothing leaves"))
        XCTAssertFalse(stub.contains("on-device"))
        XCTAssertFalse(stub.contains("on device"))
        XCTAssertFalse(stub.contains("local-first"))
        XCTAssertTrue(stub.contains("stub") || stub.contains("cloud"))
    }

    func testPRWorkflowHasNoCloudBotsPhoneHomeURL() throws {
        let text = try readRepoFile(".github/workflows/pr.yml")
        assertNoCloudBotsPhoneHome(in: text, file: "pr.yml")
    }

    func testCIPRScriptHasNoCloudBotsPhoneHomeURL() throws {
        let text = try readRepoFile("scripts/ci-pr.sh")
        assertNoCloudBotsPhoneHome(in: text, file: "ci-pr.sh")
        XCTAssertTrue(
            text.contains("127.0.0.1"),
            "ci-pr.sh mock evals must stay loopback")
    }

    // MARK: - helpers

    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir.deleteLastPathComponent()
            let pkg = dir.appendingPathComponent("Package.swift")
            let workflow = dir.appendingPathComponent(".github/workflows/pr.yml")
            if FileManager.default.fileExists(atPath: pkg.path),
               FileManager.default.fileExists(atPath: workflow.path) {
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

    /// Nash slice 0: pr.yml / ci-pr.sh do not contain a CloudBots telemetry
    /// endpoint. HTTP in these files must be loopback (mock evals).
    private func assertNoCloudBotsPhoneHome(in text: String, file: String) {
        let pattern = #"https?://[^\s"'`<>]+"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let urls = regex.matches(in: text, range: range).map { ns.substring(with: $0.range) }
        for url in urls {
            let lower = url.lowercased()
            XCTAssertFalse(
                lower.contains("cloudbot"),
                "\(file) CloudBots phone-home URL: \(url)")
            let host = lower
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            let isLoopback =
                host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost")
            XCTAssertTrue(
                isLoopback,
                "\(file) non-loopback HTTP (phone-home): \(url)")
        }
    }
}
