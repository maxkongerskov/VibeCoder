//
//  BugHuntMemoryConversationTests.swift
//
//  Verification-first hunts for Memory / Notes / Conversation / Persistence.
//  Uses isolated temp directories. Does not mutate production code.
//

import XCTest
@testable import AgentCore

final class BugHuntMemoryConversationTests: XCTestCase {

    private func makeTempDir(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStorage(in root: URL, ephemeral: Bool = false) throws -> MemoryStorage {
        let storage = MemoryStorage(
            globalDir: root.appendingPathComponent("g", isDirectory: true),
            workspaceDir: root.appendingPathComponent("w", isDirectory: true),
            workspacePath: root,
            ephemeral: ephemeral)
        try storage.ensureDirs()
        return storage
    }

    // MARK: - MemoryIndex.upsert lock

    func testUpsertReleasesLockSoCountDoesNotHang() throws {
        let root = try makeTempDir("bh-upsert-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        let index = MemoryIndex(indexURL: root.appendingPathComponent("index.jsonl"))
        index.upsert(MemoryChunk(path: "tool://x", source: "tool", text: "lock-probe fact"))

        let exp = expectation(description: "count after upsert")
        DispatchQueue.global().async {
            _ = index.count
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testMarkCompactionRecoveryDoesNotDeadlockInjectRecovery() throws {
        let root = try makeTempDir("bh-recovery-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try makeStorage(in: root)
        let backend = MemoryBackend(storage: storage, index: MemoryIndex(indexURL: storage.indexFile))
        backend.markCompactionRecovery("Decision: keep worktree isolation.")

        let exp = expectation(description: "injectRecovery after markCompactionRecovery")
        DispatchQueue.global().async {
            _ = backend.injectRecovery(query: "worktree isolation")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - MemoryIndex persist

    func testUpsertManyPersistsAcrossNewMemoryIndex() throws {
        let root = try makeTempDir("bh-upsert-persist")
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.jsonl")
        let index = MemoryIndex(indexURL: indexURL)
        let chunk = MemoryChunk(
            path: "tool://memory",
            source: "tool",
            text: "PERSIST_MARKER_tool_fact_okapi")
        index.upsertMany([chunk])
        XCTAssertEqual(index.count, 1)

        let reloaded = MemoryIndex(indexURL: indexURL)
        XCTAssertEqual(
            reloaded.count, 1,
            "upsertMany must persist index.jsonl; reload saw \(reloaded.count) chunks")
        XCTAssertTrue(
            reloaded.allChunks().contains { $0.text.contains("okapi") },
            "reloaded index missing upserted tool fact")
    }

    func testRememberPersistsIndexWithoutReindex() throws {
        let root = try makeTempDir("bh-remember-persist")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try makeStorage(in: root)
        let backend = MemoryBackend(storage: storage, index: MemoryIndex(indexURL: storage.indexFile))
        try backend.remember(
            text: "Decision: persist-index-marker wombat isolation.",
            scope: .workspace)
        XCTAssertGreaterThan(backend.index.count, 0)

        let reloaded = MemoryIndex(indexURL: storage.indexFile)
        XCTAssertGreaterThan(
            reloaded.count, 0,
            "remember() must persist index.jsonl so a new MemoryIndex can search without reindex")
    }

    func testReindexToEmptyMustClearStaleIndexFile() throws {
        let root = try makeTempDir("bh-empty-persist")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try makeStorage(in: root)
        let stale = MemoryChunk(
            path: "stale.md",
            source: "workspace",
            text: "STALE_CHUNK_quokka_should_not_survive")
        let line = String(data: try JSONEncoder().encode(stale), encoding: .utf8)! + "\n"
        try line.write(to: storage.indexFile, atomically: true, encoding: .utf8)

        let index = MemoryIndex(indexURL: storage.indexFile)
        XCTAssertEqual(index.count, 1)
        index.reindex(storage: storage)
        XCTAssertEqual(index.count, 0, "in-memory index should drop file-backed chunks that disappeared")

        let reloaded = MemoryIndex(indexURL: storage.indexFile)
        XCTAssertEqual(
            reloaded.count, 0,
            "persist() skipped empty snapshot; stale index.jsonl reloaded \(reloaded.count) chunk(s): \(reloaded.allChunks().map(\.text))")
    }

    // MARK: - MemoryIndex reindex / decay

    func testReindexPreservesCreatedAtSoDecayStillApplies() throws {
        let root = try makeTempDir("bh-decay")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try makeStorage(in: root)
        try storage.appendMemory(
            scope: .workspace,
            text: "UNIQUE_DECAY_TOKEN platypus constraint for agent edits.")

        let index = MemoryIndex(indexURL: storage.indexFile)
        index.reindex(storage: storage)
        let live = index.allChunks().filter { $0.text.contains("UNIQUE_DECAY_TOKEN") }
        XCTAssertFalse(live.isEmpty, "expected reindexed workspace chunk")

        let agedEpoch = Date().timeIntervalSince1970 - 200 * 86_400
        let aged = live.map { chunk -> MemoryChunk in
            var copy = chunk
            copy.createdAt = agedEpoch
            return copy
        }
        let enc = JSONEncoder()
        var body = ""
        for chunk in aged {
            body += String(data: try enc.encode(chunk), encoding: .utf8)! + "\n"
        }
        try body.write(to: storage.indexFile, atomically: true, encoding: .utf8)

        let agedIndex = MemoryIndex(indexURL: storage.indexFile)
        let before = agedIndex.allChunks().first { $0.text.contains("UNIQUE_DECAY_TOKEN") }
        XCTAssertNotNil(before)
        XCTAssertLessThan(before!.createdAt, Date().timeIntervalSince1970 - 100 * 86_400)

        agedIndex.reindex(storage: storage)
        let after = agedIndex.allChunks().first { $0.text.contains("UNIQUE_DECAY_TOKEN") }
        XCTAssertNotNil(after)
        XCTAssertLessThan(
            after!.createdAt,
            Date().timeIntervalSince1970 - 100 * 86_400,
            "reindex reset createdAt to \(after!.createdAt) (now=\(Date().timeIntervalSince1970)); 200-day decay is wiped on every reindex")
    }

    // MARK: - MemoryStorage atomicity

    func testAppendMemoryConcurrentWritesAreNotLost() async throws {
        let root = try makeTempDir("bh-append-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try makeStorage(in: root)
        let n = 40
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    try storage.appendMemory(scope: .workspace, text: "CONCURRENT_MARKER_\(i)_END")
                }
            }
            try await group.waitForAll()
        }
        let mem = storage.readMemory(scope: .workspace) ?? ""
        let missing = (0..<n).filter { !mem.contains("CONCURRENT_MARKER_\($0)_END") }
        XCTAssertTrue(
            missing.isEmpty,
            "appendMemory lost \(missing.count)/\(n) concurrent writes: \(missing.prefix(12))")
    }

    func testAppendMemoryDoesNotWipeExistingNonUTF8File() throws {
        let root = try makeTempDir("bh-append-utf8")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try makeStorage(in: root)
        try storage.ensureDirs()
        let raw = Data([0xFF, 0xFE, 0x00, 0x48, 0x00, 0x69])
        try raw.write(to: storage.workspaceMemoryFile)
        XCTAssertThrowsError(try storage.appendMemory(scope: .workspace, text: "NEW_BLOCK_SHOULD_NOT_CLOBBER"))
        let after = try Data(contentsOf: storage.workspaceMemoryFile)
        XCTAssertEqual(after, raw, "appendMemory must preserve a non-UTF8 MEMORY.md")
    }

    func testWorkspacePathContainingSlashTIsNotEphemeral() throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let project = caches
            .appendingPathComponent("bh-slashT-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("T", isDirectory: true)
            .appendingPathComponent("project", isDirectory: true)
        let memRoot = caches.appendingPathComponent("bh-slashT-mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent().deletingLastPathComponent())
            try? FileManager.default.removeItem(at: memRoot)
        }

        XCTAssertTrue(project.path.contains("/T/"))
        XCTAssertFalse(project.path.hasPrefix(NSTemporaryDirectory()))

        let storage = MemoryStorage(workspacePath: project, root: memRoot)
        XCTAssertFalse(
            storage.ephemeral,
            "path \(project.path) must not be treated as ephemeral because it contains /T/")
        try storage.appendMemory(scope: .workspace, text: "SLASH_T_MUST_PERSIST")
        let read = storage.readMemory(scope: .workspace) ?? ""
        XCTAssertTrue(
            read.contains("SLASH_T_MUST_PERSIST"),
            "workspace append was dropped for a normal project path containing /T/")
    }

    // MARK: - Conversation decode / encode

    func testUnknownMessageRoleDoesNotDropConversation() async throws {
        let dir = try makeTempDir("bh-convo-role")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationStore(directory: dir)
        let id = UUID()
        let msgId = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "legacy-role",
          "createdAt": "2024-01-01T00:00:00Z",
          "updatedAt": "2024-01-01T00:00:00Z",
          "messages": [
            {
              "id": "\(msgId.uuidString)",
              "role": "function",
              "content": "ROLE_KEEP_ME_visible_tool_result",
              "timestamp": "2024-01-01T00:00:00Z"
            }
          ]
        }
        """
        try json.write(
            to: dir.appendingPathComponent("\(id.uuidString).json"),
            atomically: true,
            encoding: .utf8)

        let loaded = try await store.load(id: id)
        XCTAssertNotNil(loaded, "unknown message role must not fail the whole conversation")
        XCTAssertEqual(loaded?.messages.count, 1)
        XCTAssertEqual(loaded?.messages.first?.content, "ROLE_KEEP_ME_visible_tool_result")

        let listed = try await store.list()
        XCTAssertEqual(listed.count, 1, "list() silently dropped conversation with unknown role")
    }

    func testFractionalISO8601DatesDoNotDropConversation() async throws {
        let dir = try makeTempDir("bh-convo-frac")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationStore(directory: dir)
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "frac-dates",
          "createdAt": "2024-06-01T12:00:00.250Z",
          "updatedAt": "2024-06-01T12:30:00.750Z",
          "messages": [
            {
              "id": "\(UUID().uuidString)",
              "role": "user",
              "content": "FRAC_DATE_KEEP",
              "timestamp": "2024-06-01T12:00:00.250Z"
            }
          ]
        }
        """
        try json.write(
            to: dir.appendingPathComponent("\(id.uuidString).json"),
            atomically: true,
            encoding: .utf8)

        let loaded = try await store.load(id: id)
        XCTAssertNotNil(loaded, "fractional ISO-8601 dates must not fail conversation decode")
        XCTAssertEqual(loaded?.messages.first?.content, "FRAC_DATE_KEEP")
        let listed = try await store.list()
        XCTAssertEqual(listed.count, 1, "list() dropped conversation whose dates have fractional seconds")
    }

    func testConversationStoreRoundTripPreservesTranscriptAndMeta() async throws {
        let dir = try makeTempDir("bh-convo-round")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationStore(directory: dir)
        let pin = StickyContextPinRecord(
            kind: "file", path: "/src/A.swift", displayName: "A.swift", symbolName: nil, byteSize: 12)
        let image = ChatImagePayload(
            mimeType: "image/png",
            base64Data: "iVBORw0KGgo=",
            sourcePath: "/tmp/shot.png",
            displayName: "shot.png")
        let convo = Conversation(
            title: "round-trip",
            messages: [
                ChatMessage(
                    role: .user,
                    content: "see image",
                    images: [image]),
                ChatMessage(
                    role: .assistant,
                    content: "ok",
                    reasoningContent: "think",
                    toolCalls: [ToolCallInvocation(id: "c1", name: "read_file", arguments: #"{"path":"A.swift"}"#)],
                    workDurationSeconds: 9,
                    thinkingDurationSeconds: 3),
                ChatMessage(role: .tool, content: "file body", toolCallID: "c1"),
            ],
            modelID: "local-model",
            projectRoot: URL(fileURLWithPath: "/Users/demo/Project"),
            worktreeBranch: "agentcore/abc",
            systemPromptOverride: "be brief",
            samplingOverride: SamplingParams(temperature: 0.2, maxTokens: 128),
            unlockedDeferredTools: ["tool_search"],
            pinned: true,
            archived: false,
            orchestratorBriefs: ["u1": "do the thing"],
            railUserPreference: true,
            attachedSkillIds: [UUID()],
            stickyContextPins: [pin])

        try await store.save(convo)
        let loaded = try await store.load(id: convo.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.title, "round-trip")
        XCTAssertEqual(loaded?.messages.count, 3)
        XCTAssertEqual(loaded?.messages[0].images.first?.base64Data, "iVBORw0KGgo=")
        XCTAssertEqual(loaded?.messages[1].reasoningContent, "think")
        XCTAssertEqual(loaded?.messages[1].toolCalls.first?.name, "read_file")
        XCTAssertEqual(loaded?.messages[1].workDurationSeconds, 9)
        XCTAssertEqual(loaded?.messages[2].toolCallID, "c1")
        XCTAssertEqual(loaded?.modelID, "local-model")
        XCTAssertEqual(loaded?.projectRoot?.path, "/Users/demo/Project")
        XCTAssertEqual(loaded?.worktreeBranch, "agentcore/abc")
        XCTAssertEqual(loaded?.systemPromptOverride, "be brief")
        XCTAssertEqual(loaded?.samplingOverride?.maxTokens, 128)
        XCTAssertEqual(loaded?.unlockedDeferredTools, ["tool_search"])
        XCTAssertEqual(loaded?.pinned, true)
        XCTAssertEqual(loaded?.orchestratorBriefs["u1"], "do the thing")
        XCTAssertEqual(loaded?.stickyContextPins.first?.path, "/src/A.swift")
        XCTAssertEqual(loaded?.attachedSkillIds, convo.attachedSkillIds)
    }

    func testConversationStoreSaveRecreatesDeletedDirectory() async throws {
        let dir = try makeTempDir("bh-convo-mkdir")
        let store = ConversationStore(directory: dir)
        try FileManager.default.removeItem(at: dir)
        let convo = Conversation(title: "after-rm")
        do {
            try await store.save(convo)
        } catch {
            XCTFail("save must recreate conversations directory, threw: \(error)")
            return
        }
        let loaded = try await store.load(id: convo.id)
        XCTAssertEqual(loaded?.title, "after-rm")
    }

    // MARK: - NoteStore

    func testNoteStoreSaveLoadDeleteRoundTrip() async throws {
        let dir = try makeTempDir("bh-notes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NoteStore(folderURL: dir)
        let note = Note(title: "Scratch", body: "path: /tmp/foo\n```swift\nlet x = 1\n```")
        await store.save(note)
        let all = await store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, note.id)
        XCTAssertEqual(all.first?.title, "Scratch")
        XCTAssertEqual(all.first?.body, note.body)
        await store.delete(note)
        let remaining = await store.loadAll()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testNoteStoreSaveRecreatesDeletedDirectory() async throws {
        let dir = try makeTempDir("bh-notes-mkdir")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NoteStore(folderURL: dir)
        try FileManager.default.removeItem(at: dir)
        let note = Note(title: "recreated", body: "body")
        await store.save(note)
        let all = await store.loadAll()
        XCTAssertEqual(all.count, 1, "NoteStore.save should recreate the notes folder")
        XCTAssertEqual(all.first?.title, "recreated")
    }

    // MARK: - PromptHistoryStore

    func testPromptHistoryRecordLoadDedupAndCap() async throws {
        let dir = try makeTempDir("bh-prompt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptHistoryStore(fileURL: dir.appendingPathComponent("prompt-history.json"))
        await store.record("   ")
        let empty = await store.load()
        XCTAssertTrue(empty.isEmpty)
        await store.record(" first ")
        await store.record("second")
        await store.record("first")
        let loaded = await store.load()
        XCTAssertEqual(loaded, ["first", "second"])
        let again = PromptHistoryStore(fileURL: dir.appendingPathComponent("prompt-history.json"))
        let againLoaded = await again.load()
        XCTAssertEqual(againLoaded, ["first", "second"])
    }

    func testPromptHistoryTwoStoresDoNotLoseRecords() async throws {
        let dir = try makeTempDir("bh-prompt-race")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prompt-history.json")
        let a = PromptHistoryStore(fileURL: url)
        let b = PromptHistoryStore(fileURL: url)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await a.record("alpha-unique") }
            group.addTask { await b.record("beta-unique") }
        }
        let loaded = await PromptHistoryStore(fileURL: url).load()
        XCTAssertTrue(loaded.contains("alpha-unique"), "lost alpha: \(loaded)")
        XCTAssertTrue(loaded.contains("beta-unique"), "lost beta: \(loaded)")
    }
}
