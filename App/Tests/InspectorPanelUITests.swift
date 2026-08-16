//
//  InspectorPanelUITests.swift
//
//  Wave U3 sidepane — inspector tab models, TurnChangeSummary walk,
//  notification names, visibility default.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class InspectorPanelUITests: XCTestCase {

    // MARK: - Notifications / visibility

    func testToggleInspectorNotificationName() {
        XCTAssertEqual(
            Notification.Name.toggleInspectorRequested.rawValue,
            "agentos.toggleInspector"
        )
    }

    func testSetInspectorVisibleNotificationName() {
        XCTAssertEqual(
            Notification.Name.setInspectorVisible.rawValue,
            "agentos.setInspectorVisible"
        )
    }

    func testVisibilityStoreDefaultFalse() {
        XCTAssertEqual(InspectorVisibilityStore.key, "vc.inspectorVisible")
        XCTAssertFalse(InspectorVisibilityStore.defaultVisible)
    }

    func testSetInspectorVisibleParsesUserInfo() {
        let show = Notification(
            name: .setInspectorVisible,
            object: nil,
            userInfo: ["visible": true]
        )
        XCTAssertEqual(InspectorVisibilityStore.visible(from: show), true)

        let hide = Notification(
            name: .setInspectorVisible,
            object: nil,
            userInfo: ["visible": false]
        )
        XCTAssertEqual(InspectorVisibilityStore.visible(from: hide), false)

        let numbered = Notification(
            name: .setInspectorVisible,
            object: nil,
            userInfo: ["visible": NSNumber(value: true)]
        )
        XCTAssertEqual(InspectorVisibilityStore.visible(from: numbered), true)

        let viaObject = Notification(name: .setInspectorVisible, object: false)
        XCTAssertEqual(InspectorVisibilityStore.visible(from: viaObject), false)

        let missing = Notification(name: .setInspectorVisible, object: nil)
        XCTAssertNil(InspectorVisibilityStore.visible(from: missing))
    }

    // MARK: - Project root

    func testEmptyRootHasNoProject() {
        XCTAssertNil(InspectorWorkspace.projectRoot(conversation: nil, openedProjectURL: nil))
        XCTAssertNil(InspectorWorkspace.projectRoot(conversation: Conversation(), openedProjectURL: nil))
        XCTAssertEqual(
            InspectorFilesModel.emptyMessage(projectRoot: nil),
            "No project folder — bind a project to see files."
        )
        XCTAssertTrue(InspectorFilesModel.tree(from: []).isEmpty)
    }

    func testProjectRootPrefersWorktreeThenConversationThenOpened() {
        let opened = URL(fileURLWithPath: "/opened")
        XCTAssertEqual(
            InspectorWorkspace.projectRoot(conversation: nil, openedProjectURL: opened),
            opened
        )

        let project = URL(fileURLWithPath: "/proj")
        let bound = Conversation(projectRoot: project)
        XCTAssertEqual(
            InspectorWorkspace.projectRoot(conversation: bound, openedProjectURL: opened),
            project
        )

        let worktree = Conversation(projectRoot: project, worktreeBranch: "agentcore/deadbeef")
        XCTAssertEqual(
            InspectorWorkspace.projectRoot(conversation: worktree, openedProjectURL: opened),
            worktree.worktreeRootURL
        )
        XCTAssertEqual(worktree.worktreeRootURL?.path, "/proj-agentcore-deadbeef")
    }

    // MARK: - Files tab tree

    func testFilesTabUsesTree() {
        let candidates = [
            ProjectFileCandidate(
                path: "/p/App/Foo.swift",
                relativePath: "App/Foo.swift",
                displayName: "Foo.swift"
            ),
            ProjectFileCandidate(
                path: "/p/App/Views/Bar.swift",
                relativePath: "App/Views/Bar.swift",
                displayName: "Bar.swift"
            ),
            ProjectFileCandidate(
                path: "/p/README.md",
                relativePath: "README.md",
                displayName: "README.md"
            ),
        ]
        let tree = InspectorFilesModel.tree(from: candidates)
        XCTAssertEqual(tree, FileTreeNode.build(from: candidates))
        XCTAssertEqual(Set(tree.map(\.name)), ["App", "README.md"])
        XCTAssertTrue(tree.contains { $0.isDirectory && $0.name == "App" })
        XCTAssertFalse(tree.contains { $0.name == "README.md" && $0.isDirectory })

        let app = tree.first { $0.name == "App" }
        XCTAssertEqual(app?.children.first { $0.name == "Views" }?.children.first?.relativePath, "App/Views/Bar.swift")
        XCTAssertNil(InspectorFilesModel.emptyMessage(projectRoot: URL(fileURLWithPath: "/p")))
    }

    // MARK: - Changes tab

    func testChangesTabEmptyWhenNoMutations() {
        let conversation = Conversation(messages: [
            ChatMessage(role: .user, content: "hello"),
            ChatMessage(role: .assistant, content: "Hi there."),
        ])
        XCTAssertTrue(InspectorChangeAggregator.collect(from: conversation).allSatisfy(\.isEmpty))
        XCTAssertTrue(InspectorChangeAggregator.files(in: conversation).isEmpty)
        XCTAssertTrue(InspectorChangeAggregator.files(in: nil).isEmpty)
        XCTAssertEqual(
            InspectorChangeAggregator.emptyMessage,
            "No file changes in this task yet."
        )
    }

    func testChangesTabAggregatesTurnChangeSummary() throws {
        let write = try invocation(
            id: "w1",
            name: "write_file",
            args: ["path": "Src/Hello.swift", "content": "one\ntwo\nthree\n"]
        )
        let edit = try invocation(
            id: "e1",
            name: "edit_file",
            args: [
                "path": "Src/Hello.swift",
                "edits": """
                <<<<<<< SEARCH
                two
                =======
                TWO
                extra
                >>>>>>> REPLACE
                """,
            ]
        )
        let conversation = Conversation(
            messages: turn(
                user: "please edit",
                assistantTools: [write, edit],
                results: [
                    ("w1", "Wrote 14 bytes to Src/Hello.swift."),
                    ("e1", "Edited Src/Hello.swift (1/1 block applied)."),
                ]
            )
        )

        let collected = InspectorChangeAggregator.collect(from: conversation)
        XCTAssertEqual(collected, TurnChangeSummary.summarizeEachTurn(in: conversation.messages))

        let files = InspectorChangeAggregator.files(in: conversation)
        XCTAssertEqual(files.map(\.path), ["Src/Hello.swift"])
        XCTAssertEqual(files.first?.status, .created)
        XCTAssertEqual(files.first?.added, 5)
        XCTAssertEqual(files.first?.removed, 1)
    }

    func testChangesTabMergesSamePathAcrossTurns() throws {
        let first = try invocation(
            id: "a1",
            name: "write_file",
            args: ["path": "A.swift", "content": "aaa\n"]
        )
        let second = try invocation(
            id: "b1",
            name: "write_file",
            args: ["path": "B.swift", "content": "bbb\nccc\n"]
        )
        var messages: [ChatMessage] = []
        messages += turn(
            user: "first",
            assistantTools: [first],
            results: [("a1", "Wrote 4 bytes to A.swift.")]
        )
        messages += turn(
            user: "second",
            assistantTools: [second],
            results: [("b1", "Wrote 8 bytes to B.swift.")]
        )
        let conversation = Conversation(messages: messages)

        let collected = InspectorChangeAggregator.collect(from: conversation)
        XCTAssertEqual(collected, TurnChangeSummary.summarizeEachTurn(in: conversation.messages))
        XCTAssertEqual(collected.count, 2)

        let files = InspectorChangeAggregator.files(in: conversation)
        XCTAssertEqual(files.map(\.path), ["A.swift", "B.swift"])
        XCTAssertEqual(files[0].added, 1)
        XCTAssertEqual(files[1].added, 2)
    }

    func testReconstructsDiffLinesForWriteWithoutChatView() throws {
        let write = try invocation(
            id: "w1",
            name: "write_file",
            args: ["path": "Src/Hello.swift", "content": "one\ntwo\n"]
        )
        let conversation = Conversation(
            messages: turn(
                user: "write",
                assistantTools: [write],
                results: [("w1", "Wrote 8 bytes to Src/Hello.swift.")]
            )
        )
        let lines = InspectorChangeAggregator.diffLines(in: conversation)
        let key = TurnChangeSummary.pathKey("Src/Hello.swift")
        let hunks = InspectorChangeAggregator.lines(
            for: InspectorFileChange(path: "Src/Hello.swift", added: 2, removed: 0, status: .created),
            in: lines
        )
        XCTAssertFalse(hunks.isEmpty)
        XCTAssertTrue(hunks.contains { if case .added(let text) = $0 { return text == "one" }; return false })
        XCTAssertEqual(lines[key]?.isEmpty, false)
    }

    func testChangeFileURLPrefersAbsoluteThenRoot() {
        let root = URL(fileURLWithPath: "/proj")
        XCTAssertEqual(
            InspectorChangeAggregator.fileURL(for: "/tmp/abs.swift", projectRoot: root).path,
            "/tmp/abs.swift"
        )
        XCTAssertEqual(
            InspectorChangeAggregator.fileURL(for: "Src/Hello.swift", projectRoot: root).path,
            "/proj/Src/Hello.swift"
        )
    }

    // MARK: - Fixtures

    private func invocation(id: String, name: String, args: [String: Any]) throws -> ToolCallInvocation {
        let data = try JSONSerialization.data(withJSONObject: args)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return ToolCallInvocation(id: id, name: name, arguments: json)
    }

    private func turn(
        user: String,
        assistantTools: [ToolCallInvocation],
        results: [(id: String, content: String)]
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = [
            ChatMessage(role: .user, content: user),
            ChatMessage(role: .assistant, content: "", toolCalls: assistantTools),
        ]
        for result in results {
            messages.append(ChatMessage(role: .tool, content: result.content, toolCallID: result.id))
        }
        messages.append(ChatMessage(role: .assistant, content: "done"))
        return messages
    }
}
