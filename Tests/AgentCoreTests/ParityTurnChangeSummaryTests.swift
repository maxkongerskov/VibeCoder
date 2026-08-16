//
//  ParityTurnChangeSummaryTests.swift
//
//  Wave U1 turnend: turn-end file-change aggregator (totals, dedupe,
//  delete = removed-only, empty turn, multi-turn isolation).
//

import XCTest
@testable import AgentCore

final class ParityTurnChangeSummaryTests: XCTestCase {

    func testWriteAndEditTotals() {
        let write = invocation(
            id: "w1", name: "write_file",
            args: ["path": "Src/Hello.swift", "content": "one\ntwo\nthree\n"]
        )
        let edit = invocation(
            id: "e1", name: "edit_file",
            args: [
                "path": "Src/Hello.swift",
                "edits": """
                <<<<<<< SEARCH
                two
                =======
                TWO
                extra
                >>>>>>> REPLACE
                """
            ]
        )
        let messages = turn(
            user: "please edit",
            assistantTools: [write, edit],
            results: [
                ("w1", "Wrote 14 bytes to Src/Hello.swift. hunk_id=\(UUID().uuidString)"),
                ("e1", "Edited Src/Hello.swift (1/1 block applied). hunk_id=\(UUID().uuidString)"),
            ]
        )
        let summary = TurnChangeSummary.summarize(turnMessages: messages)
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertEqual(summary.files.first?.status, .created)
        XCTAssertEqual(summary.files.first?.path, "Src/Hello.swift")
        // write: 3 lines; edit: −1 +2
        XCTAssertEqual(summary.totalAdded, 5)
        XCTAssertEqual(summary.totalRemoved, 1)
    }

    func testDedupeSamePathSumsCounts() {
        let first = invocation(
            id: "w1", name: "write_file",
            args: ["path": "a.txt", "content": "aaa\n"]
        )
        let second = invocation(
            id: "w2", name: "write_file",
            args: ["path": "a.txt", "content": "aaa\nbbb\n"]
        )
        let messages = turn(
            user: "twice",
            assistantTools: [first, second],
            results: [
                ("w1", "Wrote 4 bytes to a.txt."),
                ("w2", "Wrote 8 bytes to a.txt."),
            ]
        )
        let summary = TurnChangeSummary.summarize(turnMessages: messages)
        XCTAssertEqual(summary.files.count, 1)
        XCTAssertEqual(summary.files[0].status, .created)
        XCTAssertGreaterThan(summary.totalAdded, 0)
        // Second write is a rewrite: at least the new line is added.
        XCTAssertEqual(summary.files[0].added, summary.totalAdded)
    }

    func testApplyPatchCounts() {
        let patch = """
        --- a/Foo.swift
        +++ b/Foo.swift
        @@ -1,1 +1,2 @@
        -old
        +new
        +extra
        """
        let inv = invocation(id: "p1", name: "apply_patch", args: ["patch": patch])
        let messages = turn(
            user: "patch",
            assistantTools: [inv],
            results: [("p1", "Patched Foo.swift (1 hunks). hunk_id=\(UUID().uuidString)")]
        )
        let summary = TurnChangeSummary.summarize(turnMessages: messages)
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertEqual(summary.files[0].path, "Foo.swift")
        XCTAssertEqual(summary.files[0].status, .modified)
        XCTAssertEqual(summary.totalAdded, 2)
        XCTAssertEqual(summary.totalRemoved, 1)
    }

