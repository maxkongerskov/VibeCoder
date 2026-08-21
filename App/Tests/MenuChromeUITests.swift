//
//  MenuChromeUITests.swift
//
//  Wave U4 menus-chrome — notification names, prev/next walk, sidebar toggle.
//

import XCTest
import SwiftUI
import AgentCore
@testable import VibeCoderApp

final class MenuChromeUITests: XCTestCase {

    func testToggleSidebarNotificationName() {
        XCTAssertEqual(
            Notification.Name.toggleSidebarRequested.rawValue,
            "agentos.toggleSidebar"
        )
    }

    func testPreviousTaskNotificationName() {
        XCTAssertEqual(
            Notification.Name.previousTaskRequested.rawValue,
            "agentos.previousTask"
        )
    }

    func testNextTaskNotificationName() {
        XCTAssertEqual(
            Notification.Name.nextTaskRequested.rawValue,
            "agentos.nextTask"
        )
    }

    func testOpenWorkspaceNotificationName() {
        XCTAssertEqual(
            Notification.Name.openWorkspaceRequested.rawValue,
            "agentos.openWorkspace"
        )
    }

    func testAdjacentTaskIDWalksVisibleList() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let ids = [a, b, c]

        XCTAssertEqual(MenuChrome.adjacentTaskID(visibleIDs: ids, currentID: a, delta: 1), b)
        XCTAssertEqual(MenuChrome.adjacentTaskID(visibleIDs: ids, currentID: b, delta: 1), c)
        XCTAssertNil(MenuChrome.adjacentTaskID(visibleIDs: ids, currentID: c, delta: 1))

        XCTAssertEqual(MenuChrome.adjacentTaskID(visibleIDs: ids, currentID: c, delta: -1), b)
        XCTAssertEqual(MenuChrome.adjacentTaskID(visibleIDs: ids, currentID: b, delta: -1), a)
        XCTAssertNil(MenuChrome.adjacentTaskID(visibleIDs: ids, currentID: a, delta: -1))
    }

    func testAdjacentTaskIDNilWhenMissingOrEmpty() {
        let a = UUID()
        XCTAssertNil(MenuChrome.adjacentTaskID(visibleIDs: [], currentID: a, delta: 1))
        XCTAssertNil(MenuChrome.adjacentTaskID(visibleIDs: [a], currentID: nil, delta: 1))
        XCTAssertNil(MenuChrome.adjacentTaskID(visibleIDs: [a], currentID: UUID(), delta: 1))
    }

    func testSidebarVisibilityTogglesAllAndDetailOnly() {
        XCTAssertEqual(MenuChrome.toggledSidebarVisibility(.all), .detailOnly)
        XCTAssertEqual(MenuChrome.toggledSidebarVisibility(.detailOnly), .all)
        XCTAssertEqual(MenuChrome.toggledSidebarVisibility(.automatic), .detailOnly)
    }

    // MARK: - First-run chat routing (no XCUI)

    func testWorkspaceRoutingWaitsForStore() {
        XCTAssertEqual(
            WorkspaceChatRouting.decide(
                conversationsLoaded: false,
                conversations: [],
                selectedID: nil
            ),
            .waitingForStore
        )
        let existing = Conversation()
        XCTAssertEqual(
            WorkspaceChatRouting.decide(
                conversationsLoaded: false,
                conversations: [existing],
                selectedID: existing.id
            ),
            .waitingForStore,
            "must not seed or show chat before disk load even if memory has rows"
        )
    }

    func testWorkspaceRoutingSeedsFirstTaskWhenStoreEmpty() {
        XCTAssertEqual(
            WorkspaceChatRouting.decide(
                conversationsLoaded: true,
                conversations: [],
                selectedID: nil
            ),
            .createFirstTask
        )
        var archived = Conversation()
        archived.archived = true
        XCTAssertEqual(
            WorkspaceChatRouting.decide(
                conversationsLoaded: true,
                conversations: [archived],
                selectedID: archived.id
            ),
            .createFirstTask,
            "archived-only list is still first-run empty Recents"
        )
    }

    func testWorkspaceRoutingShowsSelectedThenFirstVisible() {
        let a = Conversation()
        let b = Conversation()
        XCTAssertEqual(
            WorkspaceChatRouting.decide(
                conversationsLoaded: true,
                conversations: [a, b],
                selectedID: b.id
            ),
            .showChat(b.id)
        )
        XCTAssertEqual(
            WorkspaceChatRouting.decide(
                conversationsLoaded: true,
                conversations: [a, b],
                selectedID: nil
            ),
            .showChat(a.id)
        )
        XCTAssertEqual(
            WorkspaceChatRouting.decide(
                conversationsLoaded: true,
                conversations: [a, b],
                selectedID: UUID()
            ),
            .showChat(a.id)
        )
    }
}
