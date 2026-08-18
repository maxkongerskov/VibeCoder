//
//  FindInTaskUITests.swift
//  Wave U2 — Find in task search model (v1: one hit per matching message).
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class FindInTaskUITests: XCTestCase {

    private let userA = UUID()
    private let userB = UUID()
    private let asstA = UUID()
    private let toolA = UUID()

    private func messages() -> [ChatMessage] {
        [
            ChatMessage(id: userA, role: .user, content: "Please review Foo.swift"),
            ChatMessage(id: asstA, role: .assistant, content: "I looked at FOO.swift and the helper."),
            ChatMessage(id: toolA, role: .tool, content: "Foo.swift contents here", toolCallID: "c1"),
            ChatMessage(role: .system, content: "You are a Foo.swift expert"),
            ChatMessage(
                id: userB,
                role: .user,
                content: SystemReminder.autoVerify(path: "Foo.swift", tail: "let foo = 1")
            ),
        ]
    }

    func testEmptyQueryYieldsNoHits() {
        XCTAssertTrue(FindInTaskSearch.hits(query: "", messages: messages()).isEmpty)
        XCTAssertTrue(FindInTaskSearch.hits(query: "   \n\t", messages: messages()).isEmpty)
        XCTAssertEqual(FindInTaskSearch.countLabel(currentIndex: 0, count: 0), "0 of 0")
    }

    func testCaseInsensitiveSubstringMatch() {
        let hits = FindInTaskSearch.hits(query: "foo.swift", messages: messages())
        XCTAssertEqual(hits.map(\.id), [userA.uuidString, asstA.uuidString])
        XCTAssertEqual(hits.map(\.messageID), [userA, asstA])
        XCTAssertTrue(hits[0].snippet.localizedCaseInsensitiveContains("Foo.swift"))
        XCTAssertGreaterThan(hits[0].matchLength, 0)
        XCTAssertEqual(
            FindInTaskSearch.countLabel(currentIndex: 0, count: hits.count),
            "1 of 2"
        )
    }

    func testSkipsNonTranscriptRoles() {
        // Tool + system contain "Foo.swift" but must not appear (appearsInTranscript == false).
        // Wire-only AutoVerify user row is also skipped.
        let hits = FindInTaskSearch.hits(query: "Foo.swift", messages: messages())
        XCTAssertFalse(hits.contains { $0.messageID == toolA })
        XCTAssertFalse(hits.contains { $0.id == toolA.uuidString })
        XCTAssertFalse(hits.contains { $0.messageID == userB })
        XCTAssertEqual(hits.count, 2)
    }

    func testWrapAroundNextAndPrevious() {
        XCTAssertEqual(FindInTaskSearch.nextIndex(0, count: 0), 0)
        XCTAssertEqual(FindInTaskSearch.previousIndex(0, count: 0), 0)

        XCTAssertEqual(FindInTaskSearch.nextIndex(0, count: 3), 1)
        XCTAssertEqual(FindInTaskSearch.nextIndex(1, count: 3), 2)
        XCTAssertEqual(FindInTaskSearch.nextIndex(2, count: 3), 0)

        XCTAssertEqual(FindInTaskSearch.previousIndex(0, count: 3), 2)
        XCTAssertEqual(FindInTaskSearch.previousIndex(2, count: 3), 1)
        XCTAssertEqual(FindInTaskSearch.previousIndex(1, count: 3), 0)
    }

    func testMultipleMatchesInOneMessageCountAsOneHit() {
        // v1: one hit per message — first range only. Intra-message next is P2.
        let repeated = ChatMessage(
            role: .user,
            content: "alpha foo mid foo end foo"
        )
        let hits = FindInTaskSearch.hits(query: "foo", messages: [repeated])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].messageID, repeated.id)
        XCTAssertEqual(hits[0].matchOffset, (repeated.content as NSString).range(of: "foo").location)
    }

    func testPendingStreamingContentIsASyntheticHit() {
        let persisted = ChatMessage(role: .user, content: "hello")
        let hits = FindInTaskSearch.hits(
            query: "partial",
            messages: [persisted],
            streamingContent: "this is a Partial reply"
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, FindInTaskSearch.pendingHitID)
        XCTAssertNil(hits[0].messageID)
        XCTAssertTrue(hits[0].snippet.localizedCaseInsensitiveContains("Partial"))
    }

    func testWhitespaceStreamingIsIgnored() {
        let hits = FindInTaskSearch.hits(
            query: "x",
            messages: [ChatMessage(role: .user, content: "nope")],
            streamingContent: "   \n"
        )
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - File-changes scope

    func testFileChangeEmptyQuery() {
        XCTAssertTrue(FindInTaskFileChangeSearch.hits(query: "", messages: writeTurn()).isEmpty)
        XCTAssertTrue(FindInTaskFileChangeSearch.hits(query: "  \n", messages: writeTurn()).isEmpty)
    }

    func testFileChangeMatchesPath() {
        let hits = FindInTaskFileChangeSearch.hits(query: "Hello.swift", messages: writeTurn())
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, FindInTaskFileChangeSearch.hitID(path: "Src/Hello.swift"))
        XCTAssertTrue(FindInTaskFileChangeSearch.isFileChangeHitID(hits[0].id))
        XCTAssertEqual(
            FindInTaskFileChangeSearch.pathKey(fromHitID: hits[0].id),
            TurnChangeSummary.pathKey("Src/Hello.swift")
        )
        XCTAssertTrue(hits[0].snippet.localizedCaseInsensitiveContains("Hello.swift"))
    }

    func testFileChangeDoesNotSearchMessageBodies() {
        let hits = FindInTaskFileChangeSearch.hits(
            query: "please edit",
            messages: writeTurn(user: "please edit")
        )
        XCTAssertTrue(hits.isEmpty)
    }

    func testFileChangeIgnoresNonMutatingTurns() {
        let messages = [
            ChatMessage(role: .user, content: "read Hello.swift"),
            ChatMessage(role: .assistant, content: "looked at Hello.swift"),
        ]
        XCTAssertTrue(FindInTaskFileChangeSearch.hits(query: "Hello.swift", messages: messages).isEmpty)
    }

    func testFileChangeDedupesSamePath() {
        let first = writeTurn(path: "a.txt", content: "aaa\n")
        let second = writeTurn(path: "a.txt", content: "aaa\nbbb\n", user: "again")
        let hits = FindInTaskFileChangeSearch.hits(query: "a.txt", messages: first + second)
        XCTAssertEqual(hits.count, 1)
    }

    private func writeTurn(
        path: String = "Src/Hello.swift",
        content: String = "one\ntwo\n",
        user: String = "write it"
    ) -> [ChatMessage] {
        let callID = "w-\(path.hashValue)"
        let data = try! JSONSerialization.data(withJSONObject: ["path": path, "content": content])
        let args = String(data: data, encoding: .utf8) ?? "{}"
        return [
            ChatMessage(role: .user, content: user),
            ChatMessage(
                role: .assistant,
                content: "",
                toolCalls: [ToolCallInvocation(id: callID, name: "write_file", arguments: args)]
            ),
            ChatMessage(
                role: .tool,
                content: "Wrote \(content.utf8.count) bytes to \(path). hunk_id=\(UUID().uuidString)",
                toolCallID: callID
            ),
            ChatMessage(role: .assistant, content: "done"),
        ]
    }
}
