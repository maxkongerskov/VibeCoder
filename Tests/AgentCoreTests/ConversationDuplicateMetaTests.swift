//
//  ConversationDuplicateMetaTests.swift
//  Wave C2: Conversation value init preserves pin / deferred tools when copying.
//

import XCTest
@testable import AgentCore

final class ConversationDuplicateMetaTests: XCTestCase {

    /// Metadata the App coordinator copies before `applyDefaultWorktree`.
    /// Git isolation for a duplicate is `testDuplicateGitBoundConversationGetsDefaultWorktree`
    /// (RELEASE_BAR contract 4 / `3a9e73c`) — not this value-init.
    func testDuplicateInitPreservesPinAndDeferredTools() {
        var source = Conversation(title: "Pinned work")
        source.pinned = true
        source.archived = true
        source.unlockedDeferredTools = ["tool_search"]
        source.railUserPreference = true
        source.samplingOverride = SamplingParams(temperature: 0.2)

        // Pre-bind copy: new id, unarchived. `worktreeBranch` starts nil;
        // coordinator bind then creates `agentcore/<copyId>` for git roots.
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
    }
}
