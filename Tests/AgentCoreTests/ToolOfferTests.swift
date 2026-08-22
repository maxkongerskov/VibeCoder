import XCTest
@testable import AgentCore

final class ToolOfferTests: XCTestCase {

    func testRecommendedIsSubsetOfCatalog() {
        XCTAssertTrue(
            ToolOffer.recommendedNames.isSubset(of: ToolOffer.catalogNames),
            "recommended extras: \(ToolOffer.recommendedNames.subtracting(ToolOffer.catalogNames).sorted())"
        )
        XCTAssertEqual(ToolOffer.recommendedNames.count, 18)
        XCTAssertTrue(ToolOffer.recommendedNames.contains("apply_patch"))
        XCTAssertTrue(ToolOffer.recommendedNames.contains("edit_file"))
        XCTAssertTrue(ToolOffer.recommendedNames.contains("tool_search"))
        XCTAssertFalse(ToolOffer.recommendedNames.contains("web_search"))
        XCTAssertFalse(ToolOffer.recommendedNames.contains("extract_pdf_text"))
        XCTAssertFalse(ToolOffer.recommendedNames.contains("task"))
    }

    func testEmptyMapUsesRecommendedDefaults() {
        XCTAssertTrue(ToolOffer.isEnabled(name: "read_file", explicit: [:]))
        XCTAssertTrue(ToolOffer.isEnabled(name: "git_commit", explicit: [:]))
        XCTAssertTrue(ToolOffer.isEnabled(name: "create_plan", explicit: [:]))
        XCTAssertTrue(ToolOffer.isEnabled(name: "apply_patch", explicit: [:]))
        XCTAssertTrue(ToolOffer.isEnabled(name: "edit_file", explicit: [:]))
        XCTAssertTrue(ToolOffer.isEnabled(name: "tool_search", explicit: [:]))
        XCTAssertFalse(ToolOffer.isEnabled(name: "extract_pdf_text", explicit: [:]))
        XCTAssertFalse(ToolOffer.isEnabled(name: "web_search", explicit: [:]))
        XCTAssertFalse(ToolOffer.isEnabled(name: "task", explicit: [:]))
        XCTAssertFalse(ToolOffer.isEnabled(name: "cron_create", explicit: [:]))
        XCTAssertFalse(ToolOffer.isEnabled(name: "screenshot", explicit: [:]))
    }

    func testExplicitOverrideWins() {
        XCTAssertFalse(ToolOffer.isEnabled(name: "read_file", explicit: ["read_file": false]))
        XCTAssertTrue(ToolOffer.isEnabled(name: "git_commit", explicit: ["git_commit": true]))
    }

    func testDisabledNamesDefaultOffExtrasOnly() {
        let disabled = ToolOffer.disabledNames(explicit: [:])
        XCTAssertFalse(disabled.contains("read_file"))
        XCTAssertFalse(disabled.contains("git_commit"))
        XCTAssertFalse(disabled.contains("create_plan"))
        XCTAssertFalse(disabled.contains("edit_file"))
        XCTAssertFalse(disabled.contains("apply_patch"))
        XCTAssertTrue(disabled.contains("monitor_jobs"))
        XCTAssertTrue(disabled.contains("web_search"))
        XCTAssertTrue(disabled.contains("extract_pdf_text"))
        XCTAssertTrue(disabled.contains("task"))
        XCTAssertEqual(disabled, ToolOffer.defaultOffNames)
    }

    func testMatchingTemplates() {
        XCTAssertEqual(
            ToolOffer.matchingTemplate(explicit: [:]),
            .recommended)
        let all = ToolOffer.enabledMap(template: .all)
        XCTAssertEqual(
            ToolOffer.matchingTemplate(explicit: all),
            .all)
        var custom = ToolOffer.enabledMap(template: .recommended)
        custom["fetch_rss"] = true
        XCTAssertNil(ToolOffer.matchingTemplate(explicit: custom))
    }

    func testCapabilityGatesDefaultHidesLongTail() {
        let settings = AppSettings()
        let disabled = AgentCapabilityGates.disabledToolNames(from: settings)
        XCTAssertFalse(disabled.contains("read_file"))
        XCTAssertFalse(disabled.contains("xcode_build"))
        XCTAssertFalse(disabled.contains("git_commit"))
        XCTAssertFalse(disabled.contains("edit_file"))
        XCTAssertFalse(disabled.contains("apply_patch"))
        XCTAssertTrue(disabled.contains("fetch_rss"))
        XCTAssertTrue(disabled.contains("web_search"))
        XCTAssertTrue(disabled.contains("task"))
        XCTAssertTrue(ComputerUseToolNames.all.isSubset(of: disabled))
        XCTAssertTrue(BrowserUseToolNames.all.isSubset(of: disabled))
    }

    func testAllTemplateStillHonorsComputerUseMasterSwitch() {
        var settings = AppSettings()
        settings.toolEnabled = ToolOffer.enabledMap(template: .all)
        XCTAssertTrue(
            ComputerUseToolNames.all.isSubset(
                of: AgentCapabilityGates.disabledToolNames(from: settings)))

        settings.computerUseEnabled = true
        settings.browserUseEnabled = true
        let on = AgentCapabilityGates.disabledToolNames(from: settings)
        XCTAssertTrue(ComputerUseToolNames.all.isDisjoint(with: on))
        XCTAssertTrue(BrowserUseToolNames.all.isDisjoint(with: on))
        XCTAssertFalse(on.contains("git_commit"))
    }
}
