//
//  ResumeReadTrackerTests.swift
//
//  Read-before-edit is stored in the in-memory SessionReadTracker actor
//  and persisted on Conversation.sessionReadPaths. AgentLoop seeds the
//  tracker from that set and passes it on ToolContext. These tests prove
//  store hydrate after a simulated process restart, and that an empty
//  tracker fails closed (does not skip the guard).
//

import XCTest
@testable import AgentCore

final class ResumeReadTrackerTests: XCTestCase {

    private var root: URL!
    private var storeDir: URL!
    private var registry: ToolRegistry!
    private var conversationID: UUID!
    private var extraIDs: [UUID] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-rbe-\(UUID().uuidString)", isDirectory: true)
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        conversationID = UUID()
        extraIDs = []
        registry = ToolRegistry.shared
        await registry.registerBuiltins()
    }

    override func tearDown() async throws {
        if let conversationID {
            await SessionReadTracker.shared.clear(conversationID: conversationID)
            await SkillToolGate.shared.clear(conversationID: conversationID)
        }
        for id in extraIDs {
            await SessionReadTracker.shared.clear(conversationID: id)
            await SkillToolGate.shared.clear(conversationID: id)
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        if let storeDir { try? FileManager.default.removeItem(at: storeDir) }
    }

    /// Tracker-only ToolContext: empty sessionReadPaths so hydrate/fail-closed
    /// is proven on SessionReadTracker, not the ToolContext field AgentLoop now seeds.
    private func productionContext(conversationID: UUID? = nil) -> ToolContext {
        ToolContext(
            projectRoot: root,
            conversationID: conversationID ?? self.conversationID,
            executionMode: .yolo
        )
    }

    private func writeExisting(_ name: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func readFile(_ name: String, conversationID: UUID? = nil) async throws -> ToolResult {
        try await registry.execute(
            name: "read_file",
            arguments: ToolArguments(dictionary: ["path": name]),
            context: productionContext(conversationID: conversationID))
    }

    private func editReplace(
        _ name: String,
        search: String,
        replace: String,
        conversationID: UUID? = nil
    ) async throws -> ToolResult {
        let edits = """
        <<<<<<< SEARCH
        \(search)
        =======
        \(replace)
        >>>>>>> REPLACE
        """
        return try await registry.execute(
            name: "edit_file",
            arguments: ToolArguments(dictionary: ["path": name, "edits": edits]),
            context: productionContext(conversationID: conversationID))
    }

    private func overwrite(_ name: String, content: String) async throws -> ToolResult {
        try await registry.execute(
            name: "write_file",
            arguments: ToolArguments(dictionary: ["path": name, "content": content]),
            context: productionContext())
    }

    private func applyPatchExisting(_ name: String, from: String, to: String) async throws -> ToolResult {
        let patch = """
        --- a/\(name)
        +++ b/\(name)
        @@ -1 +1 @@
        -\(from)
        +\(to)
        """
        return try await registry.execute(
            name: "apply_patch",
            arguments: ToolArguments(dictionary: ["patch": patch]),
            context: productionContext())
    }

    // MARK: - Same-process reload

    func testSameProcessReloadWithEmptySessionReadPathsStillAllowsEdit() async throws {
        let file = try writeExisting("keep.swift", contents: "let x = 1\n")
        let read = try await readFile("keep.swift")
        XCTAssertFalse(read.isError, read.content)

        // New ToolContext, empty sessionReadPaths — same conversation id, no actor reset.
        let edited = try await editReplace("keep.swift", search: "let x = 1", replace: "let x = 2")
        XCTAssertFalse(edited.isError, edited.content)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let x = 2\n")
    }

    // MARK: - Guard does not skip when tracker is empty

    func testActorResetWithoutHydrateFailsClosedOnEditWriteAndPatch() async throws {
        let editFile = try writeExisting("a.swift", contents: "aaa\n")
        let writeFile = try writeExisting("b.swift", contents: "bbb\n")
        let patchFile = try writeExisting("c.swift", contents: "ccc\n")

        let readA = try await readFile("a.swift")
        let readB = try await readFile("b.swift")
        let readC = try await readFile("c.swift")
        XCTAssertFalse(readA.isError, readA.content)
        XCTAssertFalse(readB.isError, readB.content)
        XCTAssertFalse(readC.isError, readC.content)

        await SessionReadTracker.shared.clear(conversationID: conversationID)

        let edited = try await editReplace("a.swift", search: "aaa", replace: "AAA")
        XCTAssertTrue(edited.isError, "empty tracker must deny edit, not skip the guard")
        XCTAssertTrue(edited.content.lowercased().contains("read-before-edit"), edited.content)
        XCTAssertEqual(try String(contentsOf: editFile, encoding: .utf8), "aaa\n")

        let written = try await overwrite("b.swift", content: "BBB\n")
        XCTAssertTrue(written.isError, "empty tracker must deny write_file overwrite")
        XCTAssertTrue(written.content.lowercased().contains("read-before-edit"), written.content)
        XCTAssertEqual(try String(contentsOf: writeFile, encoding: .utf8), "bbb\n")

        let patched = try await applyPatchExisting("c.swift", from: "ccc", to: "CCC")
        XCTAssertTrue(patched.isError, "empty tracker must deny apply_patch")
        XCTAssertTrue(patched.content.lowercased().contains("read-before-edit"), patched.content)
        XCTAssertEqual(try String(contentsOf: patchFile, encoding: .utf8), "ccc\n")
    }

    func testUnsavedMidTurnReadsFailClosedAfterSimulatedCrash() async throws {
        let file = try writeExisting("unsaved.swift", contents: "old\n")
        let read = try await readFile("unsaved.swift")
        XCTAssertFalse(read.isError, read.content)
        // No ConversationStore.save — process death drops the in-memory actor.
        await SessionReadTracker.shared.clear(conversationID: conversationID)
        let edited = try await editReplace("unsaved.swift", search: "old", replace: "new")
        XCTAssertTrue(edited.isError, "unsaved reads must not survive a crash")
        XCTAssertTrue(edited.content.lowercased().contains("read-before-edit"), edited.content)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old\n")
    }

    // MARK: - Conversation persist / restore

    func testConversationJSONWithoutSessionReadPathsStillDecodes() async throws {
        let json = """
        {
          "id": "\(conversationID.uuidString)",
          "title": "legacy",
          "createdAt": "2024-01-01T00:00:00Z",
          "updatedAt": "2024-01-01T00:00:00Z",
          "messages": []
        }
        """
        try json.write(
            to: storeDir.appendingPathComponent("\(conversationID.uuidString).json"),
            atomically: true,
            encoding: .utf8)
        let loaded = try await ConversationStore(directory: storeDir).load(id: conversationID)
        XCTAssertNotNil(loaded, "legacy conversation JSON must still decode")
        XCTAssertTrue(loaded?.sessionReadPaths.isEmpty ?? false)
        XCTAssertEqual(loaded?.id, conversationID)
    }

    func testConversationStoreRoundTripRestoresReadsSoMutationsSucceed() async throws {
        let editFile = try writeExisting("resume.swift", contents: "old\n")
        let writeFile = try writeExisting("resume.txt", contents: "keep\n")
        let patchFile = try writeExisting("resume.patchme", contents: "one\n")

        let readSwift = try await readFile("resume.swift")
        let readTxt = try await readFile("resume.txt")
        let readPatch = try await readFile("resume.patchme")
        XCTAssertFalse(readSwift.isError, readSwift.content)
        XCTAssertFalse(readTxt.isError, readTxt.content)
        XCTAssertFalse(readPatch.isError, readPatch.content)

        let live = await SessionReadTracker.shared.paths(for: conversationID)
        XCTAssertFalse(live.isEmpty, "read_file must record paths on the tracker")

        let store = ConversationStore(directory: storeDir)
        var convo = Conversation(id: conversationID, title: "resume", projectRoot: root)
        try await store.save(convo)

        let onDisk = try String(
            contentsOf: storeDir.appendingPathComponent("\(conversationID.uuidString).json"),
            encoding: .utf8)
        XCTAssertTrue(
            onDisk.contains("sessionReadPaths"),
            "save must persist recorded reads: \(onDisk)")

        // Process death: in-memory actor is empty. Guard must deny until hydrate.
        await SessionReadTracker.shared.clear(conversationID: conversationID)
        let unrestored = try await editReplace("resume.swift", search: "old", replace: "new")
        XCTAssertTrue(unrestored.isError, unrestored.content)
        XCTAssertEqual(try String(contentsOf: editFile, encoding: .utf8), "old\n")

        let loaded = try await store.load(id: conversationID)
        XCTAssertNotNil(loaded)
        convo = try XCTUnwrap(loaded)
        XCTAssertFalse(
            convo.sessionReadPaths.isEmpty,
            "loaded conversation must carry persisted read paths")

        let restored = await SessionReadTracker.shared.hasSessionRead(
            path: editFile.path,
            conversationID: conversationID,
            sessionReadPaths: [])
        XCTAssertTrue(restored, "load must seed SessionReadTracker")

        // Different replace text than the unrestored probe: ToolRegistry
        // records the denied edit_file signature and would bounce an identical retry.
        let edited = try await editReplace("resume.swift", search: "old", replace: "restored")
        XCTAssertFalse(edited.isError, edited.content)
        XCTAssertEqual(try String(contentsOf: editFile, encoding: .utf8), "restored\n")

        let written = try await overwrite("resume.txt", content: "changed\n")
        XCTAssertFalse(written.isError, written.content)
        XCTAssertEqual(try String(contentsOf: writeFile, encoding: .utf8), "changed\n")

        let patched = try await applyPatchExisting("resume.patchme", from: "one", to: "two")
        XCTAssertFalse(patched.isError, patched.content)
        XCTAssertEqual(try String(contentsOf: patchFile, encoding: .utf8), "two\n")
    }

    func testListDirectoryAlsoHydratesTracker() async throws {
        let file = try writeExisting("listed.swift", contents: "x = 1\n")
        let listedRead = try await readFile("listed.swift")
        XCTAssertFalse(listedRead.isError, listedRead.content)

        let store = ConversationStore(directory: storeDir)
        try await store.save(Conversation(id: conversationID, title: "listed", projectRoot: root))
        await SessionReadTracker.shared.clear(conversationID: conversationID)

        let listing = try await store.listDirectory()
        XCTAssertEqual(listing.conversations.map(\.id), [conversationID])

        let ok = await SessionReadTracker.shared.hasSessionRead(
            path: file.path,
            conversationID: conversationID,
            sessionReadPaths: [])
        XCTAssertTrue(ok, "listDirectory must rehydrate reads (sidebar load on launch)")

        let edited = try await editReplace("listed.swift", search: "x = 1", replace: "x = 2")
        XCTAssertFalse(edited.isError, edited.content)
    }

    func testIsolationLoadADoesNotGrantReadsToB() async throws {
        let idB = UUID()
        extraIDs.append(idB)
        let file = try writeExisting("shared.swift", contents: "let v = 1\n")
        let read = try await readFile("shared.swift", conversationID: conversationID)
        XCTAssertFalse(read.isError, read.content)

        let store = ConversationStore(directory: storeDir)
        try await store.save(Conversation(id: conversationID, title: "A", projectRoot: root))
        try await store.save(Conversation(id: idB, title: "B", projectRoot: root))

        await SessionReadTracker.shared.clear(conversationID: conversationID)
        await SessionReadTracker.shared.clear(conversationID: idB)

        let loadedA = try await store.load(id: conversationID)
        XCTAssertFalse(loadedA?.sessionReadPaths.isEmpty ?? true)

        let aOk = await SessionReadTracker.shared.hasSessionRead(
            path: file.path, conversationID: conversationID, sessionReadPaths: [])
        let bOk = await SessionReadTracker.shared.hasSessionRead(
            path: file.path, conversationID: idB, sessionReadPaths: [])
        XCTAssertTrue(aOk, "conversation A must regain its read")
        XCTAssertFalse(bOk, "conversation B must not inherit A's reads")

        let denied = try await editReplace(
            "shared.swift", search: "let v = 1", replace: "let v = 2", conversationID: idB)
        XCTAssertTrue(denied.isError, denied.content)
        XCTAssertTrue(denied.content.lowercased().contains("read-before-edit"), denied.content)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let v = 1\n")

        let allowed = try await editReplace(
            "shared.swift", search: "let v = 1", replace: "let v = 2", conversationID: conversationID)
        XCTAssertFalse(allowed.isError, allowed.content)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let v = 2\n")
    }

    func testEmptyJSONLoadDoesNotWipeLiveTracker() async throws {
        let file = try writeExisting("live.swift", contents: "keep\n")
        let read = try await readFile("live.swift")
        XCTAssertFalse(read.isError, read.content)

        let json = """
        {
          "id": "\(conversationID.uuidString)",
          "title": "legacy-empty",
          "createdAt": "2024-01-01T00:00:00Z",
          "updatedAt": "2024-01-01T00:00:00Z",
          "messages": []
        }
        """
        try json.write(
            to: storeDir.appendingPathComponent("\(conversationID.uuidString).json"),
            atomically: true,
            encoding: .utf8)

        let loaded = try await ConversationStore(directory: storeDir).load(id: conversationID)
        XCTAssertTrue(loaded?.sessionReadPaths.isEmpty ?? false)

        let stillLive = await SessionReadTracker.shared.hasSessionRead(
            path: file.path, conversationID: conversationID, sessionReadPaths: [])
        XCTAssertTrue(stillLive, "empty persisted set must not wipe live tracker reads")

        let edited = try await editReplace("live.swift", search: "keep", replace: "kept")
        XCTAssertFalse(edited.isError, edited.content)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "kept\n")
    }

    func testDeleteClearsTrackerAndSkillToolGate() async throws {
        let file = try writeExisting("gone.swift", contents: "x\n")
        await SessionReadTracker.shared.recordRead(path: file.path, conversationID: conversationID)
        await SkillToolGate.shared.record(
            allowedTools: ["read_file"], conversationID: conversationID)
        let gated = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertNotNil(gated)

        let store = ConversationStore(directory: storeDir)
        try await store.save(Conversation(id: conversationID, title: "del", projectRoot: root))
        try await store.delete(id: conversationID)

        let has = await SessionReadTracker.shared.hasSessionRead(
            path: file.path, conversationID: conversationID, sessionReadPaths: [])
        XCTAssertFalse(has, "delete must clear SessionReadTracker")
        let gate = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertNil(gate, "delete must clear SkillToolGate")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storeDir.appendingPathComponent("\(conversationID.uuidString).json").path))
    }

    func testDeleteMissingFileStillClearsTrackerAndGate() async throws {
        let file = try writeExisting("orphan.swift", contents: "y\n")
        await SessionReadTracker.shared.recordRead(path: file.path, conversationID: conversationID)
        await SkillToolGate.shared.record(
            allowedTools: ["list_directory"], conversationID: conversationID)
        let gated = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertNotNil(gated)

        try await ConversationStore(directory: storeDir).delete(id: conversationID)

        let has = await SessionReadTracker.shared.hasSessionRead(
            path: file.path, conversationID: conversationID, sessionReadPaths: [])
        XCTAssertFalse(has)
        let after = await SkillToolGate.shared.allowlist(for: conversationID)
        XCTAssertNil(after)
    }

    func testSaveNormalizesSessionReadPathsAndAvoidsSetCodable() async throws {
        let trailing = root.appendingPathComponent("norm.swift").path + "/"
        let convo = Conversation(
            id: conversationID,
            title: "norm",
            projectRoot: root,
            sessionReadPaths: [trailing, trailing])
        let store = ConversationStore(directory: storeDir)
        try await store.save(convo)

        let onDisk = try String(
            contentsOf: storeDir.appendingPathComponent("\(conversationID.uuidString).json"),
            encoding: .utf8)
        XCTAssertTrue(onDisk.contains("sessionReadPaths"), onDisk)
        XCTAssertFalse(onDisk.contains(trailing), "disk must not keep the trailing slash: \(onDisk)")

        await SessionReadTracker.shared.clear(conversationID: conversationID)
        let loaded = try await store.load(id: conversationID)
        let loadedConvo = try XCTUnwrap(loaded)
        let expected = SafeModeConfig.normalizePath(trailing)
        XCTAssertEqual(loadedConvo.sessionReadPaths, [expected])

        // Rebuilding Set from the JSON array must not crash (the Set Codable SIGSEGV).
        let again = try ConversationSessionReadCodec.decode(
            Data(onDisk.utf8))
        XCTAssertEqual(again.sessionReadPaths, [expected])
        let encoded = try ConversationSessionReadCodec.encode(again)
        XCTAssertFalse(encoded.isEmpty)
    }
}
