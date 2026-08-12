import XCTest
@testable import AgentCore

final class ChatLoopParallelToolsTests: XCTestCase {
    func testReadOnlyGitToolsAreClassifiedForParallelDispatch() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let registry = ToolRegistry.shared
        let gitDiffRO = await registry.isReadOnlyTool("git_diff")
        let gitStatusRO = await registry.isReadOnlyTool("git_status")
        let readFileRO = await registry.isReadOnlyTool("read_file")
        let writeFileRO = await registry.isReadOnlyTool("write_file")
        XCTAssertTrue(gitDiffRO)
        XCTAssertTrue(gitStatusRO)
        XCTAssertTrue(readFileRO)
        XCTAssertFalse(writeFileRO)
    }

    func testParallelReadOnlyBatchIncludesGitToolResults() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-git-parallel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "hello".write(to: tmp.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["init"]
        proc.currentDirectoryURL = tmp
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        let readBatch: [ChatChunk] = [
            .toolCallDelta(index: 0, id: "g1", name: "git_status",
                           argumentsAppend: #"{"path":"."}"#),
            .toolCallDelta(index: 1, id: "g2", name: "git_diff",
                           argumentsAppend: #"{"path":"."}"#),
            .toolCallDelta(index: 2, id: "g3", name: "read_file",
                           argumentsAppend: #"{"path":"probe.txt"}"#),
            .done(finishReason: "tool_calls"),
        ]

        let model = ModelDescriptor(id: "test", displayName: "Test", backend: .lmStudio)
        final class ScriptedBackend: InferenceBackend, @unchecked Sendable {
            let identifier: BackendIdentifier = .lmStudio
            private let turns: [[ChatChunk]]
            private var turnIndex = 0
            init(turns: [[ChatChunk]]) { self.turns = turns }
            func listModels() async throws -> [ModelDescriptor] { [] }
            func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
                let chunks = turns[min(turnIndex, turns.count - 1)]
                turnIndex += 1
                return AsyncThrowingStream { c in
                    for chunk in chunks { c.yield(chunk) }
                    c.finish()
                }
            }
            func cancel(streamID: UUID) async {}
        }

        let backend = ScriptedBackend(turns: [
            readBatch,
            [.contentDelta("Done."), .done(finishReason: "stop")],
        ])
        let loop = AgentLoop(backend: backend, model: model, config: .init(verifyEdits: false))
        let convo = try await loop.run(
            userMessage: "inspect git",
            conversation: Conversation(projectRoot: tmp)) { _ in }

        let toolResults = convo.messages.filter { $0.role == .tool }
        XCTAssertEqual(toolResults.count, 3)
        XCTAssertTrue(toolResults.contains { $0.toolCallID == "g1" })
        XCTAssertTrue(toolResults.contains { $0.toolCallID == "g2" })
        XCTAssertTrue(toolResults.contains { $0.toolCallID == "g3" })
    }
}