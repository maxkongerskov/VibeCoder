//
//  DepthD3MemoryConsolidatorTests.swift
//  D3 — optional LLM/inject consolidator with extractive fallback.
//

import XCTest
@testable import AgentCore

final class DepthD3MemoryConsolidatorTests: XCTestCase {

    private func makeBackend() throws -> (MemoryBackend, MemoryStorage, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("d3-mem-\(UUID().uuidString)", isDirectory: true)
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

    private var durableMessages: [ChatMessage] {
        [
            .init(role: .user, content: "Should we isolate agent edits with git worktrees?"),
            .init(role: .assistant, content: "Decision: always use git worktrees for agent edits."),
        ]
    }

    func testInjectedConsolidatorWritesMarkerToMemory() async throws {
        let (backend, storage, root) = try makeBackend()
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = "D3_CONSOLIDATOR_MARKER_XYZ"
        let consolidator = ClosureMemoryConsolidator { _ in
            "### Injected\n- \(marker)"
        }

        let result = try await backend.endTurnCapture(
            sessionId: UUID().uuidString,
            messages: durableMessages,
            dreamEnabled: true,
            minHours: 0,
            consolidator: consolidator)

        XCTAssertTrue(result.didFlush)
        XCTAssertTrue(result.didDream, result.dreamReason)
        XCTAssertEqual(result.dreamReason, "consolidated_llm")
        let mem = storage.readMemory(scope: .workspace) ?? ""
        XCTAssertTrue(mem.contains(marker), String(mem.prefix(400)))
        // Session logs consumed after successful dream
        XCTAssertTrue(storage.listSessionLogs().isEmpty)
    }

    func testWithoutConsolidatorUsesExtractive() async throws {
        let (backend, storage, root) = try makeBackend()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await backend.endTurnCapture(
            sessionId: UUID().uuidString,
            messages: durableMessages,
            dreamEnabled: true,
            minHours: 0,
            consolidator: nil)

        XCTAssertTrue(result.didDream)
        XCTAssertEqual(result.dreamReason, "consolidated_extractive")
        let mem = storage.readMemory(scope: .workspace) ?? ""
        XCTAssertTrue(
            mem.lowercased().contains("decision") || mem.lowercased().contains("worktree"),
            String(mem.prefix(300)))
    }

    func testConsolidatorEmptyFallsBackToExtractive() async throws {
        let (backend, storage, root) = try makeBackend()
        defer { try? FileManager.default.removeItem(at: root) }

        let consolidator = ClosureMemoryConsolidator { _ in "NO_REPLY" }
        let result = try await backend.endTurnCapture(
            sessionId: UUID().uuidString,
            messages: durableMessages,
            dreamEnabled: true,
            minHours: 0,
            consolidator: consolidator)

        XCTAssertTrue(result.didDream, result.dreamReason)
        XCTAssertEqual(result.dreamReason, "llm_empty_extractive_fallback")
        let mem = storage.readMemory(scope: .workspace) ?? ""
        XCTAssertFalse(mem.isEmpty)
    }

    func testConsolidatorThrowFallsBackToExtractive() async throws {
        struct Boom: Error {}
        let (backend, storage, root) = try makeBackend()
        defer { try? FileManager.default.removeItem(at: root) }

        let consolidator = ThrowingConsolidator()
        let result = try await backend.endTurnCapture(
            sessionId: UUID().uuidString,
            messages: durableMessages,
            dreamEnabled: true,
            minHours: 0,
            consolidator: consolidator)

        XCTAssertTrue(result.didDream, result.dreamReason)
        XCTAssertEqual(result.dreamReason, "llm_error_extractive_fallback")
        XCTAssertNotNil(storage.readMemory(scope: .workspace))
    }

    func testResolverPrefersInjectedOverLLMFlag() {
        let inject = ClosureMemoryConsolidator { $0 }
        let model = ModelDescriptor(id: "m", displayName: "m", backend: .ollama)
        let resolved = MemoryConsolidatorResolver.resolve(
            injected: inject,
            llmEnabled: true,
            backend: nil,
            model: model)
        XCTAssertTrue(resolved is ClosureMemoryConsolidator)
    }

    func testResolverLLMRequiresBackend() {
        let model = ModelDescriptor(id: "m", displayName: "m", backend: .ollama)
        XCTAssertNil(MemoryConsolidatorResolver.resolve(
            injected: nil, llmEnabled: true, backend: nil, model: model))
        XCTAssertNil(MemoryConsolidatorResolver.resolve(
            injected: nil, llmEnabled: false, backend: nil, model: model))
    }

    func testRunConsolidateExtractiveTag() async {
        let (text, tag) = await MemoryBackend.runConsolidate(
            promptInput: "- **assistant:** Decision: prefer patches.\n",
            consolidator: nil)
        XCTAssertEqual(tag, "extractive")
        XCTAssertTrue(text.contains("Decision") || text.contains("Consolidated"))
    }
}

/// Throws always — used to exercise llm_error_extractive_fallback.
private struct ThrowingConsolidator: MemoryConsolidating {
    struct Boom: Error {}
    func consolidate(sessionBlob: String) async throws -> String {
        throw Boom()
    }
}
