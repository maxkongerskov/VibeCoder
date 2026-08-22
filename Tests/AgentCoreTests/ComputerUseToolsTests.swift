//
//  ComputerUseToolsTests.swift
//
//  Slice 1: screenshot/click/type/scroll exist, labeled this-Mac, fail
//  closed without TCC. Does not click the real display in CI.
//

import XCTest
import CoreGraphics
@testable import AgentCore

final class ComputerUseToolsTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
    }

    private func ctx() -> ToolContext {
        ToolContext(projectRoot: nil, conversationID: UUID())
    }

    private func args(_ json: String = "{}") throws -> ToolArguments {
        try ToolArguments(json: json)
    }

    func testToolsRegisteredAsThisMacNotCloud() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let names = await ToolRegistry.shared.registeredNames()
        for name in ["screenshot", "click", "type", "scroll"] {
            XCTAssertTrue(names.contains(name), "missing tool \(name)")
            let meta = await ToolRegistry.shared.metadata(for: name)
            XCTAssertNotNil(meta)
            let desc = meta!.schema.description.lowercased()
            XCTAssertTrue(desc.contains("this mac"))
            XCTAssertTrue(desc.contains("not cloud"))
            XCTAssertFalse(desc.contains("marketplace"))
            XCTAssertFalse(desc.contains("remotecontrol"))
        }
    }

    func testDeniedScreenRecordingFailsClosedWithoutThrow() async throws {
        let result = await ComputerUseRuntime.$permissionOverride.withValue(.denied) {
            await ComputerUseRuntime.$driverOverride.withValue(RecordingComputerUseDriver()) {
                try? await ScreenshotTool().execute(arguments: try! args(), context: ctx())
            }
        }
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.isError)
        XCTAssertTrue(result!.content.lowercased().contains("screen recording"))
        XCTAssertEqual(result!.extras["kind"], "this-mac")
        XCTAssertEqual(result!.extras["cloud"], "false")
    }

    func testDeniedAccessibilityFailsClosedForPointerTools() async throws {
        let tools: [(String, any Tool, String)] = [
            ("click", ClickTool(), #"{"x":1,"y":1}"#),
            ("type", TypeTool(), #"{"text":"hi"}"#),
            ("scroll", ScrollTool(), "{}")
        ]
        for (name, tool, json) in tools {
            let result = await ComputerUseRuntime.$permissionOverride.withValue(.denied) {
                await ComputerUseRuntime.$driverOverride.withValue(RecordingComputerUseDriver()) {
                    try? await tool.execute(arguments: try! args(json), context: ctx())
                }
            }
            XCTAssertNotNil(result, name)
            XCTAssertTrue(result!.isError, name)
            XCTAssertTrue(
                result!.content.lowercased().contains("accessibility"),
                "\(name): \(result!.content)")
            XCTAssertEqual(result!.extras["kind"], "this-mac", name)
        }
    }

    func testGrantedUsesInjectedDriverNotMarketplace() async throws {
        let granted = ComputerUsePermissionSnapshot(screenRecording: true, accessibility: true)
        let shot = await ComputerUseRuntime.$permissionOverride.withValue(granted) {
            await ComputerUseRuntime.$driverOverride.withValue(RecordingComputerUseDriver()) {
                try? await ScreenshotTool().execute(arguments: try! args(), context: ctx())
            }
        }
        XCTAssertEqual(shot?.isError, false)
        XCTAssertTrue(shot?.content.contains("this Mac") == true)
        XCTAssertFalse(shot!.content.lowercased().contains("marketplace"))
        XCTAssertFalse(
            shot!.content.contains("png_base64"),
            "pixels must ride ChatImagePayload, not inline base64 text")
        XCTAssertEqual(shot?.images.count, 1)
        XCTAssertEqual(shot?.images.first?.mimeType, "image/png")
        XCTAssertFalse(shot!.images.first!.base64Data.isEmpty)
        XCTAssertEqual(shot?.extras["vision"], "true")
        let wire = ChatMessage.toolResult(shot!, callID: "shot-1")
        XCTAssertEqual(wire.images.count, 1)
        let encoded = ChatCompletionRequestBody.WireMessage.from(wire)
        if case .parts(let parts) = encoded.content {
            XCTAssertTrue(parts.contains(where: { $0.type == "image_url" }))
        } else {
            XCTFail("tool screenshot must encode as vision parts, got \(encoded.content)")
        }

        let click = await ComputerUseRuntime.$permissionOverride.withValue(granted) {
            await ComputerUseRuntime.$driverOverride.withValue(RecordingComputerUseDriver()) {
                try? await ClickTool().execute(arguments: try! args(#"{"x":10,"y":20}"#), context: ctx())
            }
        }
        XCTAssertEqual(click?.isError, false)

        let typed = await ComputerUseRuntime.$permissionOverride.withValue(granted) {
            await ComputerUseRuntime.$driverOverride.withValue(RecordingComputerUseDriver()) {
                try? await TypeTool().execute(arguments: try! args(#"{"text":"hello"}"#), context: ctx())
            }
        }
        XCTAssertEqual(typed?.isError, false)

        let scroll = await ComputerUseRuntime.$permissionOverride.withValue(granted) {
            await ComputerUseRuntime.$driverOverride.withValue(RecordingComputerUseDriver()) {
                try? await ScrollTool().execute(arguments: try! args("{}"), context: ctx())
            }
        }
        XCTAssertEqual(scroll?.isError, false)
    }

    func testRemoteControlStillOffAndNoMarketplaceURL() {
        XCTAssertFalse(RemoteControlServer.isEnabled)
        let files = [
            "Sources/AgentCore/ComputerUse/ComputerUseTools.swift",
            "Sources/AgentCore/ComputerUse/ComputerUsePermissions.swift"
        ]
        let root = repoRoot()
        for rel in files {
            let text = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            XCTAssertNotNil(text, rel)
            let lower = text!.lowercased()
            XCTAssertFalse(lower.contains("marketplace"))
            XCTAssertFalse(lower.contains("http://store"))
            XCTAssertFalse(RemoteControlServer.isEnabled)
        }
    }

    func testKindConstantIsThisMac() {
        XCTAssertEqual(ComputerUseTCC.kind, .thisMac)
        XCTAssertEqual(ComputerUseKind.thisMac.rawValue, "this-mac")
    }

    func testClickMapsImagePixelsToDisplayPixels() async throws {
        let driver = MappingComputerUseDriver()
        let granted = ComputerUsePermissionSnapshot(screenRecording: true, accessibility: true)
        let cap = ComputerUseCapture(
            displayWidth: 200,
            displayHeight: 100,
            imageWidth: 100,
            imageHeight: 50,
            mimeType: "image/png",
            base64Data: ComputerUseCapture.fixturePNGBase64
        )
        let click = await ComputerUseRuntime.$permissionOverride.withValue(granted) {
            await ComputerUseRuntime.$driverOverride.withValue(driver) {
                await ComputerUseRuntime.$lastCaptureOverride.withValue(cap) {
                    try? await ClickTool().execute(
                        arguments: try! args(#"{"x":10,"y":10}"#),
                        context: ctx()
                    )
                }
            }
        }
        XCTAssertEqual(click?.isError, false)
        XCTAssertEqual(driver.lastClick?.0, 20)
        XCTAssertEqual(driver.lastClick?.1, 20)
        XCTAssertTrue(click!.content.contains("image=(10, 10)"))
        XCTAssertTrue(click!.content.contains("display=(20, 20)"))
    }

    func testLiveEncoderProducesPixelsFromCGImage() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel: [UInt8] = [255, 0, 0, 255]
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage() else {
            return XCTFail("could not make 1×1 CGImage")
        }
        let payload = VisionImageEncoder.payload(
            fromCGImage: image,
            displayName: "dot.jpg",
            maxLongEdge: 1280,
            preferJPEG: true
        )
        XCTAssertNotNil(payload)
        XCTAssertFalse(payload!.base64Data.isEmpty)
        XCTAssertTrue(payload!.mimeType == "image/jpeg" || payload!.mimeType == "image/png")
    }

    private func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir.deleteLastPathComponent()
            let pkg = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) {
                return dir
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

final class MappingComputerUseDriver: ComputerUseDriver, @unchecked Sendable {
    var lastClick: (Int, Int)?

    func screenshot() throws -> ComputerUseCapture {
        ComputerUseCapture(
            displayWidth: 200,
            displayHeight: 100,
            imageWidth: 100,
            imageHeight: 50,
            mimeType: "image/png",
            base64Data: ComputerUseCapture.fixturePNGBase64
        )
    }

    func click(x: Int, y: Int, button: String) throws {
        lastClick = (x, y)
    }

    func typeText(_ text: String) throws {}
    func scroll(x: Int, y: Int, deltaX: Int, deltaY: Int) throws {}
}
