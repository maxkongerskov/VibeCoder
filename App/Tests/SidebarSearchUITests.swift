import XCTest
import AgentCore
@testable import VibeCoderApp

final class SidebarSearchUITests: XCTestCase {

    private func conv(title: String, messages: [ChatMessage] = []) -> Conversation {
        Conversation(title: title, messages: messages)
    }

    private func filter(_ items: [Conversation], _ query: String) -> [Conversation] {
        ZCodeSidebar.filteredConversations(items, query: query, cleanModelChrome: true)
    }

    func testEmptyQueryReturnsAll() {
        let items = [conv(title: "Alpha"), conv(title: "Beta")]
        XCTAssertEqual(filter(items, "").map(\.title), ["Alpha", "Beta"])
    }

    func testTitleMatch() {
        let items = [conv(title: "Refactor parser"), conv(title: "Write docs")]
        XCTAssertEqual(filter(items, "parser").map(\.title), ["Refactor parser"])
    }

    func testPreviewMatch() {
        let withPreview = conv(
            title: "Task one",
            messages: [
                ChatMessage(role: .user, content: "please look at the login flow"),
                ChatMessage(role: .assistant, content: "I updated the auth middleware."),
            ]
        )
        let other = conv(title: "Task two")
        XCTAssertEqual(
            filter([withPreview, other], "auth middleware").map(\.title),
            ["Task one"]
        )
    }

    func testCaseInsensitive() {
        let items = [conv(title: "Fix SwiftUI Sidebar"), conv(title: "Other")]
        XCTAssertEqual(filter(items, "swiftui").map(\.title), ["Fix SwiftUI Sidebar"])
        XCTAssertEqual(filter(items, "SIDEBAR").map(\.title), ["Fix SwiftUI Sidebar"])
    }

    func testNoMatchReturnsEmpty() {
        let items = [conv(title: "Alpha"), conv(title: "Beta")]
        XCTAssertTrue(filter(items, "zzzz").isEmpty)
    }

    func testWhitespaceOnlyQueryTreatedAsEmpty() {
        let items = [conv(title: "Alpha"), conv(title: "Beta")]
        XCTAssertEqual(filter(items, "   \t\n").map(\.title), ["Alpha", "Beta"])
    }
}
