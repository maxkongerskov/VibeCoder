//
//  ModelChromeTests.swift
//

import XCTest
@testable import AgentCore

final class ModelChromeTests: XCTestCase {

    func testDisabledIsIdentity() {
        let raw = "<|channel|>thought\nsecret\n<|channel|>final\nHello"
        let p = ModelChrome.present(raw, enabled: false)
        XCTAssertNil(p.thinking)
        XCTAssertEqual(p.body, raw)
    }

    func testChannelThoughtAndFinal() {
        let raw = """
        <|channel|>thought
        I should list folders.
        <|channel|>final
        Here are the folders:
        - VibeCoder
        """
        let p = ModelChrome.present(raw, enabled: true)
        XCTAssertEqual(p.thinking, "I should list folders.")
        XCTAssertTrue(p.body.contains("Here are the folders"))
        XCTAssertTrue(p.body.contains("VibeCoder"))
        XCTAssertFalse(p.body.contains("channel"))
        XCTAssertFalse(p.body.contains("I should list"))
    }

    func testBareChannelMarker() {
        let raw = "<channel|>Here are the folders:\n- A"
        let p = ModelChrome.present(raw, enabled: true)
        XCTAssertTrue(p.body.hasPrefix("Here are the folders"))
        XCTAssertFalse(p.body.contains("<channel"))
    }

    func testCleanModelPassThrough() {
        let raw = "Here are the folders:\n- VibeCoder\n- Notes"
        let p = ModelChrome.present(raw, enabled: true)
        XCTAssertNil(p.thinking)
        XCTAssertEqual(p.body, raw)
    }

    func testDisplayBodyForSidebar() {
        let raw = "<|channel|>thought\nx\n<|channel|>final\nHello world"
        XCTAssertEqual(ModelChrome.displayBody(raw, enabled: true), "Hello world")
        XCTAssertTrue(ModelChrome.displayBody(raw, enabled: false).contains("channel"))
    }

    func testThinkTagsStillWork() {
        let raw = "<think>plan</think>\nAnswer here"
        let p = ModelChrome.present(raw, enabled: true)
        XCTAssertEqual(p.thinking, "plan")
        XCTAssertEqual(p.body, "Answer here")
    }
}