    func testDeleteCountedAsRemovedOnly() {
        let write = invocation(
            id: "w1", name: "write_file",
            args: ["path": "gone.txt", "content": "keep\nme\n"]
        )
        let del = invocation(
            id: "d1", name: "delete_file",
            args: ["path": "gone.txt"]
        )
        let messages = turn(
            user: "delete it",
            assistantTools: [write, del],
            results: [
                ("w1", "Wrote 8 bytes to gone.txt."),
                ("d1", "Deleted file at gone.txt."),
            ]
        )
        let summary = TurnChangeSummary.summarize(turnMessages: messages)
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertEqual(summary.files[0].status, .deleted)
        XCTAssertEqual(summary.files[0].added, 2, "write lines still summed")
        XCTAssertEqual(summary.files[0].removed, 2)
        XCTAssertEqual(summary.totalAdded, 2)
        XCTAssertEqual(summary.totalRemoved, 2)

        let deleteOnly = turn(
            user: "just delete",
            assistantTools: [del],
            results: [("d1", "Deleted file at gone.txt.")]
        )
        let only = TurnChangeSummary.summarize(turnMessages: deleteOnly)
        XCTAssertEqual(only.files.count, 1)
        XCTAssertEqual(only.files[0].status, .deleted)
        XCTAssertEqual(only.files[0].added, 0)
        XCTAssertGreaterThanOrEqual(only.files[0].removed, 1)
    }

    func testTurnWithNoChangesIsEmpty() {
        let user = ChatMessage(role: .user, content: "hello")
        let assistant = ChatMessage(role: .assistant, content: "Hi there.")
        let summary = TurnChangeSummary.summarize(turnMessages: [user, assistant])
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.fileCount, 0)
        XCTAssertEqual(summary.totalAdded, 0)
        XCTAssertEqual(summary.totalRemoved, 0)
    }

    func testMultiTurnIsolation() {
        let writeA = invocation(
            id: "a1", name: "write_file",
            args: ["path": "A.swift", "content": "aaa\n"]
        )
        let writeB = invocation(
            id: "b1", name: "write_file",
            args: ["path": "B.swift", "content": "bbb\nccc\n"]
        )
        var messages: [ChatMessage] = []
        messages += turn(
            user: "first",
            assistantTools: [writeA],
            results: [("a1", "Wrote 4 bytes to A.swift.")]
        )
        messages.append(ChatMessage(role: .user, content: "just chat"))
        messages.append(ChatMessage(role: .assistant, content: "ok"))
        messages += turn(
            user: "second",
            assistantTools: [writeB],
            results: [("b1", "Wrote 8 bytes to B.swift.")]
        )

        let summaries = TurnChangeSummary.summarizeEachTurn(in: messages)
        XCTAssertEqual(summaries.count, 3)

        XCTAssertEqual(summaries[0].files.map(\.path), ["A.swift"])
        XCTAssertEqual(summaries[0].totalAdded, 1)
        XCTAssertEqual(summaries[0].totalRemoved, 0)

        XCTAssertTrue(summaries[1].isEmpty, "chat-only turn must not inherit prior files")

        XCTAssertEqual(summaries[2].files.map(\.path), ["B.swift"])
        XCTAssertEqual(summaries[2].totalAdded, 2)
        XCTAssertFalse(summaries[2].files.contains { $0.path.contains("A.swift") })
    }

    func testFailedToolIsIgnored() {
        let write = invocation(
            id: "w1", name: "write_file",
            args: ["path": "nope.swift", "content": "x\n"]
        )
        let messages = turn(
            user: "write",
            assistantTools: [write],
            results: [("w1", "write_file: read-before-edit required to overwrite an existing file. No files modified.")]
        )
        let summary = TurnChangeSummary.summarize(turnMessages: messages)
        XCTAssertTrue(summary.isEmpty)
    }

    // MARK: - Fixtures

    private func invocation(id: String, name: String, args: [String: Any]) -> ToolCallInvocation {
        let data = try! JSONSerialization.data(withJSONObject: args)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return ToolCallInvocation(id: id, name: name, arguments: json)
    }

    private func turn(
        user: String,
        assistantTools: [ToolCallInvocation],
        results: [(id: String, content: String)]
    ) -> [ChatMessage] {
        var msgs: [ChatMessage] = [
            ChatMessage(role: .user, content: user),
            ChatMessage(role: .assistant, content: "", toolCalls: assistantTools),
        ]
        for r in results {
            msgs.append(ChatMessage(role: .tool, content: r.content, toolCallID: r.id))
        }
        msgs.append(ChatMessage(role: .assistant, content: "done"))
        return msgs
    }
}
