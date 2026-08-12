//
//  VisionWireEncodingTests.swift
//
//  Pins multimodal wire encoding so vision models receive image_url parts.
//

import XCTest
@testable import AgentCore

final class VisionWireEncodingTests: XCTestCase {

    func testTextOnlyWireContentIsString() throws {
        let msg = ChatMessage(role: .user, content: "hello")
        let wire = ChatCompletionRequestBody.WireMessage.from(msg)
        let data = try JSONEncoder().encode(wire)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["role"] as? String, "user")
        XCTAssertEqual(obj?["content"] as? String, "hello")
    }

    func testVisionWireContentIsPartsArray() throws {
        let image = ChatImagePayload(
            mimeType: "image/png",
            base64Data: "iVBORw0KGgo=",
            displayName: "shot.png"
        )
        let msg = ChatMessage(
            role: .user,
            content: "What is in this image?",
            images: [image]
        )
        let wire = ChatCompletionRequestBody.WireMessage.from(msg)
        let data = try JSONEncoder().encode(wire)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["role"] as? String, "user")
        let parts = obj?["content"] as? [[String: Any]]
        XCTAssertNotNil(parts, "content must be an array of parts for vision")
        XCTAssertEqual(parts?.count, 2)
        XCTAssertEqual(parts?[0]["type"] as? String, "text")
        XCTAssertEqual(parts?[0]["text"] as? String, "What is in this image?")
        XCTAssertEqual(parts?[1]["type"] as? String, "image_url")
        let imageURL = parts?[1]["image_url"] as? [String: Any]
        XCTAssertEqual(
            imageURL?["url"] as? String,
            "data:image/png;base64,iVBORw0KGgo="
        )
    }

    func testIsImagePathDetectsCommonExtensions() {
        XCTAssertTrue(VisionImageEncoder.isImagePath("/tmp/a.PNG"))
        XCTAssertTrue(VisionImageEncoder.isImagePath("~/shot.jpeg"))
        XCTAssertTrue(VisionImageEncoder.isImagePath("x.webp"))
        XCTAssertFalse(VisionImageEncoder.isImagePath("/tmp/a.swift"))
        XCTAssertFalse(VisionImageEncoder.isImagePath("/tmp/readme.md"))
    }

    func testComposeMultimodalEncodesImageAttachment() throws {
        // Write a tiny valid 1×1 PNG.
        let pngBase64 =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        guard let data = Data(base64Encoded: pngBase64) else {
            return XCTFail("bad fixture")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vision-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("dot.png").path
        try data.write(to: URL(fileURLWithPath: path))

        let composed = ContextAttachmentFormatter.composeMultimodal(
            text: "Describe this",
            attachments: [
                ContextAttachment(path: path, displayName: "dot.png", byteSize: data.count)
            ]
        )
        XCTAssertFalse(composed.images.isEmpty, "image attachment must become vision payload")
        XCTAssertTrue(composed.text.contains("Describe this"))
        XCTAssertTrue(composed.text.contains("Attached images for vision"))
        let mime = composed.images.first?.mimeType ?? ""
        XCTAssertTrue(
            mime == "image/png" || mime == "image/jpeg",
            "expected image mime, got \(mime)"
        )
    }
}

