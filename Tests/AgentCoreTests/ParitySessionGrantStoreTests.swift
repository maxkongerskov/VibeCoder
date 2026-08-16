//
//  ParitySessionGrantStoreTests.swift
//
//  Wave U1 permsheet — in-memory session grants: add/match, conversation
//  isolation, clearConversation, shell-prefix vs tool-name scopes.
//

import XCTest
@testable import AgentCore

final class ParitySessionGrantStoreTests: XCTestCase {

    private func store() -> SessionGrantStore {
        SessionGrantStore()
    }

    func testAddMatchShellPrefix() {
        let s = store()
        let convo = UUID()
        s.add(grant: SessionGrantStore.grant(
            conversationID: convo,
            toolName: "run_shell",
            command: "git status"
        ))

        XCTAssertEqual(
            s.matches(conversationID: convo, toolName: "run_shell", command: "git status"),
            true
        )
        XCTAssertEqual(
            s.matches(conversationID: convo, toolName: "run_shell", command: "git diff --stat"),
            true
        )
        XCTAssertEqual(
            s.matches(conversationID: convo, toolName: "run_shell_command", command: "git log -1"),
            true
        )
        XCTAssertNil(
            s.matches(conversationID: convo, toolName: "run_shell", command: "npm install")
        )
        XCTAssertEqual(
            SessionGrantStore.scopeChipLabel(toolName: "run_shell", command: "git status"),
            "git *"
        )
    }

    func testChainedCommandRequiresEverySegment() {
        let s = store()
        let convo = UUID()
        s.add(grant: SessionGrantStore.grant(
            conversationID: convo,
            toolName: "run_shell",
            command: "git status"
        ))

        XCTAssertNil(
            s.matches(
                conversationID: convo,
                toolName: "run_shell",
                command: "git status && npm install"
            ),
            "git * must not cover a following npm segment"
        )

        s.add(grant: SessionGrantStore.grant(
            conversationID: convo,
            toolName: "run_shell",
            command: "npm install"
        ))
        XCTAssertEqual(
            s.matches(
                conversationID: convo,
                toolName: "run_shell",
                command: "git status && npm install"
            ),
            true
        )
    }

    func testAddMatchToolName() {
        let s = store()
        let convo = UUID()
        s.add(grant: SessionGrantStore.grant(
            conversationID: convo,
            toolName: "write_file",
            command: nil
        ))

        XCTAssertEqual(
            s.matches(conversationID: convo, toolName: "write_file", command: nil),
            true
        )
        XCTAssertNil(
            s.matches(conversationID: convo, toolName: "edit_file", command: nil)
        )
        XCTAssertEqual(
            SessionGrantStore.scopeChipLabel(toolName: "write_file", command: nil),
            "write_file"
        )
    }

    func testOriginTagScope() {
        let s = store()
        let convo = UUID()
        s.add(grant: SessionGrant(
            conversationID: convo,
            scope: .tool(name: "write_file", originTag: "explore")
        ))

        XCTAssertEqual(
            s.matches(
                conversationID: convo,
                toolName: "write_file",
                command: nil,
                originTag: "explore"
            ),
            true
        )
        XCTAssertNil(
            s.matches(
                conversationID: convo,
                toolName: "write_file",
                command: nil,
                originTag: "general-purpose"
            )
        )
        XCTAssertNil(
            s.matches(conversationID: convo, toolName: "write_file", command: nil)
        )
    }

    func testUntaggedToolMatchesAnyOrigin() {
        let s = store()
        let convo = UUID()
        s.add(grant: SessionGrant(
            conversationID: convo,
            scope: .tool(name: "github__create_issue", originTag: nil)
        ))
        XCTAssertEqual(
            s.matches(
                conversationID: convo,
                toolName: "github__create_issue",
                command: nil,
                originTag: "explore"
            ),
            true
        )
    }

    func testConversationIsolation() {
        let s = store()
        let a = UUID()
        let b = UUID()
        s.add(grant: SessionGrantStore.grant(
            conversationID: a,
            toolName: "run_shell",
            command: "swift test"
        ))

        XCTAssertEqual(
            s.matches(conversationID: a, toolName: "run_shell", command: "swift build"),
            true
        )
        XCTAssertNil(
            s.matches(conversationID: b, toolName: "run_shell", command: "swift build")
        )
        XCTAssertEqual(s.grants(for: a).count, 1)
        XCTAssertTrue(s.grants(for: b).isEmpty)
    }

    func testClearConversation() {
        let s = store()
        let a = UUID()
        let b = UUID()
        s.add(grant: SessionGrantStore.grant(
            conversationID: a, toolName: "edit_file", command: nil
        ))
        s.add(grant: SessionGrantStore.grant(
            conversationID: b, toolName: "edit_file", command: nil
        ))

        s.clearConversation(a)
        XCTAssertTrue(s.grants(for: a).isEmpty)
        XCTAssertEqual(
            s.matches(conversationID: b, toolName: "edit_file", command: nil),
            true
        )
        XCTAssertNil(
            s.matches(conversationID: a, toolName: "edit_file", command: nil)
        )
    }

    func testGrantsForReturnsScopeKinds() {
        let s = store()
        let convo = UUID()
        s.add(grant: SessionGrantStore.grant(
            conversationID: convo, toolName: "run_shell", command: "npm run build"
        ))
        s.add(grant: SessionGrant(
            conversationID: convo,
            scope: .tool(name: "task", originTag: "explore")
        ))

        let grants = s.grants(for: convo)
        XCTAssertEqual(grants.count, 2)
        XCTAssertTrue(grants.contains { $0.scope == .shellPrefix("npm") })
        XCTAssertTrue(grants.contains {
            if case .tool(let name, let tag) = $0.scope {
                return name == "task" && tag == "explore"
            }
            return false
        })
        XCTAssertEqual(grants.first { $0.scope == .shellPrefix("npm") }?.chipLabel, "npm *")
    }

    func testSketchMatchesUsesBoundConversation() {
        let s = store()
        let convo = UUID()
        s.add(grant: SessionGrantStore.grant(
            conversationID: convo, toolName: "fetch_url", command: nil
        ))
        XCTAssertNil(s.matches(toolName: "fetch_url", command: nil))

        s.bindConversation(convo)
        XCTAssertEqual(s.matches(toolName: "fetch_url", command: nil), true)
        XCTAssertNil(s.matches(toolName: "web_search", command: nil))
    }

    func testDuplicateAddIsIdempotent() {
        let s = store()
        let convo = UUID()
        let grant = SessionGrantStore.grant(
            conversationID: convo, toolName: "run_shell", command: "ls -la"
        )
        s.add(grant: grant)
        s.add(grant: SessionGrantStore.grant(
            conversationID: convo, toolName: "run_shell", command: "ls /tmp"
        ))
        XCTAssertEqual(s.grants(for: convo).count, 1)
    }

    func testPathExecutableUsesBasename() {
        let s = store()
        let convo = UUID()
        s.add(grant: SessionGrantStore.grant(
            conversationID: convo,
            toolName: "run_shell",
            command: "/usr/bin/git status"
        ))
        XCTAssertEqual(
            s.matches(conversationID: convo, toolName: "run_shell", command: "git log"),
            true
        )
        XCTAssertEqual(
            SessionGrantStore.scopeChipLabel(
                toolName: "run_shell",
                command: "/usr/bin/git status"
            ),
            "git *"
        )
    }

    func testNoGrantReturnsNil() {
        let s = store()
        XCTAssertNil(
            s.matches(conversationID: UUID(), toolName: "run_shell", command: "echo hi")
        )
    }
}
