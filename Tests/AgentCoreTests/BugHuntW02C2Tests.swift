//
//  BugHuntW02C2Tests.swift
//
//  Wave C2 second-pass tests for edit surface residuals + new fail-closed paths.
//

import XCTest
@testable import AgentCore

final class BugHuntW02C2Tests: XCTestCase {

    private var root: URL!
    private var registry: ToolRegistry!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-c2-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - B-CASCADE: unique gate uses applier cascade

    func testCascadeCountMatchesWhitespaceUnique() {
        // File has one indented occurrence of `return 1`.
        let content = "func f() {\n    return 1\n}\n"
        // SEARCH without indent — exact substring may be unique, cascade should match 1 window.
        let search = "return 1\n"
        let n = EditBlockApplier.countMatchWindows(search: search, in: content)
        XCTAssertEqual(n, 1, "whitespace cascade should count one window")
    }

    func testCascadeCountAmbiguousTwoWindows() {
        let content = "    foo\nbar\n    foo\n"
        let search = "foo\n"
        let n = EditBlockApplier.countMatchWindows(search: search, in: content)
        XCTAssertEqual(n, 2)
    }

    func testEditFileWhitespaceSearchNotFalseAmbiguous() async throws {
        let file = root.appendingPathComponent("ws.swift")
        try "func f() {\n    return 1\n}\n".write(to: file, atomically: true, encoding: .utf8)
        // SEARCH without indent; only one match under cascade.
        let edits = """
        <<<<<<< SEARCH
        return 1
        =======
        return 2
        >>>>>>> REPLACE
        """
        let result = try await registry.execute(
            name: "edit_file",
            arguments: ToolArguments(dictionary: ["path": "ws.swift", "edits": edits]),
            context: ctx(preRead: [file]))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("return 2"))
    }

    // MARK: - apply_patch soft trailing WS

    func testUnifiedDiffSoftTrailingWhitespace() {
        let original = "func greet() {\n    print(\"hello\")   \n}\n"
        let patch = """
        --- a/hello.swift
        +++ b/hello.swift
        @@ -1,3 +1,3 @@
         func greet() {
        -    print("hello")
        +    print("hello, world")
         }
        """
        let parsed = UnifiedDiff.parse(patch)
        XCTAssertEqual(parsed.count, 1)
        let result = UnifiedDiff.apply(filePatch: parsed[0], to: original)
        guard case .success(let updated) = result else {
            return XCTFail("expected soft match success, got \(result)")
        }
        XCTAssertTrue(updated.contains("hello, world"))
    }

    // MARK: - write_file no-op + unreadable fail-closed

    func testWriteFileNoOpUnchangedContent() async throws {
        let file = root.appendingPathComponent("same.txt")
        try "same".write(to: file, atomically: true, encoding: .utf8)
        let result = try await registry.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: [
                "path": "same.txt",
                "content": "same",
            ]),
            context: ctx(preRead: [file]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("unchanged"), result.content)
        XCTAssertTrue(result.mutatedPaths.isEmpty)
    }

    // MARK: - HunkTracker path normalize classify

    func testClassifyNormalizesAgentPaths() async {
        let abs = root.appendingPathComponent("c.swift").path
        await HunkTracker.shared.recordAgentEdit(path: abs, summary: "edit_file", conversationID: UUID())
        let origin = await HunkTracker.shared.classify(path: abs)
        XCTAssertEqual(origin, .agent)
        await HunkTracker.shared.clear()
    }

    // MARK: - resolvePath must keep project root (C2 regression)

    func testResolvePathRelativeStaysUnderBase() {
        let base = root! // IUO → URL for resolvePath
        let resolved = resolvePath("src/Foo.swift", base: base)
        let expected = base.appendingPathComponent("src/Foo.swift").path
        XCTAssertEqual(
            SafeModeConfig.normalizePath(resolved.path),
            SafeModeConfig.normalizePath(expected))
        XCTAssertTrue(
            SafeModeConfig.normalizePath(resolved.path)
                .hasPrefix(SafeModeConfig.normalizePath(base.path) + "/"),
            "resolved=\(resolved.path) base=\(base.path)")
    }

    func testResolvePathDotDotDoesNotEscapeWithoutDetection() {
        let base = root!.appendingPathComponent("proj", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let resolved = resolvePath("../escape.txt", base: base)
        // After standardize, path is sibling of proj — outside base.
        XCTAssertFalse(
            SafeModeConfig.normalizePath(resolved.path)
                .hasPrefix(SafeModeConfig.normalizePath(base.path) + "/"))
    }
}
