//
//  SidebarArchiveUITests.swift
//
//  Active / Archived / All catalog. Conversation schema unchanged.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class SidebarArchiveUITests: XCTestCase {

    private func conv(_ title: String, archived: Bool = false, pinned: Bool = false) -> Conversation {
        var c = Conversation(title: title)
        c.archived = archived
        c.pinned = pinned
        return c
    }

    func testActiveCatalogUsesInjectedList() {
        let live = conv("Live")
        let buried = conv("Old", archived: true)
        let out = ZCodeSidebar.catalog(
            injectedActive: [live],
            allConversations: [live, buried],
            filter: .active
        )
        XCTAssertEqual(out.map(\.title), ["Live"])
    }

    func testArchivedCatalogOnlyArchivedNewestFirst() {
        var older = conv("Older", archived: true)
        older.updatedAt = Date(timeIntervalSince1970: 100)
        var newer = conv("Newer", archived: true)
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        let live = conv("Live")
        let out = ZCodeSidebar.catalog(
            injectedActive: [live],
            allConversations: [live, older, newer],
            filter: .archived
        )
        XCTAssertEqual(out.map(\.title), ["Newer", "Older"])
        XCTAssertTrue(out.allSatisfy(\.archived))
    }

    func testAllCatalogIncludesArchivedAndPinsFirst() {
        let pinned = conv("Pinned", pinned: true)
        let archived = conv("Archived", archived: true)
        let live = conv("Live")
        let out = ZCodeSidebar.catalog(
            injectedActive: [pinned, live],
            allConversations: [live, archived, pinned],
            filter: .all
        )
        XCTAssertEqual(out.first?.title, "Pinned")
        XCTAssertEqual(Set(out.map(\.title)), ["Pinned", "Archived", "Live"])
    }

    func testEmptyCopy() {
        XCTAssertEqual(ZCodeSidebar.emptyCatalogCopy(filter: .active), "No tasks yet")
        XCTAssertEqual(ZCodeSidebar.emptyCatalogCopy(filter: .all), "No tasks yet")
        XCTAssertEqual(ZCodeSidebar.emptyCatalogCopy(filter: .archived), "No archived tasks")
    }

    func testSearchStillWorksOnArchivedCatalog() {
        let hit = conv("Auth rewrite")
        var buried = conv("Auth old")
        buried.archived = true
        buried.messages = [ChatMessage(role: .assistant, content: "legacy oauth notes")]
        let catalog = ZCodeSidebar.catalog(
            injectedActive: [hit],
            allConversations: [hit, buried],
            filter: .archived
        )
        let filtered = ZCodeSidebar.filteredConversations(
            catalog,
            query: "oauth",
            cleanModelChrome: true
        )
        XCTAssertEqual(filtered.map(\.title), ["Auth old"])
    }
}
