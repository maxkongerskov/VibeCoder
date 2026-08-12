//
//  FileOpsToolsTests.swift
//
//  Behavioural tests for DeleteFileTool, MoveFileTool, and
//  CreateDirectoryTool. Each test uses a fresh temp directory as the
//  ToolContext working dir so writes/deletes don't touch the host
//  filesystem outside `/tmp`.
//
//  Coverage targets:
//    - delete_file: removes files, removes dirs recursively, refuses
//      to delete the working-dir root, errors on missing paths.
//    - move_file: moves files, renames in place, creates missing
//      parent dirs at destination, refuses to overwrite without flag,
//      overwrites when flag is set.
//    - create_directory: makes the dir, makes intermediate parents,
//      is idempotent when dir exists, errors when path exists as file.
//

import XCTest
@testable import AgentCore

final class FileOpsToolsTests: XCTestCase {

    private var tempRoot: URL!
    private var context: ToolContext!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-fileops-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        context = ToolContext(
            projectRoot: tempRoot,
            conversationID: UUID()
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - delete_file

    func testDeleteFileRemovesAFile() async throws {
        let file = tempRoot.appendingPathComponent("hello.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let result = try await DeleteFileTool().execute(
            arguments: try ToolArguments(json: #"{"path": "hello.txt"}"#),
            context: context
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(result.content.contains("hello.txt"))
    }

    func testDeleteFileRemovesDirectoryRecursively() async throws {
        let dir = tempRoot.appendingPathComponent("nested/a/b/c")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("leaf.txt"), atomically: true, encoding: .utf8)

        _ = try await DeleteFileTool().execute(
            arguments: try ToolArguments(json: #"{"path": "nested"}"#),
            context: context
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("nested").path))
    }

    func testDeleteFileRefusesToDeleteWorkingDirRoot() async {
        do {
            _ = try await DeleteFileTool().execute(
                arguments: try ToolArguments(json: #"{"path": "."}"#),
                context: context
            )
            XCTFail("Expected refusal when deleting working-dir root")
        } catch ToolError.invalidArguments(let msg) {
            XCTAssertTrue(msg.lowercased().contains("refusing"), "Wrong error message: \(msg)")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        // Working dir itself still exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.path))
    }

    func testDeleteFileErrorsOnMissingPath() async {
        do {
            _ = try await DeleteFileTool().execute(
                arguments: try ToolArguments(json: #"{"path": "does-not-exist.txt"}"#),
                context: context
            )
            XCTFail("Expected error on missing path")
        } catch ToolError.invalidArguments {
            // pass
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - move_file

    func testMoveFileRenamesInPlace() async throws {
        let src = tempRoot.appendingPathComponent("old.txt")
        try "v".write(to: src, atomically: true, encoding: .utf8)

        _ = try await MoveFileTool().execute(
            arguments: try ToolArguments(json: #"{"source": "old.txt", "destination": "new.txt"}"#),
            context: context
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("new.txt").path))
    }

    func testMoveFileCreatesParentDirAtDestination() async throws {
        let src = tempRoot.appendingPathComponent("x.txt")
        try "x".write(to: src, atomically: true, encoding: .utf8)

        _ = try await MoveFileTool().execute(
            arguments: try ToolArguments(json: #"{"source": "x.txt", "destination": "deep/nested/x.txt"}"#),
            context: context
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("deep/nested/x.txt").path))
    }

    func testMoveFileRefusesOverwriteByDefault() async throws {
        let src = tempRoot.appendingPathComponent("a.txt")
        let dst = tempRoot.appendingPathComponent("b.txt")
        try "a".write(to: src, atomically: true, encoding: .utf8)
        try "b".write(to: dst, atomically: true, encoding: .utf8)

        do {
            _ = try await MoveFileTool().execute(
                arguments: try ToolArguments(json: #"{"source": "a.txt", "destination": "b.txt"}"#),
                context: context
            )
            XCTFail("Expected overwrite-refusal error")
        } catch ToolError.invalidArguments(let msg) {
            XCTAssertTrue(msg.contains("overwrite"))
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        // Both files still exist with original content.
        XCTAssertEqual(try String(contentsOf: src), "a")
        XCTAssertEqual(try String(contentsOf: dst), "b")
    }

    func testMoveFileOverwritesWhenFlagSet() async throws {
        let src = tempRoot.appendingPathComponent("a.txt")
        let dst = tempRoot.appendingPathComponent("b.txt")
        try "a".write(to: src, atomically: true, encoding: .utf8)
        try "b".write(to: dst, atomically: true, encoding: .utf8)

        _ = try await MoveFileTool().execute(
            arguments: try ToolArguments(json: #"{"source": "a.txt", "destination": "b.txt", "overwrite": "true"}"#),
            context: context
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(try String(contentsOf: dst), "a")  // dst now has src's content
    }

    // MARK: - create_directory

    func testCreateDirectoryMakesNewDir() async throws {
        _ = try await CreateDirectoryTool().execute(
            arguments: try ToolArguments(json: #"{"path": "fresh"}"#),
            context: context
        )
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("fresh").path,
            isDirectory: &isDir)
        XCTAssertTrue(exists)
        XCTAssertTrue(isDir.boolValue)
    }

    func testCreateDirectoryMakesIntermediateParents() async throws {
        _ = try await CreateDirectoryTool().execute(
            arguments: try ToolArguments(json: #"{"path": "a/b/c/d"}"#),
            context: context
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("a/b/c/d").path))
    }

    func testCreateDirectoryIsIdempotent() async throws {
        // First call creates; second is a no-op success (NOT an error).
        // Idempotency matters because re-runnable agent loops will hit
        // the same setup steps multiple times.
        _ = try await CreateDirectoryTool().execute(
            arguments: try ToolArguments(json: #"{"path": "twice"}"#),
            context: context
        )
        let result = try await CreateDirectoryTool().execute(
            arguments: try ToolArguments(json: #"{"path": "twice"}"#),
            context: context
        )
        XCTAssertTrue(result.content.lowercased().contains("already"))
    }

    func testCreateDirectoryErrorsWhenPathExistsAsFile() async throws {
        let file = tempRoot.appendingPathComponent("collision")
        try "I am a file".write(to: file, atomically: true, encoding: .utf8)

        do {
            _ = try await CreateDirectoryTool().execute(
                arguments: try ToolArguments(json: #"{"path": "collision"}"#),
                context: context
            )
            XCTFail("Expected file-vs-directory collision error")
        } catch ToolError.invalidArguments(let msg) {
            XCTAssertTrue(msg.contains("file"))
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}
