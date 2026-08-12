//
//  ConversationDuplicateMetaTests.swift
//  Wave C2: Conversation value init preserves pin / deferred tools when copying.
//

import XCTest
@testable import AgentCore

final class ConversationDuplicateMetaTests: XCTestCase {

    /// Mirrors the fields ConversationCoordinator.duplicateConversation must copy.
    func testDuplicateInitPreservesPinAndDeferredTools() {
        var source = Conversation(title: "Pinned work")
        source.pinned = true
        source.archived = true
        source.unlockedDeferredTools = ["tool_search"]
        source.railUserPreference = true
        source.samplingOverride = SamplingParams(temperature: 0.2)

        // Same shape as coordinator duplicate (new id, unarchived, no worktree).
        let copy = Conversation(
            id: UUID(),
            title: source.title + " (copy)",
            createdAt: Date(),
            updatedAt: Date(),
            messages: source.messages,
            modelID: source.modelID,
            projectRoot: source.projectRoot,
            worktreeBranch: nil,
            systemPromptOverride: source.systemPromptOverride,
            samplingOverride: source.samplingOverride,
            unlockedDeferredTools: source.unlockedDeferredTools,
            pinned: source.pinned,
            archived: false,
            orchestratorBriefs: source.orchestratorBriefs,
            railUserPreference: source.railUserPreference
        )

        XCTAssertTrue(copy.pinned)
        XCTAssertFalse(copy.archived, "duplicate must reappear in sidebar")
        XCTAssertEqual(copy.unlockedDeferredTools, ["tool_search"])
        XCTAssertEqual(copy.railUserPreference, true)
        XCTAssertEqual(copy.samplingOverride?.temperature, 0.2)
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertNil(copy.worktreeBranch)
    }
}
