//
//  ProjectMemoryFilesTests.swift
//  S4 — project MEMORY.md / DECISIONS.md read-write.
//

import XCTest
@testable import AgentCore

final class ProjectMemoryFilesTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("s4-mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReadMissingReturnsEmpty() {
        XCTAssertFalse(ProjectMemoryFiles.exists(kind: .memory, projectRoot: root))
        XCTAssertEqual(ProjectMemoryFiles.read(kind: .memory, projectRoot: root), "")
    }

    func testWriteAndReadMemoryRoundTrip() throws {
        let body = "# Memory\n\nS4_MARKER_ABC\n"
        try ProjectMemoryFiles.write(kind: .memory, projectRoot: root, text: body)
        XCTAssertTrue(ProjectMemoryFiles.exists(kind: .memory, projectRoot: root))
        XCTAssertEqual(ProjectMemoryFiles.read(kind: .memory, projectRoot: root), body)
        XCTAssertTrue(
            ProjectMemoryFiles.url(kind: .memory, projectRoot: root).path.hasSuffix("MEMORY.md"))
    }

    func testWriteDecisionsAndLoadProjectMemoryInjects() throws {
        try ProjectMemoryFiles.write(
            kind: .decisions,
            projectRoot: root,
            text: "# Decisions\n\n**Decision:** use worktrees\n")
        try ProjectMemoryFiles.write(
            kind: .memory,
            projectRoot: root,
            text: "# Memory\n\nPrefer patches.\n")
        let block = ChatLoop.loadProjectMemory(projectRoot: root)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("Prefer patches") || block!.contains("Memory"), block ?? "")
        XCTAssertTrue(block!.contains("worktrees") || block!.contains("Decision"), block ?? "")
    }

    func testDefaultTemplatesNonEmpty() {
        for kind in ProjectMemoryFileKind.allCases {
            let t = ProjectMemoryFiles.defaultTemplate(kind: kind)
            XCTAssertFalse(t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(t.contains("#"))
        }
    }
}
