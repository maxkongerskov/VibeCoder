//
//  GrokPortCompactionTests.swift
//

import XCTest
@testable import AgentCore

final class GrokPortCompactionTests: XCTestCase {

    func testFullReplaceCompactsLongHistoryAndKeepsDecision() async {
        var messages: [ChatMessage] = []
        messages.append(.init(role: .user, content: "Build a calculator app"))
        messages.append(.init(
            role: .assistant,
            content: "I will decide to use SwiftUI for the calculator UI."))
        for i in 0..<30 {
            messages.append(.init(
                role: .user,
                content: "Continue step \(i) with lots of padding " + String(repeating: "x", count: 200)))
            messages.append(.init(
                role: .assistant,
                content: "Working on step \(i) " + String(repeating: "y", count: 200)))
        }
        messages.append(.init(role: .user, content: "What UI framework did we pick?"))

        let result = await FullReplaceCompactor.compact(
            messages,
            systemPromptTokens: 100,
            budgetTokens: 800,
            keepRecent: 4)

        XCTAssertGreaterThan(result.droppedCount, 0, "should drop older turns")
        // Must retain the planted SwiftUI decision in durableNote (not just template tokens)
        let durable = result.durableNote.lowercased()
        XCTAssertTrue(
            durable.contains("swiftui"),
            "durableNote must contain planted SwiftUI decision, got: \(result.durableNote)")
        XCTAssertFalse(result.durableNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testExtractDurableNoteCapturesDecideWillLines() {
        let older = [
            ChatMessage(role: .assistant, content: "I will decide to use SwiftUI for the calculator UI.")
        ]
        let summary = """
        [full-replace summary]
        hint: Preserve decisions
        current_goal: Build a calculator
        decisions:
          - I will decide to use SwiftUI for the calculator UI.
        note: recent turns after this summary are verbatim.
        """
        let note = FullReplaceCompactor.extractDurableNote(from: summary, older: older)
        XCTAssertTrue(note.lowercased().contains("swiftui"), "got: \(note)")
    }

    func testFlushMarkRecoveryInjectSurfacesPlantedDecision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("compact-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = MemoryStorage(
            globalDir: root.appendingPathComponent("g"),
            workspaceDir: root.appendingPathComponent("w"),
            workspacePath: root,
            ephemeral: false)
        try storage.ensureDirs()
        let backend = MemoryBackend(storage: storage, index: MemoryIndex(indexURL: storage.indexFile))

        let planted = "Decision: always use git worktrees for agent edits to protect main."
        let history = [
            ChatMessage(role: .user, content: "How should agents edit?"),
            ChatMessage(role: .assistant, content: planted),
        ]
        try backend.flushConversation(
            sessionId: UUID().uuidString,
            messages: history,
            plantedNote: planted)

        // Simulate compact recovery path used by AgentLoop
        backend.markCompactionRecovery(planted)
        let recovery = backend.injectRecovery(query: "worktree agent edits")
        XCTAssertNotNil(recovery)
        XCTAssertTrue(
            recovery!.lowercased().contains("worktree"),
            "recovery inject must surface planted decision: \(recovery!)")

        // Search path must also find it after reindex
        let hits = backend.search(query: "worktree agent edits", maxResults: 5)
        XCTAssertFalse(hits.isEmpty, "search should find planted recovery/session content")
        let blob = hits.map(\.snippet).joined(separator: " ").lowercased()
        XCTAssertTrue(blob.contains("worktree") || blob.contains("agent"), "got: \(blob)")
    }

    func testShouldCompactThreshold() {
        let msgs = (0..<20).map { i in
            ChatMessage(role: .user, content: String(repeating: "word ", count: 50) + "\(i)")
        }
        let over = FullReplaceCompactor.shouldCompact(
            messages: msgs, systemPromptTokens: 100, budgetTokens: 200, thresholdFraction: 0.5)
        XCTAssertTrue(over)
        let under = FullReplaceCompactor.shouldCompact(
            messages: Array(msgs.prefix(1)), systemPromptTokens: 10, budgetTokens: 100_000)
        XCTAssertFalse(under)
    }
}
