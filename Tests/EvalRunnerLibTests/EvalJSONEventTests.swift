//
//  EvalJSONEventTests.swift
//  Phase B PB6 — pure JSONL event encoding + loop mapping.
//

import XCTest
import AgentCore
@testable import EvalRunnerLib

final class EvalJSONEventTests: XCTestCase {

    func testToolCallJSONLineShape() throws {
        let e = EvalJSONEvent.toolCall(
            id: "c1", name: "write_file", phase: .completed, isError: false)
        let line = try e.jsonLine()
        XCTAssertTrue(line.hasSuffix("\n"))
        let data = Data(line.dropLast().utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "tool_call")
        XCTAssertEqual(obj?["name"] as? String, "write_file")
        XCTAssertEqual(obj?["phase"] as? String, "completed")
        XCTAssertEqual(obj?["is_error"] as? Bool, false)
        XCTAssertEqual(obj?["id"] as? String, "c1")
    }

    func testTextAndDoneAndError() throws {
        let text = try EvalJSONEvent.text("hello").jsonLine()
        XCTAssertTrue(text.contains("\"type\":\"text\""))
        XCTAssertTrue(text.contains("hello"))

        let done = try EvalJSONEvent.done(
            reason: "stop", toolCalls: 2, messages: 4, ok: true
        ).jsonLine()
        XCTAssertTrue(done.contains("\"type\":\"done\""))
        XCTAssertTrue(done.contains("\"ok\":true"))
        XCTAssertTrue(done.contains("\"tool_calls\":2"))

        let err = try EvalJSONEvent.error("boom").jsonLine()
        XCTAssertTrue(err.contains("\"type\":\"error\""))
        XCTAssertTrue(err.contains("boom"))
    }

    func testFromLoopEventToolAndText() {
        let started = EvalJSONEvent.from(
            loopEvent: .toolStarted(id: "t1", name: "read_file", label: "Read"))
        XCTAssertEqual(started.count, 1)
        if case .toolCall(let id, let name, let phase, let isError) = started[0] {
            XCTAssertEqual(id, "t1")
            XCTAssertEqual(name, "read_file")
            XCTAssertEqual(phase, .started)
            XCTAssertFalse(isError)
        } else {
            XCTFail("expected toolCall")
        }

        let completed = EvalJSONEvent.from(
            loopEvent: .toolCompleted(id: "t1", name: "read_file", label: "Read", isError: true))
        if case .toolCall(_, _, let phase, let isError) = completed[0] {
            XCTAssertEqual(phase, .completed)
            XCTAssertTrue(isError)
        } else {
            XCTFail("expected completed toolCall")
        }

        let deltas = EvalJSONEvent.from(loopEvent: .contentDelta("hi"))
        XCTAssertEqual(deltas, [.text("hi")])
        XCTAssertTrue(EvalJSONEvent.from(loopEvent: .contentDelta("")).isEmpty)

        let errors = EvalJSONEvent.from(loopEvent: .error(description: "nope"))
        XCTAssertEqual(errors, [.error("nope")])

        // finished is deferred to runner for counts
        XCTAssertTrue(EvalJSONEvent.from(loopEvent: .finished(reason: "x")).isEmpty)
    }
}
