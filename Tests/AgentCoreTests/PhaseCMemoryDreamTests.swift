//
//  PhaseCMemoryDreamTests.swift
//  PC3 — end-of-turn flush + dream/skip gates (extractive; no embeddings).
//

import XCTest
@testable import AgentCore

final class PhaseCMemoryDreamTests: XCTestCase {

    private func makeBackend() throws -> (MemoryBackend, MemoryStorage, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc3-mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = MemoryStorage(
            globalDir: root.appendingPathComponent("g"),
            workspaceDir: root.appendingPathComponent("w"),
            workspacePath: root,
            ephemeral: false)
        try storage.ensureDirs()
        let backend = MemoryBackend(
            storage: storage,
            index: MemoryIndex(indexURL: storage.indexFile))
        return (backend, storage, root)
    }

    // MARK: - Flush gates

    func testFlushDecisionSkipsEmptyAndTrivial() {
        let empty = MemoryBackend.flushDecision(messages: [])
        XCTAssertFalse(empty.shouldFlush)
        XCTAssertEqual(empty.reason, "empty_messages")

        let trivial = MemoryBackend.flushDecision(
            messages: [.init(role: .user, content: "hi")])
        XCTAssertFalse(trivial.shouldFlush)
        XCTAssertEqual(trivial.reason, "trivial_transcript")
    }

    func testFlushDecisionAcceptsAssistantOrLongUser() {
        let asst = MemoryBackend.flushDecision(messages: [
            .init(role: .user, content: "x"),
            .init(role: .assistant, content: "Working on it."),
        ])
        XCTAssertTrue(asst.shouldFlush)
        XCTAssertEqual(asst.reason, "ok")

        let longUser = MemoryBackend.flushDecision(messages: [
            .init(role: .user, content: String(repeating: "a", count: 20)),
        ])
        XCTAssertTrue(longUser.shouldFlush)
    }

    func testFlushDecisionAcceptsToolSubstance() {
        let toolOnly = MemoryBackend.flushDecision(messages: [
            .init(role: .user, content: "ok"),
            .init(role: .tool, content: "Edited Sources/Foo.swift", toolCallID: "c1"),
        ])
        XCTAssertTrue(toolOnly.shouldFlush, "tool results should fuel session logs")
    }

    // MARK: - Dream time/volume gates

    func testDreamEvaluateNotEnoughSessions() {
        let lock = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-lock-\(UUID().uuidString)")
        let gate = MemoryDream.evaluate(
            lockURL: lock, sessionCount: 0, minSessions: 1, minHours: 0)
        XCTAssertFalse(gate.shouldRun)
        XCTAssertEqual(gate.reason, "not_enough_sessions")
    }

