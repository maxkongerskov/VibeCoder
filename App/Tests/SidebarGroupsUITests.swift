//
//  SidebarGroupsUITests.swift
//
//  Wave 3 — sidecar task groups, 7 colors, unread lastReadAt.
//  Does not edit Conversation.swift.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class SidebarGroupsUITests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func conv(
        _ title: String,
        at date: Date,
        id: UUID = UUID(),
        messages: [ChatMessage] = []
    ) -> Conversation {
        Conversation(
            id: id,
            title: title,
            createdAt: date,
            updatedAt: date,
            messages: messages
        )
    }

    // MARK: - Colors

    func testSevenGroupColors() {
        XCTAssertEqual(
            TaskGroupColor.allCases.map(\.rawValue),
            ["gray", "red", "orange", "yellow", "green", "blue", "purple"]
        )
        XCTAssertEqual(TaskGroupColor.allCases.count, 7)
    }

    // MARK: - Create / rename / delete / assign

    func testCreateRenameDeleteGroup() {
        var snap = TaskGroupSnapshot.empty
        let a = snap.createGroup(name: "Alpha", color: .red)
        XCTAssertEqual(snap.groups.count, 1)
        XCTAssertEqual(a.name, "Alpha")
        XCTAssertEqual(a.color, .red)

        XCTAssertTrue(snap.renameGroup(id: a.id, to: "  Beta  "))
        XCTAssertEqual(snap.group(id: a.id)?.name, "Beta")
        XCTAssertFalse(snap.renameGroup(id: a.id, to: "   "))
        XCTAssertFalse(snap.renameGroup(id: UUID(), to: "Nope"))

        XCTAssertTrue(snap.deleteGroup(id: a.id))
        XCTAssertTrue(snap.groups.isEmpty)
        XCTAssertFalse(snap.deleteGroup(id: a.id))
    }

    func testAssignUnassignAndDeleteClearsMembership() {
        var snap = TaskGroupSnapshot.empty
        let g = snap.createGroup(name: "Work", color: .blue)
        let id = UUID()
        XCTAssertTrue(snap.assign(conversationID: id, to: g.id))
        XCTAssertEqual(snap.membership[id], g.id)
        XCTAssertEqual(snap.group(for: id)?.id, g.id)

        snap.unassign(conversationID: id)
        XCTAssertNil(snap.membership[id])

        XCTAssertTrue(snap.assign(conversationID: id, to: g.id))
        XCTAssertTrue(snap.deleteGroup(id: g.id))
        XCTAssertNil(snap.membership[id])
        XCTAssertFalse(snap.assign(conversationID: id, to: g.id))
    }

    func testUniqueGroupNames() {
        var snap = TaskGroupSnapshot.empty
        XCTAssertEqual(snap.createGroup(name: "New group").name, "New group")
        XCTAssertEqual(snap.createGroup(name: "New group").name, "New group 2")
        XCTAssertEqual(snap.createGroup(name: "New group").name, "New group 3")
    }

    func testPruneDropsMissingConversations() {
        var snap = TaskGroupSnapshot.empty
        let g = snap.createGroup(name: "Keep")
        let live = UUID()
        let dead = UUID()
        _ = snap.assign(conversationID: live, to: g.id)
        _ = snap.assign(conversationID: dead, to: g.id)
        snap.markRead(conversationID: dead, updatedAt: now, now: now)
        snap.prune(existingIDs: [live])
        XCTAssertEqual(snap.membership[live], g.id)
        XCTAssertNil(snap.membership[dead])
        XCTAssertNil(snap.lastReadAt[dead])
        XCTAssertEqual(snap.groups.count, 1)
    }

    // MARK: - Layout: groups above time buckets, empty hidden

    func testGroupedSectionsSitAboveTimeBuckets() {
        let today = conv("Today ungrouped", at: now)
        let yesterday = conv(
            "Yesterday ungrouped",
            at: calendar.date(byAdding: .day, value: -1, to: now)!
        )
        let groupedToday = conv("In group", at: now)
        var snap = TaskGroupSnapshot.empty
        let g = snap.createGroup(name: "Launch", color: .green, assigning: groupedToday.id)

        let sections = TaskGroupLayout.sections(
            unpinned: [groupedToday, today, yesterday],
            snapshot: snap,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].kind, .namedGroup(id: g.id, name: "Launch", color: .green))
        XCTAssertEqual(sections[0].conversations.map(\.title), ["In group"])
        XCTAssertEqual(sections[1].kind, .timeBucket(label: "Today"))
        XCTAssertEqual(sections[1].conversations.map(\.title), ["Today ungrouped"])
        XCTAssertEqual(sections[2].kind, .timeBucket(label: "Yesterday"))
        XCTAssertEqual(sections[2].conversations.map(\.title), ["Yesterday ungrouped"])
    }

    func testEmptyGroupsHidden() {
        var snap = TaskGroupSnapshot.empty
        _ = snap.createGroup(name: "Empty", color: .gray)
        let lone = conv("Solo", at: now)
        let sections = TaskGroupLayout.sections(
            unpinned: [lone],
            snapshot: snap,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].kind, .timeBucket(label: "Today"))
        XCTAssertTrue(snap.populatedGroups(among: [lone.id]).isEmpty)
    }

    func testSearchStillMatchesTitleAndPreviewInsideGroup() {
        let hit = conv(
            "Auth rewrite",
            at: now,
            messages: [
                ChatMessage(role: .user, content: "please look at the login flow"),
                ChatMessage(role: .assistant, content: "I updated the auth middleware."),
            ]
        )
        let miss = conv("Unrelated", at: now)
        var snap = TaskGroupSnapshot.empty
        let g = snap.createGroup(name: "Security", assigning: hit.id)
        _ = snap.assign(conversationID: miss.id, to: g.id)

        let filtered = ZCodeSidebar.filteredConversations(
            [hit, miss],
            query: "auth middleware",
            cleanModelChrome: true
        )
        XCTAssertEqual(filtered.map(\.title), ["Auth rewrite"])

        let sections = TaskGroupLayout.sections(
            unpinned: filtered,
            snapshot: snap,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].kind, .namedGroup(id: g.id, name: "Security", color: .blue))
        XCTAssertEqual(sections[0].conversations.map(\.title), ["Auth rewrite"])
    }

    // MARK: - Unread

    func testUnreadMissingKeyIsRead() {
        let snap = TaskGroupSnapshot.empty
        XCTAssertFalse(snap.isUnread(conversationID: UUID(), updatedAt: now))
    }

    func testMarkUnreadAndSelectClears() {
        var snap = TaskGroupSnapshot.empty
        let id = UUID()
        snap.markUnread(conversationID: id, updatedAt: now)
        XCTAssertTrue(snap.isUnread(conversationID: id, updatedAt: now))

        snap.markRead(conversationID: id, updatedAt: now, now: now)
        XCTAssertFalse(snap.isUnread(conversationID: id, updatedAt: now))
    }

    func testNewerUpdatedAtMarksUnread() {
        var snap = TaskGroupSnapshot.empty
        let id = UUID()
        snap.markRead(conversationID: id, updatedAt: now, now: now)
        XCTAssertFalse(snap.isUnread(conversationID: id, updatedAt: now))
        let later = now.addingTimeInterval(60)
        XCTAssertTrue(snap.isUnread(conversationID: id, updatedAt: later))
    }

    // MARK: - Sidecar codec

    func testSidecarEncodeDecodeRoundTrip() throws {
        var snap = TaskGroupSnapshot.empty
        let convID = UUID()
        let g = snap.createGroup(name: "Design", color: .purple, assigning: convID)
        snap.markRead(conversationID: convID, updatedAt: now, now: now)

        let data = try TaskGroupCodec.encode(snap)
        let decoded = try TaskGroupCodec.decode(data)
        XCTAssertEqual(decoded.groups, snap.groups)
        XCTAssertEqual(decoded.membership, snap.membership)
        XCTAssertEqual(decoded.group(id: g.id)?.color, .purple)
        XCTAssertEqual(
            decoded.lastReadAt[convID]?.timeIntervalSince1970 ?? 0,
            now.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testEmptyJSONDecodesToEmptySnapshot() throws {
        let decoded = try TaskGroupCodec.decode(Data("{}".utf8))
        XCTAssertEqual(decoded, .empty)
    }

    @MainActor
    func testStorePersistsToSidecarFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-groups-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let convID = UUID()
        let store = TaskGroupStore(fileURL: url, autosave: true)
        let g = store.createGroup(name: "Persisted", color: .orange, assigning: convID)
        store.markUnread(conversationID: convID, updatedAt: now)

        let reloaded = TaskGroupStore(fileURL: url, autosave: false)
        XCTAssertEqual(reloaded.snapshot.groups, [g])
        XCTAssertEqual(reloaded.snapshot.membership[convID], g.id)
        XCTAssertTrue(reloaded.isUnread(conversationID: convID, updatedAt: now))
    }
}
