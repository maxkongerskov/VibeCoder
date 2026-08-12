//
//  ResponseNormalizerTests.swift
//

import XCTest
@testable import AgentCore

final class ResponseNormalizerTests: XCTestCase {

    func testResentFullNameDoesNotDuplicate() {
        var acc = ResponseNormalizer.Accumulator()
        acc.ingestToolCallDelta(index: 0, id: "c1", name: "read_file", argumentsAppend: "{}")
        acc.ingestToolCallDelta(index: 0, id: nil, name: "read_file", argumentsAppend: nil)
        let result = acc.finalize()
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].name, "read_file")
    }

    func testFragmentedNameAndArgumentsAppend() {
        var acc = ResponseNormalizer.Accumulator()
        acc.ingestToolCallDelta(index: 0, id: "c1", name: "read_", argumentsAppend: #"{"path":""#)
        acc.ingestToolCallDelta(index: 0, id: nil, name: "file", argumentsAppend: #"a"}"#)
        let result = acc.finalize()
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].name, "read_file")
        XCTAssertEqual(result.toolCalls[0].id, "c1")
        XCTAssertEqual(result.toolCalls[0].arguments, #"{"path":"a"}"#)
    }

}