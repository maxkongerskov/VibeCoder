//
//  InlineEditParseTests.swift
//
//  Guards Chat inline-edit cards: SEARCH/REPLACE parsing, rewrite red lines,
//  path seeding. These broke in the wild as "Edit · 1 edit" activity rows
//  and "Created" cards with only green +.
//

import XCTest
@testable import VibeCoderApp
import AgentCore

final class InlineEditParseTests: XCTestCase {

    func testEditFileSearchReplaceProducesRedAndGreen() {
        let edits = """
        <<<<<<< SEARCH
        let x = 1
        =======
        let x = 2
        >>>>>>> REPLACE
        """
        let args: [String: Any] = [
            "path": "/tmp/Foo.swift",
            "edits": edits
        ]
        let input = try! String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let state = ToolCallUIState(
            id: "t1",
            toolName: "edit_file",
            status: .success,
            input: input,
            output: "Edited /tmp/Foo.swift (1/1 block applied)."
        )

        let edit = CodeSessionBuilder.fileEdit(from: state)
        XCTAssertNotNil(edit)
        XCTAssertEqual(edit?.addedCount, 1)
        XCTAssertEqual(edit?.removedCount, 1)
        XCTAssertEqual(edit?.statusLabel, "Edited")
        // Must not treat status output as the only "diff"
        XCTAssertFalse(edit?.lines.contains(where: {
            if case .context(let s) = $0 { return s.contains("block applied") }
            return false
        }) ?? true)
    }

    func testEditFileWithoutFilenameLineStillParses() {
        // Models often omit the path line inside `edits` when `path` is set.
        let edits = """
        <<<<<<< SEARCH
        a
        =======
        b
        >>>>>>> REPLACE
        """
        let args: [String: Any] = ["path": "Desktop/Mockup.swift", "edits": edits]
        let input = try! String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let state = ToolCallUIState(
            id: "t2", toolName: "edit_file", status: .success,
            input: input, output: "ok"
        )
        let edit = CodeSessionBuilder.fileEdit(from: state)
        XCTAssertNotNil(edit, "Should prepend path like EditFileTool.ensureDefaultFilename")
        XCTAssertEqual(edit?.removedCount, 1)
        XCTAssertEqual(edit?.addedCount, 1)
    }

    func testWriteFileRewriteUsesPreviousContentForRedLines() {
        let createArgs: [String: Any] = [
            "path": "/Users/me/Desktop/A.swift",
            "content": "line1\nline2\nline3\n"
        ]
        let createInput = try! String(data: JSONSerialization.data(withJSONObject: createArgs), encoding: .utf8)!
        let create = ToolCallUIState(
            id: "c", toolName: "write_file", status: .success,
            input: createInput, output: "wrote"
        )

        let rewriteArgs: [String: Any] = [
            "path": "/Users/me/Desktop/A.swift",
            "content": "line1\nline3\n"
        ]
        let rewriteInput = try! String(data: JSONSerialization.data(withJSONObject: rewriteArgs), encoding: .utf8)!
        let rewrite = ToolCallUIState(
            id: "r", toolName: "write_file", status: .success,
            input: rewriteInput, output: "wrote"
        )

        let parts = ChatToolPartition.split([create, rewrite])
        XCTAssertEqual(parts.edits.count, 2)
        let first = parts.edits[0]
        let second = parts.edits[1]
        XCTAssertEqual(first.statusLabel, "Created")
        XCTAssertGreaterThan(first.addedCount, 0)
        XCTAssertEqual(first.removedCount, 0)
        // Second should be a rewrite with at least one removal.
        XCTAssertGreaterThan(second.removedCount, 0, "Rewrite must show red − lines")
        XCTAssertTrue(second.statusLabel == "Edited" || second.statusLabel == "Rewrote")
    }

    func testPathLookupMatchesFilenameSuffix() {
        var map = ["/Users/me/Desktop/Mockup.swift": "hello\n"]
        let found = CodeSessionBuilder.lookupContent(map, path: "maxkongerskov/Desktop/Mockup.swift")
        XCTAssertEqual(found, "hello\n")
    }

    func testFailedEditStillProducesCard() {
        let args: [String: Any] = [
            "path": "/tmp/x.swift",
            "edits": "not a real block"
        ]
        let input = try! String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let state = ToolCallUIState(
            id: "f", toolName: "edit_file", status: .failure,
            input: input,
            output: "edit_file: no SEARCH/REPLACE blocks found in `edits`."
        )
        let edit = CodeSessionBuilder.fileEdit(from: state)
        XCTAssertNotNil(edit, "Failed edits should still surface as cards")
        XCTAssertEqual(edit?.status, .failure)
    }

    func testStatusOutputNotPreferredOverInputArgs() {
        // Regression: mergedJSON preferred output, so cards showed "1/1 block applied"
        // as context with zero red/green.
        let edits = """
        <<<<<<< SEARCH
        old
        =======
        new
        >>>>>>> REPLACE
        """
        let args: [String: Any] = ["path": "F.swift", "edits": edits]
        let input = try! String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let state = ToolCallUIState(
            id: "s", toolName: "edit_file", status: .success,
            input: input,
            output: "Edited F.swift (1/1 block applied). hunk_id=ABC"
        )
        let edit = CodeSessionBuilder.fileEdit(from: state)!
        XCTAssertEqual(edit.removedCount, 1)
        XCTAssertEqual(edit.addedCount, 1)
        let texts = edit.lines.map { line -> String in
            switch line {
            case .added(let s), .removed(let s), .context(let s): return s
            }
        }
        XCTAssertFalse(texts.contains(where: { $0.contains("block applied") }))
    }

    func testParseHunkIDsFromToolOutput() {
        let id1 = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let id2 = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let output = "Edited F.swift (1/1 block applied). hunk_id=\(id1.uuidString)"
        XCTAssertEqual(CodeSessionBuilder.parseHunkIDs(from: output), [id1])

        let multi = "Patched a.swift. hunk_id=\(id1.uuidString)\nPatched b.swift. hunk_id=\(id2.uuidString)"
        XCTAssertEqual(CodeSessionBuilder.parseHunkIDs(from: multi), [id1, id2])

        XCTAssertTrue(CodeSessionBuilder.parseHunkIDs(from: "no id here").isEmpty)
        XCTAssertTrue(CodeSessionBuilder.parseHunkIDs(from: "hunk_id=not-a-uuid").isEmpty)
    }

    func testFileEditSurfacesHunkIDsAndCanUndo() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let edits = """
        <<<<<<< SEARCH
        a
        =======
        b
        >>>>>>> REPLACE
        """
        let args: [String: Any] = ["path": "G.swift", "edits": edits]
        let input = try! String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let state = ToolCallUIState(
            id: "u", toolName: "edit_file", status: .success,
            input: input,
            output: "Edited G.swift (1/1 block applied). hunk_id=\(id.uuidString)"
        )
        let edit = CodeSessionBuilder.fileEdit(from: state)!
        XCTAssertEqual(edit.hunkIDs, [id])
        XCTAssertTrue(edit.canUndo)

        let failed = ToolCallUIState(
            id: "f2", toolName: "edit_file", status: .failure,
            input: input,
            output: "edit_file: boom. hunk_id=\(id.uuidString)"
        )
        if let failEdit = CodeSessionBuilder.fileEdit(from: failed) {
            XCTAssertFalse(failEdit.canUndo)
        }
    }
}
