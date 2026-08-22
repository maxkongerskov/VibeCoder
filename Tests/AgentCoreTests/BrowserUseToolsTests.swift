//
//  BrowserUseToolsTests.swift
//
//  Isolated this-Mac browser tools: fail closed without a host, honor
//  SSRF, and drive an injected recording driver. Does not load WebKit.
//

import XCTest
@testable import AgentCore

final class BrowserUseToolsTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        BrowserUseRuntime.resetInstalled()
    }

    override func tearDown() async throws {
        BrowserUseRuntime.resetInstalled()
    }

    private func ctx() -> ToolContext {
        ToolContext(projectRoot: nil, conversationID: UUID())
    }

    private func args(_ json: String = "{}") throws -> ToolArguments {
        try ToolArguments(json: json)
    }

    func testToolsRegisteredAsThisMacNotCloudOrComputerUse() async throws {
        let names = await ToolRegistry.shared.registeredNames()
        for name in BrowserUseToolNames.all {
            XCTAssertTrue(names.contains(name), "missing \(name)")
            let meta = await ToolRegistry.shared.metadata(for: name)
            let desc = meta!.schema.description.lowercased()
            XCTAssertTrue(desc.contains("this-mac") || desc.contains("this mac"), name)
            XCTAssertTrue(desc.contains("not cloud"), name)
            XCTAssertFalse(desc.contains("remotecontrol"), name)
            XCTAssertFalse(desc.contains("marketplace"), name)
        }
        XCTAssertEqual(BrowserUseToolNames.all.count, 4)
    }

    func testNoDriverFailsClosedWithoutThrow() async throws {
        let result = try await BrowserNavigateTool().execute(
            arguments: try args(#"{"url":"https://example.com"}"#),
            context: ctx()
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("failed closed"))
        XCTAssertEqual(result.extras["cloud"], "false")
        XCTAssertEqual(result.extras["computer_use"], "false")
    }

    func testPrivateURLIsBlockedEvenWithDriver() async throws {
        let driver = RecordingBrowserUseDriver()
        let result = await BrowserUseRuntime.$driverOverride.withValue(driver) {
            try? await BrowserNavigateTool().execute(
                arguments: try! args(#"{"url":"http://127.0.0.1:8080"}"#),
                context: ctx()
            )
        }
        XCTAssertEqual(result?.isError, true)
        XCTAssertTrue(result!.content.lowercased().contains("private") || result!.content.lowercased().contains("refusing"))
        XCTAssertTrue(driver.navigated.isEmpty)
    }

    func testInjectedDriverNavigatesAndSnapshots() async throws {
        let driver = RecordingBrowserUseDriver()
        driver.title = "Example"
        driver.text = "Hello page"
        driver.clickable = "1. #go — Go"
        let nav = await BrowserUseRuntime.$driverOverride.withValue(driver) {
            try? await BrowserNavigateTool().execute(
                arguments: try! args(#"{"url":"https://example.com/x"}"#),
                context: ctx()
            )
        }
        XCTAssertEqual(nav?.isError, false)
        XCTAssertEqual(driver.navigated, ["https://example.com/x"])
        XCTAssertTrue(nav!.content.contains("this Mac"))

        let snap = await BrowserUseRuntime.$driverOverride.withValue(driver) {
            try? await BrowserSnapshotTool().execute(
                arguments: try! args(),
                context: ctx()
            )
        }
        XCTAssertEqual(snap?.isError, false)
        XCTAssertTrue(snap!.content.contains("Hello page"))
        XCTAssertTrue(snap!.content.contains("Example"))
        XCTAssertTrue(snap!.content.lowercased().contains("not computer-use"))

        let click = await BrowserUseRuntime.$driverOverride.withValue(driver) {
            try? await BrowserClickTool().execute(
                arguments: try! args("{\"selector\":\"#go\"}"),
                context: ctx()
            )
        }
        XCTAssertEqual(click?.isError, false)
        XCTAssertEqual(driver.clicks, ["#go"])

        let typed = await BrowserUseRuntime.$driverOverride.withValue(driver) {
            try? await BrowserTypeTool().execute(
                arguments: try! args("{\"selector\":\"#q\",\"text\":\"hi\"}"),
                context: ctx()
            )
        }
        XCTAssertEqual(typed?.isError, false)
        XCTAssertEqual(driver.typed.count, 1)
        XCTAssertEqual(driver.typed.first?.0, "#q")
        XCTAssertEqual(driver.typed.first?.1, "hi")
    }

    func testDefaultSettingsDisableBrowserAndComputerUseTools() {
        let settings = AppSettings()
        XCTAssertFalse(settings.computerUseEnabled)
        XCTAssertFalse(settings.browserUseEnabled)
        let disabled = AgentCapabilityGates.disabledToolNames(from: settings)
        XCTAssertTrue(ComputerUseToolNames.all.isSubset(of: disabled))
        XCTAssertTrue(BrowserUseToolNames.all.isSubset(of: disabled))
    }

    func testOptInRemovesCapabilityGate() {
        var settings = AppSettings()
        settings.computerUseEnabled = true
        settings.browserUseEnabled = true
        let disabled = AgentCapabilityGates.disabledToolNames(from: settings)
        XCTAssertTrue(ComputerUseToolNames.all.isDisjoint(with: disabled))
        XCTAssertTrue(BrowserUseToolNames.all.isDisjoint(with: disabled))
    }
}
