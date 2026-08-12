//
//  BugHuntPhaseAMutationReviewTests.swift
//
//  Phase A PA1 — MutationReview preview hunks from original/updated content.
//

import XCTest
@testable import AgentCore

final class BugHuntPhaseAMutationReviewTests: XCTestCase {

    // MARK: - hunksFromContents

    func testIdenticalContentsYieldNoHunks() {
        let text = "let x = 1\nlet y = 2\n"
        let hunks = MutationReview.hunksFromContents(original: text, updated: text)
        XCTAssertTrue(hunks.isEmpty, "identical content must not invent a diff")
    }

    func testOneLineEditProducesAtLeastOneHunk() {
        let original = "func f() {\n    return 1\n}\n"
        let updated = "func f() {\n    return 2\n}\n"
        let hunks = MutationReview.hunksFromContents(original: original, updated: updated)
        XCTAssertGreaterThanOrEqual(hunks.count, 1, "one-line edit must produce ≥1 preview hunk")

        let allLines = hunks.flatMap(\.lines)
        let removed = allLines.compactMap { line -> String? in
            if case .removed(let s) = line { return s }
            return nil
        }
        let added = allLines.compactMap { line -> String? in
            if case .added(let s) = line { return s }
            return nil
        }
        XCTAssertTrue(removed.contains { $0.contains("return 1") }, "expected removed line, got \(removed)")
        XCTAssertTrue(added.contains { $0.contains("return 2") }, "expected added line, got \(added)")
    }

    func testNewFileIsAllAdditions() {
        // No trailing newline → exactly two content lines.
        let hunks = MutationReview.hunksFromContents(original: "", updated: "hello\nworld")
        XCTAssertEqual(hunks.count, 1)
        let kinds = hunks[0].lines.map { line -> String in
            switch line {
            case .added: return "a"
            case .removed: return "r"
            case .context: return "c"
            }
        }
        XCTAssertEqual(kinds, ["a", "a"])
        XCTAssertEqual(hunks[0].oldLen, 0)
        XCTAssertEqual(hunks[0].newLen, 2)
    }

    func testDeleteFileIsAllRemovals() {
        // No trailing newline → exactly two content lines removed.
        let hunks = MutationReview.hunksFromContents(original: "a\nb", updated: "")
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].oldLen, 2)
        XCTAssertEqual(hunks[0].newLen, 0)
        XCTAssertTrue(hunks[0].lines.allSatisfy {
            if case .removed = $0 { return true }
            return false
        })
    }

    func testRequireApprovalPassesNonEmptyHunksToReviewer() async throws {
        let original = "line1\nold\nline3\n"
        let updated = "line1\nnew\nline3\n"
        let box = PreviewCapture()
        let reviewer = PatchReviewer { previews in
            box.store(previews)
            return .acceptAll
        }
        let ctx = ToolContext(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            patchReviewer: reviewer,
            conversationID: UUID(),
            executionMode: .build,
            authorization: AuthorizationConfig(useInlineRememberedOnly: true)
        )
        try await MutationReview.requireApproval(
            path: "Foo.swift",
            original: original,
            updated: updated,
            context: ctx
        )
        let captured = box.previews
        XCTAssertEqual(captured.count, 1)
        XCTAssertFalse(captured[0].hunks.isEmpty, "requireApproval must populate hunks for Ask sheet")
        XCTAssertGreaterThanOrEqual(captured[0].hunks.count, 1)
        XCTAssertEqual(captured[0].originalContent, original)
        XCTAssertEqual(captured[0].updatedContent, updated)
    }

    func testRequireApprovalIdenticalStillEmptyHunks() async throws {
        let text = "same\n"
        let box = PreviewCapture()
        let reviewer = PatchReviewer { previews in
            box.store(previews)
            return .acceptAll
        }
        let ctx = ToolContext(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            patchReviewer: reviewer,
            conversationID: UUID(),
            executionMode: .build,
            authorization: AuthorizationConfig(useInlineRememberedOnly: true)
        )
        try await MutationReview.requireApproval(
            path: "Same.swift",
            original: text,
            updated: text,
            context: ctx
        )
        let captured = box.previews
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].hunks.isEmpty)
    }
}

/// Sendable capture box for @Sendable PatchReviewer closures (Swift 6).
private final class PreviewCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _previews: [PatchPreview] = []
    func store(_ p: [PatchPreview]) {
        lock.lock(); defer { lock.unlock() }
        _previews = p
    }
    var previews: [PatchPreview] {
        lock.lock(); defer { lock.unlock() }
        return _previews
    }
}
