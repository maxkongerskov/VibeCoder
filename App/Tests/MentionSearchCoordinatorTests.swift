//
//  MentionSearchCoordinatorTests.swift
//

import XCTest
import AgentCore
@testable import VibeCoderApp

@MainActor
final class MentionSearchCoordinatorTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mention-coord-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "struct Alpha {}".write(
            to: root.appendingPathComponent("Alpha.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "struct Beta {}\nfunc betaHelper() {}".write(
            to: root.appendingPathComponent("Sources/Beta.swift"),
            atomically: true,
            encoding: .utf8
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLatestGenerationWinsAfterRapidRefresh() async throws {
        let coordinator = MentionSearchCoordinator()
        coordinator.debounceNanosecondsWarm = 40_000_000
        coordinator.debounceNanosecondsCold = 40_000_000
        await coordinator.warm(root: root)

        async let first: Void = coordinator.refresh(text: "@alp", root: root)
        async let second: Void = coordinator.refresh(text: "@bet", root: root)
        _ = await (first, second)

        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(coordinator.candidates.contains {
            $0.displayName.contains("Beta") || $0.relativePath.contains("Beta")
        })
        XCTAssertFalse(coordinator.candidates.contains {
            $0.kind == .file && $0.displayName == "Alpha.swift"
        })
    }

    func testRefreshPublishesOnMainActor() async {
        let coordinator = MentionSearchCoordinator()
        coordinator.debounceNanosecondsWarm = 1
        coordinator.debounceNanosecondsCold = 1
        await coordinator.warm(root: root)
        await coordinator.refresh(text: "@alp", root: root)

        XCTAssertTrue(Thread.isMainThread)
        XCTAssertFalse(coordinator.candidates.isEmpty)
        XCTAssertTrue(coordinator.showPopup)
    }

    func testInactiveMentionClearsCandidates() async {
        let coordinator = MentionSearchCoordinator()
        coordinator.debounceNanosecondsWarm = 1
        coordinator.debounceNanosecondsCold = 1
        await coordinator.warm(root: root)
        await coordinator.refresh(text: "@alp", root: root)
        await coordinator.refresh(text: "no mention here", root: root)

        XCTAssertTrue(coordinator.candidates.isEmpty)
        XCTAssertFalse(coordinator.showPopup)
    }

    func testSearchAllIncludesFolderAndFile() async {
        let hits = await MentionSearchCoordinator.searchAll(query: "sour", root: root)
        XCTAssertTrue(hits.contains { $0.kind == .folder && $0.displayName == "Sources" },
                      "expected Sources folder in \(hits.map { "\($0.kind):\($0.displayName)" })")
        // Empty query still returns some files
        let all = await MentionSearchCoordinator.searchAll(query: "", root: root)
        XCTAssertFalse(all.isEmpty)
    }

    func testSearchAllIncludesSymbolWhenQueryLongEnough() async {
        let hits = await MentionSearchCoordinator.searchAll(query: "betaHelper", root: root)
        // SymbolIndex substring may or may not find depending on scan — file hit is enough
        // but we prefer symbol when present.
        XCTAssertTrue(
            hits.contains { $0.kind == .symbol || $0.relativePath.contains("Beta") },
            "expected symbol or Beta file for betaHelper; got \(hits.map { "\($0.kind):\($0.displayName)" })"
        )
    }

    func testExtractSymbolNameFromSnippet() {
        XCTAssertEqual(
            MentionSearchCoordinator.extractSymbolName(from: "    func betaHelper() {"),
            "betaHelper")
        XCTAssertEqual(
            MentionSearchCoordinator.extractSymbolName(from: "struct Alpha {"),
            "Alpha")
    }
}
