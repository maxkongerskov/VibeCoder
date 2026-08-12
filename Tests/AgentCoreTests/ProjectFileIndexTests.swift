//
//  ProjectFileIndexTests.swift
//

import XCTest
@testable import AgentCore

final class ProjectFileIndexTests: XCTestCase {

    func testSearchFindsMatchingFilesInTempProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecoder-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "struct Foo {}".write(
            to: sources.appendingPathComponent("Foo.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "print(1)".write(
            to: root.appendingPathComponent("Bar.swift"),
            atomically: true,
            encoding: .utf8
        )

        let hits = ProjectFileIndex.search(query: "foo", root: root)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.contains { $0.displayName == "Foo.swift" })
        XCTAssertFalse(hits.contains { $0.displayName == "Bar.swift" })
    }

    func testWarmCacheMakesIndexAvailableBeforeSearch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecoder-warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "warm".write(
            to: root.appendingPathComponent("Warm.swift"),
            atomically: true,
            encoding: .utf8
        )

        let cold = await ProjectFileIndex.isCacheWarm(for: root)
        XCTAssertFalse(cold)
        await ProjectFileIndex.warmCache(for: root)
        let warm = await ProjectFileIndex.isCacheWarm(for: root)
        XCTAssertTrue(warm)

        let hits = await ProjectFileIndex.searchAsync(query: "warm", root: root)
        XCTAssertTrue(hits.contains { $0.displayName == "Warm.swift" })
    }

    func testSearchAsyncUsesCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecoder-async-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "struct Async {}".write(
            to: root.appendingPathComponent("Async.swift"),
            atomically: true,
            encoding: .utf8
        )

        let first = await ProjectFileIndex.searchAsync(query: "async", root: root)
        let second = await ProjectFileIndex.searchAsync(query: "async", root: root)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains { $0.displayName == "Async.swift" })
    }
}