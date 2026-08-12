import XCTest
@testable import VibeCoderApp

final class CommandPaletteFilterTests: XCTestCase {
    private let sample: [CommandPaletteItem] = [
        CommandPaletteItem(
            id: "new-chat", title: "New Conversation", subtitle: nil,
            category: "Chat", keywords: ["new"]),
        CommandPaletteItem(
            id: "toggle-rail", title: "Show Activity Rail", subtitle: "Toggle panel",
            category: "View", keywords: ["rail", "artifact"]),
    ]

    func testEmptyQueryReturnsAllItems() {
        let result = CommandPaletteFilter.filter(sample, query: "")
        XCTAssertEqual(result.count, 2)
    }

    func testFilterMatchesTitleCategoryAndKeywords() {
        XCTAssertEqual(CommandPaletteFilter.filter(sample, query: "rail").map(\.id), ["toggle-rail"])
        XCTAssertEqual(CommandPaletteFilter.filter(sample, query: "chat").map(\.id), ["new-chat"])
        XCTAssertEqual(CommandPaletteFilter.filter(sample, query: "artifact").map(\.id), ["toggle-rail"])
    }
}