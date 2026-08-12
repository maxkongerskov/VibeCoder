import XCTest
@testable import AgentCore

final class AppSettingsSafeModeTests: XCTestCase {

    func testSafeModeConfigExpandsTildePaths() {
        var settings = AppSettings()
        settings.safeModeAllowedPaths = ["~/code/", "/var/tmp/"]
        settings.safeModeAllowedShellPrefixes = ["git", "swift build"]
        let config = settings.safeModeConfig()
        let home = NSHomeDirectory()
        let codeExpanded = ("~/code/" as NSString).expandingTildeInPath
        let tmpExpanded = ("/var/tmp/" as NSString).expandingTildeInPath
        XCTAssertTrue(config.allowedPathPrefixes.contains(codeExpanded))
        XCTAssertTrue(config.allowedPathPrefixes.contains(tmpExpanded))
        XCTAssertTrue(config.allowedPathPrefixes.contains(where: { $0.hasPrefix(home) }))
        XCTAssertFalse(config.allowedPathPrefixes.contains(where: { $0.contains("~") }))
        XCTAssertEqual(config.allowedPathPrefixes.count, 2)
        XCTAssertEqual(config.allowedShellPrefixes, ["git", "swift build"])
    }

    func testLegacySafeModeMigrationReadsInjectedDefaults() {
        let suite = "agentos.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        LegacySettingsMigration.seedPathsForTesting(["/custom/path/"], in: defaults)
        XCTAssertEqual(LegacySettingsMigration.migrateSafeModePaths(from: defaults), ["/custom/path/"])
    }
}