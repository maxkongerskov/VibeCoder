//
//  PatchReviewerTests.swift
//
//  Tests for the Sendable-bridge types in `Sources/AgentCore/Patch/
//  PatchReviewer.swift`. Added in #87 to let the host app suspend
//  `apply_patch` in Safe Mode and surface previews to the user.
//

import XCTest
@testable import AgentCore

final class PatchReviewerTests: XCTestCase {

    // MARK: - PatchDecision

    func testDecisionEquatable() {
        XCTAssertEqual(PatchDecision.acceptAll, .acceptAll)
        XCTAssertEqual(PatchDecision.rejectAll, .rejectAll)
        XCTAssertNotEqual(PatchDecision.acceptAll, .rejectAll)

        let id1 = UUID()
        let id2 = UUID()
        XCTAssertEqual(
            PatchDecision.partial(acceptedFileIDs: [id1, id2]),
            PatchDecision.partial(acceptedFileIDs: [id1, id2])
        )
        XCTAssertNotEqual(
            PatchDecision.partial(acceptedFileIDs: [id1]),
            PatchDecision.partial(acceptedFileIDs: [id1, id2])
        )
        XCTAssertNotEqual(
            PatchDecision.partial(acceptedFileIDs: []),
            PatchDecision.acceptAll
        )
    }

    // MARK: - PatchPreview

    func testPreviewIdentifiable() {
        let p = PatchPreview(
            path: "Sources/foo.swift",
            originalContent: "old",
            updatedContent: "new",
            hunks: []
        )
        // Two previews built with auto-IDs should differ.
        let q = PatchPreview(
            path: "Sources/foo.swift",
            originalContent: "old",
            updatedContent: "new",
            hunks: []
        )
        XCTAssertNotEqual(p.id, q.id, "Auto-generated UUIDs must be unique per instance")
    }

    func testPreviewExplicitID() {
        let id = UUID()
        let p = PatchPreview(
            id: id,
            path: "Sources/foo.swift",
            originalContent: "",
            updatedContent: "new content",
            hunks: []
        )
        XCTAssertEqual(p.id, id)
        XCTAssertEqual(p.path, "Sources/foo.swift")
        XCTAssertEqual(p.originalContent, "")
        XCTAssertEqual(p.updatedContent, "new content")
        XCTAssertTrue(p.hunks.isEmpty)
    }

    // MARK: - PatchReviewer wrapper

    func testReviewerInvokesClosure() async {
        // The reviewer is a Sendable struct holding a closure. We
        // verify the wrap-and-invoke round-trip works without needing
        // an actual AppViewModel coordinator behind it.
        // Lock-boxed counter: the reviewer closure is `@Sendable`, so a
        // captured `var` mutation is a data race (a hard error in Swift 6).
        let calls = CallCounter()
        let reviewer = PatchReviewer { _ in
            calls.increment()
            return .acceptAll
        }
        let preview = PatchPreview(
            path: "test.swift",
            originalContent: "",
            updatedContent: "",
            hunks: []
        )
        let decision = await reviewer.review([preview])
        XCTAssertEqual(calls.count, 1, "Closure should fire exactly once per review call")
        XCTAssertEqual(decision, .acceptAll)
    }

    func testReviewerCanReturnPartial() async {
        let id1 = UUID()
        let id2 = UUID()
        let reviewer = PatchReviewer { _ in
            .partial(acceptedFileIDs: [id1])
        }
        let p1 = PatchPreview(id: id1, path: "a.swift",
                              originalContent: "", updatedContent: "", hunks: [])
        let p2 = PatchPreview(id: id2, path: "b.swift",
                              originalContent: "", updatedContent: "", hunks: [])
        let decision = await reviewer.review([p1, p2])
        guard case .partial(let ids) = decision else {
            return XCTFail("Expected .partial, got \(decision)")
        }
        XCTAssertEqual(ids, [id1])
    }

    func testReviewerCanReject() async {
        let reviewer = PatchReviewer { _ in .rejectAll }
        let decision = await reviewer.review([])
        XCTAssertEqual(decision, .rejectAll)
    }
}

/// Thread-safe call counter for `@Sendable` test closures (a captured
/// `var` would be a data race under Swift 6 strict concurrency).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
