//
//  TodoMCPGroupingTests.swift
//
//  Grouping lock: TodoWrite/TodoRead/update_todo and namespaced MCP
//  (`server__tool`) must not collapse into Explore. MCP is its own card.
//  Copy is already characterized by Sable (SettingsDiscoverabilityCopyTests);
//  this file does not restyle or re-assert that chrome.
//  Product is VibeCoder. Looks like ZCode grouping. Not ZCode. Not Electron.
//  Does not stamp 99%.
//

import XCTest
@testable import AgentCore
@testable import VibeCoderApp

final class TodoMCPGroupingTests: XCTestCase {

    func testTodoWriteAndTodoReadAreTodoCardsNotExplore() {
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "update_todo"), .todo)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "TodoWrite"), .todo)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "TodoRead"), .todo)
        XCTAssertFalse(ToolCallGrouping.isExploreMember(.todo))

        let events = [
            ToolCallEvent(name: "grep_code"),
            ToolCallEvent(name: "TodoWrite", todoSummary: "ship cards"),
            ToolCallEvent(name: "TodoRead"),
            ToolCallEvent(name: "read_file"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 4, "todo tools must not merge into Explore or each other")
        guard case .explore = groups[0] else { return XCTFail("search is explore") }
        guard case .todo(let write) = groups[1] else { return XCTFail("TodoWrite is a todo card") }
        XCTAssertEqual(write.toolName, "TodoWrite")
        XCTAssertEqual(write.summary, "ship cards")
        guard case .todo(let read) = groups[2] else { return XCTFail("TodoRead is its own todo card") }
        XCTAssertEqual(read.toolName, "TodoRead")
        guard case .explore(let counts, _) = groups[3] else {
            return XCTFail("read after todo is a new explore, not the same burst")
        }
        XCTAssertEqual(counts.files, 1)
        XCTAssertEqual(counts.searches, 0)
    }

    func testNamespacedMCPIsOwnCardAndDoesNotCollapseIntoExplore() {
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "github__list_issues"), .mcp)
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "node_repl__js_eval"), .mcp)
        XCTAssertFalse(ToolCallGrouping.isExploreMember(.mcp))

        let events = [
            ToolCallEvent(name: "list_directory"),
            ToolCallEvent(name: "github__list_issues", mcpParameters: "{}"),
            ToolCallEvent(name: "github__get_issue", mcpParameters: "{\"n\":1}"),
            ToolCallEvent(name: "read_file"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 4, "MCP tools stay their own cards; consecutive MCP does not merge")
        guard case .explore = groups[0] else { return XCTFail("list is explore") }
        guard case .mcp(let a) = groups[1] else { return XCTFail("first MCP is an mcp card") }
        XCTAssertEqual(a.toolName, "github__list_issues")
        XCTAssertEqual(a.serverName, "github")
        guard case .mcp(let b) = groups[2] else { return XCTFail("second MCP is a separate mcp card") }
        XCTAssertEqual(b.toolName, "github__get_issue")
        guard case .explore(let counts, _) = groups[3] else {
            return XCTFail("read after MCP is a new explore")
        }
        XCTAssertEqual(counts.files, 1)
    }

    func testTodoThenMCPThenSearchStayThreeFamilies() {
        let groups = ToolCallGrouping.group([
            ToolCallEvent(name: "update_todo", todoSummary: "next"),
            ToolCallEvent(name: "github__create_issue"),
            ToolCallEvent(name: "grep_code"),
        ])
        XCTAssertEqual(groups.count, 3)
        guard case .todo = groups[0] else { return XCTFail("todo card") }
        guard case .mcp(let mcp) = groups[1] else { return XCTFail("mcp is its own card") }
        XCTAssertEqual(mcp.serverName, "github")
        guard case .explore(let counts, _) = groups[2] else { return XCTFail("search is explore") }
        XCTAssertEqual(counts.searches, 1)
        XCTAssertEqual(counts.files, 0)
    }

    func testChatStackPaintsTodoAndMCPAsOwnRowsNotExplore() throws {
        let src = try appSource("Views/Chat/ZCodeActivityLineView.swift")
        XCTAssertTrue(src.contains("case .todo(let card):"))
        XCTAssertTrue(src.contains("items.append(.todo(card))"))
        XCTAssertTrue(src.contains("todoRow(card)"))
        XCTAssertTrue(src.contains("case .mcp(let card):"))
        XCTAssertTrue(src.contains("items.append(.mcp(card))"))
        XCTAssertTrue(src.contains("mcpRow(card)"))
        XCTAssertEqual(src.components(separatedBy: "private func todoRow(").count - 1, 1)
        XCTAssertEqual(src.components(separatedBy: "private func mcpRow(").count - 1, 1)
        XCTAssertFalse(src.contains("Ask ZCode"))
        XCTAssertFalse(src.localizedCaseInsensitiveContains("99%"))
        assertNotProductIdentityLies(in: src, file: "ZCodeActivityLineView.swift")
    }

    // MARK: - helpers

    private func assertNotProductIdentityLies(in text: String, file: String) {
        let lower = text.lowercased()
        XCTAssertFalse(
            lower.contains("vibecoder is zcode"),
            "\(file) must not claim VibeCoder IS ZCode")
        XCTAssertFalse(
            lower.contains("we are zcode"),
            "\(file) must not claim the product is ZCode")
        XCTAssertFalse(
            lower.contains("this app is electron")
                || lower.contains("vibecoder is electron"),
            "\(file) must not claim Electron")
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func appSource(_ relative: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(relative), encoding: .utf8)
    }
}