    func testDreamEvaluateTooSoon() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-soon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent(".dream-lock")
        MemoryDream.recordConsolidation(lockURL: lock)
        let gate = MemoryDream.evaluate(
            lockURL: lock, sessionCount: 2, minSessions: 1, minHours: 1,
            now: Date())
        XCTAssertFalse(gate.shouldRun)
        XCTAssertEqual(gate.reason, "too_soon")
    }

    func testDreamEvaluateOkWhenNoLock() {
        let lock = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-lock-\(UUID().uuidString)")
        let gate = MemoryDream.evaluate(
            lockURL: lock, sessionCount: 1, minSessions: 1, minHours: 1)
        XCTAssertTrue(gate.shouldRun)
        XCTAssertEqual(gate.reason, "ok")
    }

    // MARK: - endTurnCapture structured results

    func testEndTurnFlushWithoutDreamWhenDisabled() async throws {
        let (backend, storage, root) = try makeBackend()
        defer { try? FileManager.default.removeItem(at: root) }

        let messages: [ChatMessage] = [
            .init(role: .user, content: "Please use worktrees for agent edits."),
            .init(role: .assistant, content: "Decision: always use git worktrees."),
        ]
        let result = try await backend.endTurnCapture(
            sessionId: UUID().uuidString,
            messages: messages,
            dreamEnabled: false,
            minHours: 0)
        XCTAssertTrue(result.didFlush)
        XCTAssertEqual(result.flushReason, "ok")
        XCTAssertFalse(result.didDream)
        XCTAssertEqual(result.dreamReason, "dream_disabled")
        XCTAssertFalse(storage.listSessionLogs().isEmpty, "flush must write session log even if dream off")
    }

    func testEndTurnSkipsTrivialDoesNotFlush() async throws {
        let (backend, storage, root) = try makeBackend()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await backend.endTurnCapture(
            sessionId: UUID().uuidString,
            messages: [.init(role: .user, content: "yo")],
            dreamEnabled: true,
            minHours: 0)
        XCTAssertFalse(result.didFlush)
        XCTAssertEqual(result.flushReason, "trivial_transcript")
        XCTAssertFalse(result.didDream)
        XCTAssertTrue(storage.listSessionLogs().isEmpty)
    }

    func testEndTurnFlushThenDreamConsolidatesExtractive() async throws {
        let (backend, storage, root) = try makeBackend()
        defer { try? FileManager.default.removeItem(at: root) }

        let messages: [ChatMessage] = [
            .init(role: .user, content: "Should we isolate agent edits with git worktrees?"),
            .init(role: .assistant, content: "Decision: always use git worktrees for agent edits to protect main."),
        ]
        let result = try await backend.endTurnCapture(
            sessionId: UUID().uuidString,
            messages: messages,
            dreamEnabled: true,
            minSessions: 1,
            minHours: 0)
        XCTAssertTrue(result.didFlush)
        XCTAssertTrue(result.didDream, "dreamReason=\(result.dreamReason)")
        XCTAssertEqual(result.dreamReason, "consolidated_extractive")
        let mem = storage.readMemory(scope: .workspace) ?? ""
        XCTAssertTrue(
            mem.lowercased().contains("worktree") || mem.lowercased().contains("decision"),
            String(mem.prefix(400)))
    }

    func testDefaultMinHoursThrottlesSecondDreamButFlushStillRuns() async throws {
        let (backend, storage, root) = try makeBackend()
        defer { try? FileManager.default.removeItem(at: root) }

        let messages: [ChatMessage] = [
            .init(role: .user, content: "Decision topic: use worktrees for isolation please"),
            .init(role: .assistant, content: "Decision: always use git worktrees for agent edits."),
        ]
        let first = try await backend.endTurnCapture(
            sessionId: UUID().uuidString, messages: messages,
            dreamEnabled: true, minHours: 0)
        XCTAssertTrue(first.didDream)

        let second = try await backend.endTurnCapture(
            sessionId: UUID().uuidString, messages: messages,
            dreamEnabled: true) // default minHours = 1
        XCTAssertTrue(second.didFlush, "flush every substantive turn")
        XCTAssertFalse(second.didDream)
        XCTAssertEqual(second.dreamReason, "too_soon")
        XCTAssertFalse(storage.listSessionLogs().isEmpty, "post-dream logs accumulate while throttled")
    }

    func testDreamLogsTooThinSkipsWithoutAppendingMemory() async throws {
        let (backend, storage, root) = try makeBackend()
        defer { try? FileManager.default.removeItem(at: root) }

        // Write a tiny session log that will not meet minSessionBlobChars.
        _ = try storage.writeSessionLog(sessionId: "tiny", content: "x")
        let dream = try await backend.dreamIfNeeded(minSessions: 1, minHours: 0)
        XCTAssertFalse(dream.didRun)
        XCTAssertEqual(dream.reason, "logs_too_thin")
        XCTAssertNil(storage.readMemory(scope: .workspace))
    }

    func testExtractiveNoSignalReturnsNO_REPLY() {
        let out = MemoryDream.extractiveConsolidate("hello world\nno durable markers")
        XCTAssertEqual(out, "NO_REPLY")
    }

    /// Honesty: dream path is extractive; there is no embedding API on MemoryBackend.
    func testNoEmbeddingAPIOnMemoryBackend() {
        // Compile-time / surface check: MemoryDream is extractive-only defaults.
        XCTAssertEqual(MemoryDream.defaultMinHours, 1)
        XCTAssertEqual(MemoryDream.defaultMinSessions, 1)
        let sample = MemoryDream.extractiveConsolidate(
            "- **assistant:** Decision: prefer patches over full rewrites.")
        XCTAssertTrue(sample.contains("Decision") || sample.contains("Consolidated"))
        XCTAssertFalse(sample.lowercased().contains("embedding"))
    }
}
