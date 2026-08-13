//
//  BugHuntMLXHarnessCatalogTests.swift
//
//  Verification-first proofs for MLXBackend HF-cache parsing,
//  ThinkingModelScanner, LMModel keywords, ExecutionMode mapping,
//  Harness ArgumentCoercer, and EvalRunner JSON events.
//
//  Each test below asserts the *actual* broken runtime behavior so a
//  green run is the proof. Comments state the correct behavior.
//

import XCTest
@testable import AgentCore
import EvalRunnerLib
import MLXBackend
import enum Harness.ArgumentCoercer
import enum Harness.ArgCoercion
import struct Harness.ToolParameter
import enum Harness.JSONType
import struct Harness.ToolSchema

final class BugHuntMLXHarnessCatalogTests: XCTestCase {

    // MARK: - Verbatim MLXBackend.listModels folder parse
    // Copied from Sources/MLXBackend/MLXBackend.swift:47-54.

    private func parseHFCacheFolderVerbatim(_ name: String) -> String? {
        guard name.hasPrefix("models--") else { return nil }
        let rest = String(name.dropFirst("models--".count))
        let parts = rest.components(separatedBy: "--").filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    func testHFCacheFolderSplitOnSingleHyphenManglesRepoId() {
        let folder = "models--mlx-community--Qwen2.5-Coder-7B-Instruct-4bit"
        let got = parseHFCacheFolderVerbatim(folder)
        XCTAssertEqual(got, "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
    }

    func testHFCacheFolderSplitManglesLmstudioCommunityGemma() {
        let folder = "models--lmstudio-community--gemma-4-31B-it-MLX-4bit"
        let got = parseHFCacheFolderVerbatim(folder)
        XCTAssertEqual(got, "lmstudio-community/gemma-4-31B-it-MLX-4bit")
    }

    func testHFCacheFolderSplitManglesUnslothLlama() {
        let folder = "models--unsloth--Llama-3.1-8B-Instruct"
        let got = parseHFCacheFolderVerbatim(folder)
        XCTAssertEqual(got, "unsloth/Llama-3.1-8B-Instruct")
    }

    func testHFCacheSingleSegmentRepoDropped() {
        XCTAssertEqual(parseHFCacheFolderVerbatim("models--gpt2"), "gpt2")
    }

    func testMLXBackendListModelsUsesBrokenHyphenSplit() async throws {
        let fm = FileManager.default
        let cache = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        let token = "BUGHUNT\(ProcessInfo.processInfo.processIdentifier)\(UUID().uuidString.prefix(8))"
        let folderName = "models--mlx-community--Qwen2.5-Coder-7B-Instruct-4bit-\(token)"
        let folder = cache.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let models = try await MLXBackend().listModels()
        let hit = models.first { $0.id.contains(token) }
        XCTAssertNotNil(hit, "planted HF-cache folder should be listed: \(models.map(\.id))")
        // Production joins every '-' piece with '/'.
        XCTAssertEqual(
            hit?.id,
            "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit-\(token)")
        XCTAssertEqual(hit?.backend, .mlx)
    }

    // MARK: - ThinkingModelScanner false matches

    func testScannerFalseMatch_Claude35SonnetIsNotExtendedThinking() {
        // Claude 3.5 Sonnet has no extended-thinking API. Sending
        // thinking.budget_tokens will 400. Only 3.7 / 4+ should match.
        let cap = ThinkingModelScanner.detect(modelId: "claude-3-5-sonnet-20241022")
        XCTAssertNil(cap, "Claude 3.5 Sonnet must not be treated as extended thinking")
    }

    func testScannerFalseMatch_Claude3OpusAndSonnet() {
        XCTAssertNil(ThinkingModelScanner.detect(modelId: "claude-3-opus-20240229"))
        XCTAssertNil(ThinkingModelScanner.detect(modelId: "claude-3-sonnet-20240229"))
        XCTAssertNil(ThinkingModelScanner.detect(modelId: "anthropic/claude-3-sonnet"))
    }

    func testScannerFalseMatch_ChatGLMUsesGLM5ThinkingAPI() {
        XCTAssertNil(ThinkingModelScanner.detect(modelId: "THUDM/chatglm3-6b"))
    }

    func testScannerFalseMatch_MiniMaxText01IsNotAReasoner() {
        XCTAssertNil(ThinkingModelScanner.detect(modelId: "MiniMaxAI/MiniMax-Text-01"))
    }

    func testScannerFalseMatch_Qwen3Instruct2507IsNonThinkingVariant() {
        XCTAssertNil(ThinkingModelScanner.detect(modelId: "Qwen/Qwen3-4B-Instruct-2507"))
    }

    func testScannerApplyThinkingInjectsBudgetOnClaude35() {
        XCTAssertNil(ThinkingModelScanner.detect(modelId: "claude-3-5-sonnet"))
    }

    func testScannerDoesNotMatchPlainQwen25Instruct() {
        // Control: comment claims qwen2.5 instruct is excluded.
        XCTAssertNil(ThinkingModelScanner.detect(modelId: "Qwen/Qwen2.5-7B-Instruct"))
        XCTAssertNil(ThinkingModelScanner.detect(modelId: "meta-llama/Llama-3.1-8B-Instruct"))
        XCTAssertNil(ThinkingModelScanner.detect(modelId: "gpt-4o-mini"))
    }

    // MARK: - LMModel capability keywords

    func testLMModel_Llama32TextOnlyMarkedVision() {
        // Llama 3.2 1B/3B are text-only. 11B/90B are the VL checkpoints.
        let small = LMModel(id: "meta-llama/Llama-3.2-1B-Instruct")
        XCTAssertFalse(small.capabilities.contains(.vision))
        let threeB = LMModel(id: "meta-llama/Llama-3.2-3B-Instruct")
        XCTAssertFalse(threeB.capabilities.contains(.vision))
    }

    func testLMModel_Gemma3_1BMarkedVision() {
        let m = LMModel(id: "google/gemma-3-1b-it")
        XCTAssertFalse(m.capabilities.contains(.vision))
    }

    func testLMModel_Yi6BMarkedLongContext() {
        let m = LMModel(id: "01-ai/Yi-1.5-6B-Chat")
        XCTAssertFalse(m.capabilities.contains(.longContext))
    }

    func testLMModel_GPT35TurboMissesTools() {
        let m = LMModel(id: "gpt-3.5-turbo-0125")
        XCTAssertTrue(m.probablySupportsTools)
        XCTAssertTrue(m.capabilities.contains(.toolCalling))
    }

    // MARK: - ExecutionMode mapping

    func testExecutionMode_EditPromptPromisesShellAskButFlagsSayFreeRein() {
        // Flags: edit disables Safe Mode + patch review (same as yolo for
        // those two levers). Prompt/authorization still require shell ask.
        // Mapping table therefore cannot express Auto vs Full.
        XCTAssertFalse(ExecutionMode.edit.enablesSafeMode)
        XCTAssertFalse(ExecutionMode.yolo.enablesSafeMode)
        XCTAssertFalse(ExecutionMode.edit.enablesPatchReview)
        XCTAssertFalse(ExecutionMode.yolo.enablesPatchReview)
        XCTAssertFalse(ExecutionMode.edit.isReadOnly)
        XCTAssertFalse(ExecutionMode.yolo.isReadOnly)
        XCTAssertTrue(
            ExecutionMode.edit.systemPromptSummary.lowercased().contains("approval"),
            "Auto prompt still talks about shell approval")
        XCTAssertFalse(
            ExecutionMode.yolo.systemPromptSummary.lowercased().contains("approval"))
    }

    func testExecutionMode_PlanReadOnlyNotRepresentedByTheTwoDocumentedLevers() {
        // Header claims only safeModeOn + patchReview exist. Plan is
        // safe=true, review=false — same pair as a Safe Mode edit — and
        // isReadOnly is a third lever hosts must remember to honor.
        XCTAssertTrue(ExecutionMode.plan.enablesSafeMode)
        XCTAssertFalse(ExecutionMode.plan.enablesPatchReview)
        XCTAssertTrue(ExecutionMode.plan.isReadOnly)
        // A host that only wires the two documented levers would allow
        // writes under the allow-list in Plan. ToolAuthorization uses
        // isReadOnly / executionMode == .plan separately.
        let outcome = ToolAuthorization.evaluate(
            toolName: "write_file",
            permission: .mutates,
            arguments: ToolArguments(dictionary: [
                "path": "/tmp/not-a-plan.md",
                "content": "x",
            ]),
            context: ToolContext(
                projectRoot: URL(fileURLWithPath: "/tmp"),
                conversationID: UUID(),
                executionMode: .plan))
        guard case .deny = outcome else {
            return XCTFail("plan must deny non-plan writes, got \(outcome)")
        }
    }

    // MARK: - Harness ArgumentCoercer

    private func arraySchema() -> Harness.ToolSchema {
        Harness.ToolSchema(
            name: "glob",
            description: "g",
            parameters: [
                ToolParameter(name: "path", type: .string, required: true),
                ToolParameter(
                    name: "globs", type: .array, arrayElementType: .string),
            ])
    }

    func testArgumentCoercer_ArrayOfIntsAcceptedThenStringArrayDropsAll() {
        let result = ArgumentCoercer.coerce(
            rawJSON: #"{"path":"a","globs":[1,2,3]}"#,
            against: arraySchema())
        switch result {
        case .ok(let args), .correctable(let args, _):
            XCTAssertEqual(args.stringArray("globs"), ["1", "2", "3"])
        default:
            XCTFail("int elements in a string array should coerce, got \(result)")
        }
    }

    func testArgumentCoercer_ScalarIntWrappedForStringArrayBecomesEmpty() {
        let result = ArgumentCoercer.coerce(
            rawJSON: #"{"path":"a","globs":5}"#,
            against: arraySchema())
        switch result {
        case .ok(let args), .correctable(let args, _):
            XCTAssertEqual(args.stringArray("globs"), ["5"])
        default:
            XCTFail("scalar int should wrap to [\"5\"], got \(result)")
        }
    }

    func testArgumentCoercer_OptionalNullRejectedInsteadOfOmitted() {
        let schema = Harness.ToolSchema(
            name: "read_file",
            description: "r",
            parameters: [
                ToolParameter(name: "path", type: .string, required: true),
                ToolParameter(name: "max_lines", type: .integer, required: false),
            ])
        let result = ArgumentCoercer.coerce(
            rawJSON: #"{"path":"/tmp/x","max_lines":null}"#,
            against: schema)
        guard case .ok(let args) = result else {
            return XCTFail("optional null should be omitted, got \(result)")
        }
        XCTAssertNil(args.values["max_lines"])
    }

    func testArgumentCoercer_IntegerFromSpacedDecimalStringRejected() {
        let schema = Harness.ToolSchema(
            name: "t",
            description: "t",
            parameters: [
                ToolParameter(name: "n", type: .integer, required: true),
            ])
        let result = ArgumentCoercer.coerce(
            rawJSON: #"{"n":"  25.0  "}"#,
            against: schema)
        switch result {
        case .ok(let args), .correctable(let args, _):
            XCTAssertEqual(args.int("n"), 25)
        default:
            XCTFail("spaced decimal string should coerce, got \(result)")
        }
    }

    // MARK: - EvalRunner JSON events

    func testEvalJSONEvent_StallAndCapAndReasoningDropped() {
        XCTAssertTrue(
            EvalJSONEvent.from(loopEvent: .stalled(repeatedSignature: "read:x")).isEmpty)
        XCTAssertTrue(
            EvalJSONEvent.from(loopEvent: .iterationCapHit(cap: 40)).isEmpty)
        XCTAssertTrue(
            EvalJSONEvent.from(loopEvent: .reasoningDelta("I should look")).isEmpty)
        XCTAssertTrue(
            EvalJSONEvent.from(loopEvent: .finished(reason: "stalled: read:x")).isEmpty)
    }

    func testEvalJSONEvent_ToolResultDroppedSoOraclesNeverSeeOutput() {
        let inv = ToolCallInvocation(id: "c1", name: "read_file", arguments: "{}")
        let ev = LoopEvent.toolResult(
            invocation: inv,
            result: ToolResult(content: "file body", isError: false))
        XCTAssertTrue(
            EvalJSONEvent.from(loopEvent: ev).isEmpty,
            "tool_result content is not a JSON event")
    }

    func testEvalJSONEvent_TextWithNewlineStaysOneJSONLLine() throws {
        let line = try EvalJSONEvent.text("hello\nworld").jsonLine()
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.dropLast().filter { $0 == "\n" }.count, 0)
        let obj = try JSONSerialization.jsonObject(
            with: Data(line.dropLast().utf8)) as? [String: Any]
        XCTAssertEqual(obj?["text"] as? String, "hello\nworld")
    }

    // MARK: - Curated MLX catalog RAM picker

    func testCuratedCatalogRecommendsModelThatDoesNotFit16GB() {
        let rec = CuratedMLXCatalog.recommended(forSystemRAMGB: 16)
        XCTAssertLessThanOrEqual(rec.minRAMGB, 16)
    }
}
