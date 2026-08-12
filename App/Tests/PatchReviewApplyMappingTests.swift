//
//  PatchReviewApplyMappingTests.swift
//
//  File-level patch decisions must match AgentCore PatchDecision wire format.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class PatchReviewApplyMappingTests: XCTestCase {

    private let idA = UUID()
    private let idB = UUID()
    private let idC = UUID()

    private var pathMap: [String: UUID] {
        ["a.swift": idA, "b.swift": idB, "c.swift": idC]
    }

    func testRejectAllWhenNothingAccepted() {
        let d: [String: FilePatchDecision] = [
            "a.swift": .rejected,
            "b.swift": .pending,
            "c.swift": .rejected,
        ]
        let result = PatchReviewApplyMapping.toPatchDecision(
            decisions: d,
            pathToPreviewID: pathMap,
            previewCount: 3
        )
        XCTAssertEqual(result, .rejectAll)
    }

    func testAcceptAllWhenEveryFileAccepted() {
        let d: [String: FilePatchDecision] = [
            "a.swift": .accepted,
            "b.swift": .accepted,
            "c.swift": .accepted,
        ]
        let result = PatchReviewApplyMapping.toPatchDecision(
            decisions: d,
            pathToPreviewID: pathMap,
            previewCount: 3
        )
        XCTAssertEqual(result, .acceptAll)
    }

    func testPartialAcceptsOnlyAcceptedFileIDs() {
        let d: [String: FilePatchDecision] = [
            "a.swift": .accepted,
            "b.swift": .rejected,
            "c.swift": .accepted,
        ]
        let result = PatchReviewApplyMapping.toPatchDecision(
            decisions: d,
            pathToPreviewID: pathMap,
            previewCount: 3
        )
        guard case .partial(let ids) = result else {
            return XCTFail("expected .partial, got \(result)")
        }
        XCTAssertEqual(ids, Set([idA, idC]))
        XCTAssertFalse(ids.contains(idB))
    }

    func testUnknownPathInDecisionsIsIgnored() {
        let d: [String: FilePatchDecision] = [
            "a.swift": .accepted,
            "ghost.swift": .accepted,
        ]
        let result = PatchReviewApplyMapping.toPatchDecision(
            decisions: d,
            pathToPreviewID: ["a.swift": idA],
            previewCount: 1
        )
        XCTAssertEqual(result, .acceptAll)
    }

    func testHunkDecisionAliasMatchesFilePatchDecision() {
        // Honesty regression: API surface still exposes HunkDecision as alias
        // of file-level enum so no code path reintroduces per-hunk apply keys.
        let file: FilePatchDecision = .accepted
        let hunk: HunkDecision = file
        XCTAssertEqual(hunk, .accepted)
    }
}
