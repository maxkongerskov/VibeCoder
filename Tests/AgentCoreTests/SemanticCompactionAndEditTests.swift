//
//  SemanticCompactionAndEditTests.swift
//

import XCTest
@testable import AgentCore

final class SemanticCompactionAndEditTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
    }

    func testSemanticCompactionTriggersAndKeepsRecent() async {
        var messages: [ChatMessage] = []
        for i in 0..<20 {
            messages.append(.init(role: .user, content: "goal step \(i): decide to touch file_\(i).swift"))
            messages.append(.init(role: .assistant, content: "I will edit file_\(i).swift", toolCalls: [
                .init(id: "c\(i)", name: "read_file", arguments: "{\"path\":\"file_\(i).swift\"}")
            ]))
            messages.append(.init(role: .tool, content: String(repeating: "x", count: 500) + " error failed", toolCallID: "c\(i)"))
        }
        // Small budget forces compaction
        let result = await SemanticCompactor.compact(
            messages,
            systemPromptTokens: 100,
            budgetTokens: 400,
            keepRecent: 4)
        XCTAssertTrue(result.didCompact)
        XCTAssertNotNil(result.summary)
        XCTAssertTrue(result.summary!.contains("current_goal")
                      || result.summary!.contains("files_touched")
                      || result.summary!.contains("decisions"),
                      result.summary ?? "")
        // Recent region preserved at end
        XCTAssertEqual(result.messages.last?.toolCallID, messages.last?.toolCallID)
        // No dangling: every tool message in result should have preceding assistant with tool calls
        // or be part of summary-only prefix
        let afterSummary = result.messages.dropFirst() // summary is first
        for (idx, m) in afterSummary.enumerated() where m.role == .tool {
            // find previous assistant in afterSummary
            let prior = afterSummary.prefix(idx).reversed().first { $0.role == .assistant }
            XCTAssertNotNil(prior, "tool without assistant in recent region")
        }
    }

    func testEditRequiresReadBeforeEdit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-rbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("A.swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)

        let convo = UUID()
        let context = ToolContext(
            projectRoot: root,
            conversationID: convo,
            executionMode: .yolo)

        let edits = """
        <<<<<<< SEARCH
        let x = 1
        =======
        let x = 2
        >>>>>>> REPLACE
        """
        let denied = try await ToolRegistry.shared.execute(
            name: "edit_file",
            arguments: ToolArguments(dictionary: ["path": file.path, "edits": edits]),
            context: context)
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(denied.content.lowercased().contains("read-before-edit"), denied.content)

        // After read, edit should work
        _ = try await ToolRegistry.shared.execute(
            name: "read_file",
            arguments: ToolArguments(dictionary: ["path": file.path]),
            context: context)
        let ok = try await ToolRegistry.shared.execute(
            name: "edit_file",
            arguments: ToolArguments(dictionary: ["path": file.path, "edits": edits]),
            context: context)
        XCTAssertFalse(ok.isError, ok.content)
        let body = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(body.contains("let x = 2"))
        XCTAssertTrue(ok.content.contains("hunk_id="))
    }

    func testAmbiguousSearchFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-amb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("B.swift")
        try "foo\nbar\nfoo\n".write(to: file, atomically: true, encoding: .utf8)
        let convo = UUID()
        let context = ToolContext(
            projectRoot: root,
            conversationID: convo,
            executionMode: .yolo,
            sessionReadPaths: [SafeModeConfig.normalizePath(file.path)])

        let edits = """
        <<<<<<< SEARCH
        foo
        =======
        baz
        >>>>>>> REPLACE
        """
        let result = try await ToolRegistry.shared.execute(
            name: "edit_file",
            arguments: ToolArguments(dictionary: ["path": file.path, "edits": edits]),
            context: context)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("ambiguous"), result.content)
    }

    func testHunkRejectRollsBack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("C.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        let convo = UUID()
        // Wave B: overwrite requires read-before-edit (sessionReadPaths or prior read_file).
        let context = ToolContext(
            projectRoot: root,
            conversationID: convo,
            executionMode: .yolo,
            sessionReadPaths: [SafeModeConfig.normalizePath(file.path)])

        _ = try await ToolRegistry.shared.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: ["path": file.path, "content": "changed"]),
            context: context)
        let hunks = await HunkTracker.shared.hunks(for: convo)
        // PA2: single full TrackedHunk — registry only marks agent path origin.
        XCTAssertEqual(hunks.count, 1, "expected exactly one hunk, got \(hunks.map { ($0.originalContent, $0.updatedContent) })")
        let full = hunks[0]
        XCTAssertEqual(full.originalContent, "original")
        XCTAssertEqual(full.updatedContent, "changed")
        let ok = try await HunkTracker.shared.reject(id: full.id)
        XCTAssertTrue(ok)
        let body = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(body, "original")
        await HunkTracker.shared.clear(conversationID: convo)
    }
}
