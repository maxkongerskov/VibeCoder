//
//  ParityReadSessionContextTests.swift
//
//  In-memory coverage for read_session_context: relevant vs handoff,
//  missing session id, and the maxTokens cap.
//

import XCTest
@testable import AgentCore

final class ParityReadSessionContextTests: XCTestCase {

    override func tearDown() {
        ConversationSearchSource.current = .sharedStore
        super.tearDown()
    }

    // MARK: - fixtures

    private let sessionID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!

    private func sampleConversation(id: UUID? = nil, longFiller: Bool = false) -> Conversation {
        let filler = longFiller
            ? String(repeating: "oauth token refresh details ", count: 400)
            : "Implemented OAuth PKCE login."
        return Conversation(
            id: id ?? sessionID,
            title: "Auth work",
            messages: [
                ChatMessage(role: .user, content: "Please implement OAuth login with PKCE."),
                ChatMessage(
                    role: .assistant,
                    content: filler,
                    toolCalls: [
                        ToolCallInvocation(id: "c1", name: "edit_file", arguments: "{}"),
                        ToolCallInvocation(id: "c2", name: "read_file", arguments: "{}"),
                    ]
                ),
                ChatMessage(role: .user, content: "Also restyle the navbar color to blue."),
                ChatMessage(role: .assistant, content: "Auth still uses PKCE."),
            ]
        )
    }

    private func context() -> ToolContext {
        ToolContext(projectRoot: nil, conversationID: UUID())
    }

    // MARK: - relevant vs handoff

    func testRelevantReturnsKeywordHitsWithRoleAndDropsUnrelated() throws {
        let convo = sampleConversation()
        let text = try ConversationSearch.excerpt(
            conversations: [convo],
            sessionId: sessionID.uuidString,
            query: "OAuth PKCE",
            strategy: .relevant
        )
        XCTAssertTrue(text.contains("Session context (relevant)"), text)
        XCTAssertTrue(text.contains("user"), text)
        XCTAssertTrue(text.contains("OAuth") || text.contains("PKCE"), text)
        XCTAssertTrue(text.contains("background"), text)
        XCTAssertFalse(text.contains("navbar"), "unrelated user ask should score 0: \(text)")
    }

    func testHandoffIncludesTitleAsksConclusionsToolsAndRecent() throws {
        let convo = sampleConversation()
        let text = try ConversationSearch.excerpt(
            conversations: [convo],
            sessionId: sessionID.uuidString.lowercased(),
            query: "continue the auth work",
            strategy: .handoff
        )
        XCTAssertTrue(text.contains("Session handoff"), text)
        XCTAssertTrue(text.contains("Auth work"), text)
        XCTAssertTrue(text.contains("Last user asks"), text)
        XCTAssertTrue(text.contains("OAuth login"), text)
        XCTAssertTrue(text.contains("navbar"), text)
        XCTAssertTrue(text.contains("Last assistant conclusions"), text)
        XCTAssertTrue(text.contains("edit_file"), text)
        XCTAssertTrue(text.contains("read_file"), text)
        XCTAssertTrue(text.contains("Recent messages"), text)
        XCTAssertTrue(text.contains("[user]"), text)
        XCTAssertTrue(text.contains("[assistant]"), text)
    }

    func testToolRelevantVsHandoffOnInMemorySource() async throws {
        ConversationSearchSource.current = .inMemory([sampleConversation()])
        let tool = ReadSessionContextTool()
        let relevant = try await tool.execute(
            arguments: ToolArguments(dictionary: [
                "sessionId": sessionID.uuidString,
                "query": "OAuth PKCE",
                "strategy": "relevant",
            ]),
            context: context()
        )
        XCTAssertFalse(relevant.isError, relevant.content)
        XCTAssertTrue(relevant.content.contains("relevant"), relevant.content)
        XCTAssertTrue(relevant.content.contains("OAuth") || relevant.content.contains("PKCE"), relevant.content)

        let handoff = try await tool.execute(
            arguments: ToolArguments(dictionary: [
                "sessionId": String(sessionID.uuidString.prefix(8)),
                "query": "resume prior work",
                "strategy": "handoff",
            ]),
            context: context()
        )
        XCTAssertFalse(handoff.isError, handoff.content)
        XCTAssertTrue(handoff.content.contains("handoff"), handoff.content)
        XCTAssertTrue(handoff.content.contains("Auth work"), handoff.content)
        XCTAssertTrue(handoff.content.contains("edit_file"), handoff.content)
    }

    // MARK: - missing id

    func testMissingIdReturnsError() async throws {
        ConversationSearchSource.current = .inMemory([sampleConversation()])
        let result = try await ReadSessionContextTool().execute(
            arguments: ToolArguments(dictionary: [
                "sessionId": "00000000-0000-0000-0000-000000000000",
                "query": "anything",
            ]),
            context: context()
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(
            result.content.contains("No conversation matched") || result.content.contains("sessionId"),
            result.content
        )
    }

    func testExcerptThrowsOnUnknownSession() {
        XCTAssertThrowsError(
            try ConversationSearch.excerpt(
                conversations: [sampleConversation()],
                sessionId: "deadbeef-dead-beef-dead-beefdeadbeef",
                query: "OAuth",
                strategy: .relevant
            )
        ) { error in
            guard case ConversationSearchError.sessionNotFound = error else {
                return XCTFail("expected sessionNotFound, got \(error)")
            }
        }
    }

    // MARK: - token cap

    func testTokenCapIsRespected() throws {
        let convo = sampleConversation(longFiller: true)
        let text = try ConversationSearch.excerpt(
            conversations: [convo],
            sessionId: sessionID.uuidString,
            query: "OAuth token",
            strategy: .relevant,
            maxTokens: 40
        )
        XCTAssertLessThanOrEqual(ConversationSearch.estimatedTokens(text), 40)
        XCTAssertFalse(text.isEmpty)
    }

    func testHandoffTokenCapAndAbsoluteClamp() throws {
        let convo = sampleConversation(longFiller: true)
        let text = ConversationSearch.excerpt(
            conversation: convo,
            query: "continue",
            strategy: .handoff,
            maxTokens: 32
        )
        XCTAssertLessThanOrEqual(ConversationSearch.estimatedTokens(text), 32)
        XCTAssertEqual(ConversationSearch.clampMaxTokens(nil), 4000)
        XCTAssertEqual(ConversationSearch.clampMaxTokens(0), 4000)
        XCTAssertEqual(ConversationSearch.clampMaxTokens(20_000), 12_000)
    }

    func testToolHonorsMaxTokensOnInMemoryConversation() async throws {
        ConversationSearchSource.current = .inMemory([sampleConversation(longFiller: true)])
        let result = try await ReadSessionContextTool().execute(
            arguments: ToolArguments(dictionary: [
                "sessionId": sessionID.uuidString,
                "query": "OAuth token",
                "strategy": "relevant",
                "maxTokens": 48,
            ]),
            context: context()
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertLessThanOrEqual(ConversationSearch.estimatedTokens(result.content), 48)
    }

    // MARK: - metadata

    func testToolMetadata() {
        XCTAssertEqual(ReadSessionContextTool.name, "read_session_context")
        XCTAssertEqual(ReadSessionContextTool.category, .memory)
        XCTAssertEqual(ReadSessionContextTool.permission, .readOnly)
        XCTAssertEqual(ReadSessionContextTool.schema.parameters.required, ["sessionId", "query"])
        switch ReadSessionContextTool.availability {
        case .core: break
        default: XCTFail("expected core availability")
        }
    }
}
