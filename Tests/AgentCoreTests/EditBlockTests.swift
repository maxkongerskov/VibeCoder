//
//  EditBlockTests.swift
//
//  Tests for the Aider-style SEARCH/REPLACE parser and applier.
//

import XCTest
@testable import AgentCore

final class EditBlockTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-editblock-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeTestFile(_ name: String, content: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Parser

    func testParseSingleBlock() throws {
        let input = """
        test.swift
        <<<<<<< SEARCH
        let x = 1
        =======
        let x = 2
        >>>>>>> REPLACE
        """
        let blocks = try EditBlockParser.findBlocks(in: input)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].filename, "test.swift")
        XCTAssertEqual(blocks[0].original.trimmingCharacters(in: .newlines), "let x = 1")
        XCTAssertEqual(blocks[0].updated.trimmingCharacters(in: .newlines), "let x = 2")
    }

    func testParseMultipleBlocks() throws {
        let input = """
        test.swift
        <<<<<<< SEARCH
        let a = 1
        =======
        let a = 2
        >>>>>>> REPLACE

        <<<<<<< SEARCH
        let b = 3
        =======
        let b = 4
        >>>>>>> REPLACE
        """
        let blocks = try EditBlockParser.findBlocks(in: input)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].original.trimmingCharacters(in: .newlines), "let a = 1")
        XCTAssertEqual(blocks[1].original.trimmingCharacters(in: .newlines), "let b = 3")
    }

    func testParseThrowsOnMissingFilename() {
        let input = """
        <<<<<<< SEARCH
        hello
        =======
        world
        >>>>>>> REPLACE
        """
        XCTAssertThrowsError(try EditBlockParser.findBlocks(in: input)) { error in
            if let e = error as? EditBlockParseError {
                if case .missingFilename = e { return }
            }
            XCTFail("Expected missingFilename, got \(error)")
        }
    }

    func testParseThrowsOnMissingDivider() {
        let input = """
        test.swift
        <<<<<<< SEARCH
        hello
        >>>>>>> REPLACE
        """
        XCTAssertThrowsError(try EditBlockParser.findBlocks(in: input)) { error in
            if let e = error as? EditBlockParseError {
                if case .missingDivider = e { return }
            }
            XCTFail("Expected missingDivider, got \(error)")
        }
    }

    func testParseToleratesMarkerLength() throws {
        // Models sometimes emit 6, 7, or 8 characters instead of 5.
        let input = """
        foo.py
        <<<<<<<< SEARCH
        old
        ========
        new
        >>>>>>> REPLACE
        """
        let blocks = try EditBlockParser.findBlocks(in: input)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].original.trimmingCharacters(in: .newlines), "old")
    }

    func testParseEmptyBlocks() throws {
        let input = "no blocks here"
        let blocks = try EditBlockParser.findBlocks(in: input)
        XCTAssertTrue(blocks.isEmpty)
    }

    // MARK: - Applier: exact match

    func testApplyExactMatch() {
        let content = "line1\nline2\nline3\n"
        let block = EditBlock(filename: "test.txt", original: "line2\n", updated: "LINE2\n")
        switch EditBlockApplier.apply(block, to: content) {
        case .applied(let new):
            XCTAssertEqual(new, "line1\nLINE2\nline3\n")
        case .failed(let reason):
            XCTFail("Should have applied: \(reason)")
        }
    }

    // MARK: - Applier: whitespace tolerance

    func testApplyWhitespaceTolerant() {
        let content = "    let x = 1\n    let y = 2\n"
        // Model dropped indentation — whitespace-flexible match should catch it
        let block = EditBlock(filename: "test.swift",
                              original: "let x = 1\n",
                              updated: "let x = 42\n")
        switch EditBlockApplier.apply(block, to: content) {
        case .applied(let new):
            XCTAssertTrue(new.contains("let x = 42"))
        case .failed(let reason):
            XCTFail("Whitespace-tolerant match should have worked: \(reason)")
        }
    }

    // MARK: - Applier: dotdotdots elision

    func testApplyDotdotdotsElision() throws {
        let content = "func a() {\n    line1\n    line2\n    target\n    line4\n    line5\n}\n"
        let block = EditBlock(filename: "test.swift",
                              original: "func a() {\n    ...\n    target\n    ...\n}\n",
                              updated: "func a() {\n    ...\n    replaced\n    ...\n}\n")
        switch EditBlockApplier.apply(block, to: content) {
        case .applied(let new):
            XCTAssertTrue(new.contains("replaced"))
            XCTAssertFalse(new.contains("target"))
        case .failed(let reason):
            XCTFail("Dotdotdots elision should have worked: \(reason)")
        }
    }

    // MARK: - Applier: no match

    func testApplyFailsOnNoMatch() {
        let content = "hello world\n"
        let block = EditBlock(filename: "test.txt", original: "goodbye\n", updated: "farewell\n")
        switch EditBlockApplier.apply(block, to: content) {
        case .applied:
            XCTFail("Should not have applied — no matching content")
        case .failed(let reason):
            XCTAssertFalse(reason.isEmpty, "Failure reason should be non-empty")
        }
    }

    // MARK: - applyAll: multi-block with partial failure

    func testApplyAllWithPartialFailure() {
        let content = "aaa\nbbb\nccc\n"
        let block1 = EditBlock(filename: "test.txt", original: "aaa\n", updated: "AAA\n")
        let block2 = EditBlock(filename: "test.txt", original: "NONEXISTENT\n", updated: "XYZ\n")
        let (newContent, failures) = EditBlockApplier.applyAll([block1, block2], to: content)
        XCTAssertEqual(failures.count, 1, "One block should have failed")
        XCTAssertTrue(newContent.contains("AAA"), "Successful block should be applied")
        XCTAssertTrue(newContent.contains("bbb"), "Other content should remain")
        XCTAssertTrue(newContent.contains("ccc"))
    }

    func testApplyAllEmpty() {
        let content = "hello\n"
        let (newContent, failures) = EditBlockApplier.applyAll([], to: content)
        XCTAssertEqual(newContent, content)
        XCTAssertTrue(failures.isEmpty)
    }
}
