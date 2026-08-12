//
//  InlineToolCallParserTests.swift  (AgentCore)
//
//  Regression suite for inline tool-call recovery in the app loop.
//

import XCTest
@testable import AgentCore

final class InlineToolCallParserTests: XCTestCase {

    private func args(_ call: ToolCallInvocation?) -> [String: Any] {
        guard let s = call?.arguments, let d = s.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return [:] }
        return dict
    }

    func testExtractsJSONArrayWithToolKeyAndFlatArgs() {
        let content = """
        [
          {"tool": "list_directory", "path": "."},
          {"tool": "glob_files", "pattern": "*.swift", "path": "Sources/AgentCore/Agent"}
        ]
        """
        let r = InlineToolCallParser.extract(from: content)
        XCTAssertEqual(r.calls.count, 2)
        XCTAssertEqual(r.calls[0].name, "list_directory")
        XCTAssertEqual(r.calls[1].name, "glob_files")
        XCTAssertEqual(args(r.calls[0])["path"] as? String, ".")
        XCTAssertEqual(args(r.calls[1])["pattern"] as? String, "*.swift")
        XCTAssertTrue(r.cleaned.isEmpty)
    }

    func testExtractsBareJSONWithToolKeyAndFlatArgs() {
        let content = #"{"tool": "list_directory", "path": "."}"#
        let r = InlineToolCallParser.extract(from: content)
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls.first?.name, "list_directory")
        XCTAssertEqual(args(r.calls.first)["path"] as? String, ".")
    }
}