//
//  EditReliabilityWaveBTests.swift
//
//  Wave B S5: strict multi-block, write_file/apply_patch RBE, multi-file honesty helpers.
//

import XCTest
@testable import AgentCore

final class EditReliabilityWaveBTests: XCTestCase {

    private var root: URL!
    private var registry: ToolRegistry!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveb-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        registry = ToolRegistry.shared
        await registry.registerBuiltins()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func ctx(preRead: [URL] = [], conversationID: UUID = UUID()) -> ToolContext {
        let reads = Set(preRead.map { SafeModeConfig.normalizePath($0.path) })
        return ToolContext(
            projectRoot: root,
            conversationID: conversationID,
            executionMode: .yolo,
            sessionReadPaths: reads
        )
    }

    // MARK: - write_file RBE

    func testWriteFileCreateNewDoesNotRequireRead() async throws {
        let result = try await registry.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": "new.txt",
                "content": "hello",
            ]),
            context: ctx())
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.txt"), encoding: .utf8), "hello")
    }

    func testWriteFileOverwriteRequiresReadBeforeEdit() async throws {
        let file = root.appendingPathComponent("exist.txt")
        try "old".write(to: file, atomically: true, encoding: .utf8)

        let denied = try await registry.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": "exist.txt",
                "content": "new",
            ]),
            context: ctx())
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(denied.content.lowercased().contains("read-before-edit"), denied.content)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")

        let ok = try await registry.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": "exist.txt",
                "content": "new",
            ]),
            context: ctx(preRead: [file]))
        XCTAssertFalse(ok.isError, ok.content)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
    }

    // MARK: - apply_patch RBE + multi-file success

    func testApplyPatchExistingRequiresReadBeforeEdit() async throws {
        let file = root.appendingPathComponent("p.swift")
        try "func f() {\n    return 1\n}\n".write(to: file, atomically: true, encoding: .utf8)

        let patch = """
        --- a/p.swift
        +++ b/p.swift
        @@ -1,3 +1,3 @@
         func f() {
        -    return 1
        +    return 2
         }
        """

        let denied = try await registry.execute(
            name: "apply_patch",
            arguments: ToolArguments(dictionary: ["patch": patch]),
            context: ctx())
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(denied.content.lowercased().contains("read-before-edit"), denied.content)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("return 1"))

        let ok = try await registry.execute(
            name: "apply_patch",
            arguments: ToolArguments(dictionary: ["patch": patch]),
            context: ctx(preRead: [file]))
        XCTAssertFalse(ok.isError, ok.content)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("return 2"))
    }

    func testApplyPatchMultiFileAllOrNothingOnPlanFailure() async throws {
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try "aaa\n".write(to: a, atomically: true, encoding: .utf8)
        try "bbb\n".write(to: b, atomically: true, encoding: .utf8)

        // Second file has wrong context → plan fails; neither should change.
        let patch = """
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -aaa
        +AAA
        --- a/b.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -WRONG
        +BBB
        """

        let result = try await registry.execute(
            name: "apply_patch",
            arguments: ToolArguments(dictionary: ["patch": patch]),
            context: ctx(preRead: [a, b]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("No files modified") || result.content.lowercased().contains("failed"),
                      result.content)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "aaa\n")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "bbb\n")
    }

    func testApplyPatchMultiFileSuccessWritesBoth() async throws {
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try "aaa\n".write(to: a, atomically: true, encoding: .utf8)
        try "bbb\n".write(to: b, atomically: true, encoding: .utf8)

        let patch = """
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -aaa
        +AAA
        --- a/b.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -bbb
        +BBB
        """

        let result = try await registry.execute(
            name: "apply_patch",
            arguments: ToolArguments(dictionary: ["patch": patch]),
            context: ctx(preRead: [a, b]))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "AAA\n")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "BBB\n")
        XCTAssertTrue(result.mutatedPaths.contains("a.txt") || result.mutatedPaths.contains(a.path)
                      || result.content.contains("a.txt"))
    }

    func testSessionReadTrackerHelper() async {
        let convo = UUID()
        let path = root.appendingPathComponent("x.swift").path
        let norm = SafeModeConfig.normalizePath(path)
        let no = await SessionReadTracker.shared.hasSessionRead(
            path: path, conversationID: convo, sessionReadPaths: [])
        XCTAssertFalse(no)
        let seeded = await SessionReadTracker.shared.hasSessionRead(
            path: path, conversationID: convo, sessionReadPaths: [norm])
        XCTAssertTrue(seeded)
        await SessionReadTracker.shared.recordRead(path: path, conversationID: convo)
        let tracked = await SessionReadTracker.shared.hasSessionRead(
            path: path, conversationID: convo, sessionReadPaths: [])
        XCTAssertTrue(tracked)
        await SessionReadTracker.shared.clear(conversationID: convo)
    }
}
