//
//  EditFileToolTests.swift
//
//  Tests for the edit_file tool: parsing, file creation, apply/reject,
// partial failures, and Safe Mode enforcement.
//

import XCTest
@testable import AgentCore

final class EditFileToolTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ToolRegistry!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-editfile-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registry = ToolRegistry.shared
        await registry.registerBuiltins()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func context(safeMode: Bool = false,
                         shellPrefixes: [String] = [],
                         preReadRelative: [String] = []) -> ToolContext {
        // Read-before-edit guard: tests that edit existing files must
        // seed sessionReadPaths (or call read_file first).
        var reads = Set(preReadRelative.map {
            SafeModeConfig.normalizePath(tempDir.appendingPathComponent($0).path)
        })
        // Convenience: if empty, allow any file already under tempDir for
        // legacy edit tests — only absolute paths that exist.
        if reads.isEmpty {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path) {
                for name in items {
                    let p = tempDir.appendingPathComponent(name).path
                    reads.insert(SafeModeConfig.normalizePath(p))
                }
            }
        }
        return ToolContext(
            projectRoot: tempDir,
            safeMode: safeMode ? SafeModeConfig(
                allowedPathPrefixes: [tempDir.path],
                allowedShellPrefixes: shellPrefixes
            ) : nil,
            conversationID: UUID(),
            sessionReadPaths: reads
        )
    }

    /// Build ToolArguments from a dictionary, avoiding JSON string
    /// interpolation issues with newlines and quotes.
    private func args(_ dict: [String: String]) -> ToolArguments {
        ToolArguments(dictionary: dict)
    }

    // MARK: - Basic editing

    func testEditFileReplacesContent() async throws {
        let file = tempDir.appendingPathComponent("test.swift")
        try "let x = 1\nlet y = 2\n".write(to: file, atomically: true, encoding: .utf8)

        let edits = "test.swift\n<<<<<<< SEARCH\nlet x = 1\n=======\nlet x = 42\n>>>>>>> REPLACE\n"

        let result = try await registry.execute(
            name: "edit_file",
            arguments: args(["path": "test.swift", "edits": edits]),
            context: context()
        )
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Edited test.swift"))
        XCTAssertTrue(result.content.contains("1/1 block"), "Expected '1/1 block' in: \(result.content)")

        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("let x = 42"))
        XCTAssertTrue(updated.contains("let y = 2"), "unchanged lines should remain")
    }

    // MARK: - File creation (empty SEARCH)

    func testEditFileCreatesNewFile() async throws {
        let edits = "newfile.swift\n<<<<<<< SEARCH\n\n=======\nimport Foundation\n\nprint(\"hello\")\n>>>>>>> REPLACE\n"

        let result = try await registry.execute(
            name: "edit_file",
            arguments: args(["path": "newfile.swift", "edits": edits]),
            context: context()
        )
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Created newfile.swift"))

        let file = tempDir.appendingPathComponent("newfile.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(content.contains("import Foundation"))
    }

    // MARK: - No blocks found

    func testEditFileNoBlocksReturnsError() async throws {
        let file = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let result = try await registry.execute(
            name: "edit_file",
            arguments: args(["path": "test.txt", "edits": "no blocks here"]),
            context: context()
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("no SEARCH/REPLACE blocks"))
    }

    // MARK: - Default filename injection

    func testEditFileDefaultFilenameInjection() async throws {
        let file = tempDir.appendingPathComponent("foo.swift")
        try "let a = 1\n".write(to: file, atomically: true, encoding: .utf8)

        // No filename header — tool should prepend the path argument as default.
        let edits = "<<<<<<< SEARCH\nlet a = 1\n=======\nlet a = 99\n>>>>>>> REPLACE\n"

        let result = try await registry.execute(
            name: "edit_file",
            arguments: args(["path": "foo.swift", "edits": edits]),
            context: context()
        )
        XCTAssertFalse(result.isError, "Should succeed with default filename injection: \(result.content)")

        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("let a = 99"))
    }

    // MARK: - Partial failure (strict default + partial_ok)

    func testEditFileStrictPartialFailureWritesNothing() async throws {
        let file = tempDir.appendingPathComponent("test.swift")
        try "aaa\nbbb\nccc\n".write(to: file, atomically: true, encoding: .utf8)

        // Block 1: matches. Block 2: doesn't match.
        let edits = "test.swift\n<<<<<<< SEARCH\naaa\n=======\nAAA\n>>>>>>> REPLACE\n\n<<<<<<< SEARCH\nNONEXISTENT\n=======\nXYZ\n>>>>>>> REPLACE\n"

        let result = try await registry.execute(
            name: "edit_file",
            arguments: args(["path": "test.swift", "edits": edits]),
            context: context()
        )
        XCTAssertTrue(result.isError, "Partial failure should be error")
        XCTAssertTrue(result.content.lowercased().contains("strict") || result.content.contains("no files modified"),
                      result.content)
        XCTAssertTrue(result.content.contains("failed") || result.content.contains("1 of 2"),
                      result.content)
        XCTAssertTrue(result.mutatedPaths.isEmpty)

        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("aaa"), "Strict mode must not write partial success")
        XCTAssertFalse(updated.contains("AAA"), "Strict mode must leave file unchanged")
    }

    func testEditFilePartialOkWritesSuccessfulBlocks() async throws {
        let file = tempDir.appendingPathComponent("test.swift")
        try "aaa\nbbb\nccc\n".write(to: file, atomically: true, encoding: .utf8)

        let edits = "test.swift\n<<<<<<< SEARCH\naaa\n=======\nAAA\n>>>>>>> REPLACE\n\n<<<<<<< SEARCH\nNONEXISTENT\n=======\nXYZ\n>>>>>>> REPLACE\n"

        let result = try await registry.execute(
            name: "edit_file",
            arguments: ToolArguments(dictionary: [
                "path": "test.swift",
                "edits": edits,
                "partial_ok": true
            ]),
            context: context()
        )
        XCTAssertTrue(result.isError, "Partial failure should still be error")
        XCTAssertTrue(result.content.contains("1/2 blocks") || result.content.contains("1 of 2"),
                      result.content)
        XCTAssertEqual(result.mutatedPaths, ["test.swift"])

        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("AAA"), "partial_ok should apply successful block")
    }

    func testEditFileMismatchedBlockFilenameFailsClosed() async throws {
        let file = tempDir.appendingPathComponent("a.swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        // Other file exists so a mistaken multi-file payload is realistic.
        try "let y = 2\n".write(to: tempDir.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)

        let edits = """
        a.swift
        <<<<<<< SEARCH
        let x = 1
        =======
        let x = 9
        >>>>>>> REPLACE

        b.swift
        <<<<<<< SEARCH
        let y = 2
        =======
        let y = 8
        >>>>>>> REPLACE
        """

        let result = try await registry.execute(
            name: "edit_file",
            arguments: args(["path": "a.swift", "edits": edits]),
            context: context()
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("b.swift") || result.content.lowercased().contains("multi-file"),
                      result.content)
        XCTAssertTrue(result.mutatedPaths.isEmpty)

        let a = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(a.contains("let x = 1"), "must not apply when multi-file blocks present")
    }

    // MARK: - Safe Mode: path escape via path argument

    func testEditFilePathOutsideAllowListIsDenied() async throws {
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-editfile-escape-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)

        let edits = "<<<<<<< SEARCH\n\n=======\npwned\n>>>>>>> REPLACE\n"

        do {
            _ = try await registry.execute(
                name: "edit_file",
                arguments: args(["path": outside.path, "edits": edits]),
                context: context(safeMode: true)
            )
            XCTFail("Should have been denied — path outside allow-list")
        } catch let e as ToolError {
            guard case .permissionDenied = e else {
                XCTFail("Expected permissionDenied, got \(e)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path),
                       "file must not be created on a denied call")
    }

    // MARK: - Safe Mode: edit inside allow-list succeeds

    func testEditFileInsideAllowListSucceeds() async throws {
        let file = tempDir.appendingPathComponent("inside.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        let edits = "inside.txt\n<<<<<<< SEARCH\nhello\n=======\nworld\n>>>>>>> REPLACE\n"

        let result = try await registry.execute(
            name: "edit_file",
            arguments: args(["path": "inside.txt", "edits": edits]),
            context: context(safeMode: true)
        )
        XCTAssertFalse(result.isError, "Inside-path edit should succeed: \(result.content)")

        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("world"))
    }
}
