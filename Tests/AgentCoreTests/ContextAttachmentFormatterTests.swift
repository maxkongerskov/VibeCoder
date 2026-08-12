//
//  ContextAttachmentFormatterTests.swift
//

import XCTest
@testable import AgentCore

final class ContextAttachmentFormatterTests: XCTestCase {

    func testComposeUserMessagePrefixesAttachments() {
        let attachments = [
            ContextAttachment(path: "/tmp/Foo.swift", displayName: "Foo.swift", byteSize: 2048)
        ]
        let composed = ContextAttachmentFormatter.composeUserMessage(
            text: "Fix the bug",
            attachments: attachments
        )

        XCTAssertTrue(composed.hasPrefix("[Attached context files]"))
        XCTAssertTrue(composed.contains("@Foo.swift"))
        XCTAssertTrue(composed.contains("/tmp/Foo.swift"))
        XCTAssertTrue(composed.hasSuffix("Fix the bug"))
    }

    func testComposeUserMessageWithoutAttachmentsReturnsTextUnchanged() {
        let text = "Just a question"
        XCTAssertEqual(
            ContextAttachmentFormatter.composeUserMessage(text: text, attachments: []),
            text
        )
    }
}