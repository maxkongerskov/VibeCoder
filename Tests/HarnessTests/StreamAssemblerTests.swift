//
//  StreamAssemblerTests.swift  (Harness)
//
//  Pins the normalize() seam — the single most important reliability surface
//  for open-weight models. Covers native streaming-fragment reassembly (the
//  id-only-on-first-fragment rule, multi-call ordering, out-of-order arrival),
//  the inline fallback handoff, and the "never double-execute" guarantee.
//

import XCTest
import AgentCore
@testable import Harness

final class StreamAssemblerTests: XCTestCase {

    private func assemble(_ events: [RawEvent]) -> AssembledResponse {
        var a = StreamAssembler()
        for e in events { a.ingest(e) }
        return a.finalize()
    }

    private func argsDict(_ call: ToolCall?) -> [String: Any] {
        guard let s = call?.arguments, let d = s.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return [:] }
        return dict
    }

    // MARK: - shared ResponseNormalizer bucketing

    func testFragmentedNameMatchesResponseNormalizerAccumulator() {
        var assembler = StreamAssembler()
        assembler.ingest(.contentDelta("hello "))
        assembler.ingest(.toolCallDelta(index: 0, id: "x", name: "grep_", argumentsAppend: #"{"q":"#))
        assembler.ingest(.toolCallDelta(index: 0, id: nil, name: "code", argumentsAppend: #"x"}"#))
        let harnessResult = assembler.finalize()

        var acc = ResponseNormalizer.Accumulator()
        acc.ingestContentDelta("hello ")
        acc.ingestToolCallDelta(index: 0, id: "x", name: "grep_", argumentsAppend: #"{"q":"#)
        acc.ingestToolCallDelta(index: 0, id: nil, name: "code", argumentsAppend: #"x"}"#)
        let coreResult = acc.finalize()

        XCTAssertEqual(harnessResult.toolCalls.count, coreResult.toolCalls.count)
        XCTAssertEqual(harnessResult.toolCalls.first?.name, coreResult.toolCalls.first?.name)
        XCTAssertEqual(harnessResult.toolCalls.first?.arguments, coreResult.toolCalls.first?.arguments)
        XCTAssertEqual(harnessResult.content, coreResult.content)
    }

    // MARK: - content only

    func testContentOnlyResponse() {
        let r = assemble([
            .contentDelta("Hello, "),
            .contentDelta("world."),
            .done(finishReason: "stop"),
        ])
        XCTAssertEqual(r.content, "Hello, world.")
        XCTAssertTrue(r.toolCalls.isEmpty)
        XCTAssertEqual(r.finishReason, "stop")
        XCTAssertFalse(r.usedInlineFallback)
    }

    // MARK: - native tool calls: id only on first fragment

    func testNativeSingleCallFragmentedArguments() {
        // id + name on first fragment; argument JSON dribbles in across
        // fragments with id == nil (the OpenAI streaming contract).
        let r = assemble([
            .toolCallDelta(index: 0, id: "call_abc", name: "read_file", argumentsAppend: #"{"pa"#),
            .toolCallDelta(index: 0, id: nil, name: nil, argumentsAppend: #"th":"#),
            .toolCallDelta(index: 0, id: nil, name: nil, argumentsAppend: #" "/etc/hosts"}"#),
            .done(finishReason: "tool_calls"),
        ])
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls.first?.id, "call_abc")
        XCTAssertEqual(r.toolCalls.first?.name, "read_file")
        XCTAssertEqual(argsDict(r.toolCalls.first)["path"] as? String, "/etc/hosts")
        XCTAssertFalse(r.usedInlineFallback)
    }

    func testNativeMultipleCallsOrderedByIndex() {
        // Fragments arrive interleaved/out-of-order; output is ordered by the
        // index each call first appeared at.
        let r = assemble([
            .toolCallDelta(index: 0, id: "c0", name: "read_file", argumentsAppend: #"{"path":"a"}"#),
            .toolCallDelta(index: 1, id: "c1", name: "grep_code", argumentsAppend: #"{"q":"#),
            .toolCallDelta(index: 0, id: nil, name: nil, argumentsAppend: ""),       // stray empty for 0
            .toolCallDelta(index: 1, id: nil, name: nil, argumentsAppend: #""foo"}"#),
            .done(finishReason: "tool_calls"),
        ])
        XCTAssertEqual(r.toolCalls.map(\.name), ["read_file", "grep_code"])
        XCTAssertEqual(argsDict(r.toolCalls[0])["path"] as? String, "a")
        XCTAssertEqual(argsDict(r.toolCalls[1])["q"] as? String, "foo")
    }

    func testNativeCallWithoutIdGetsSyntheticId() {
        // Some backends omit id entirely on tool-call deltas — synthesize a
        // stable one from the index so the tool-result pairing still works.
        let r = assemble([
            .toolCallDelta(index: 0, id: nil, name: "list_directory", argumentsAppend: "{}"),
            .done(finishReason: "tool_calls"),
        ])
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls.first?.id, "call_0")
    }

    func testNativeCallEmptyArgumentsBecomesEmptyObject() {
        let r = assemble([
            .toolCallDelta(index: 0, id: "c0", name: "git_status", argumentsAppend: nil),
            .done(finishReason: "tool_calls"),
        ])
        XCTAssertEqual(r.toolCalls.first?.arguments, "{}")
    }

    func testNamelessBucketIsDropped() {
        // A bucket that never received a name is noise, not a call.
        let r = assemble([
            .toolCallDelta(index: 0, id: "c0", name: nil, argumentsAppend: #"{"x":1}"#),
            .done(finishReason: "stop"),
        ])
        XCTAssertTrue(r.toolCalls.isEmpty)
    }

    // MARK: - inline fallback

    func testInlineFallbackRecoversXMLInvoke() {
        // No native tool calls; the call is buried in the content as XML.
        let r = assemble([
            .contentDelta("Sure.\n<invoke name=\"run_shell\">"),
            .contentDelta("<parameter name=\"command\">ls -la</parameter></invoke>"),
            .done(finishReason: "stop"),
        ])
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls.first?.name, "run_shell")
        XCTAssertEqual(argsDict(r.toolCalls.first)["command"] as? String, "ls -la")
        XCTAssertTrue(r.usedInlineFallback, "inline recovery must be flagged")
        XCTAssertFalse(r.content.contains("<invoke"), "markup stripped from content")
        XCTAssertTrue(r.content.contains("Sure."))
    }

    func testNativeCallsSuppressInlineFallback() {
        // A native call is present, so incidental tool-shaped JSON in the
        // prose must NOT be parsed as a second call (no double-execute).
        let r = assemble([
            .contentDelta(#"Here's an example: {"name":"not_a_tool","arguments":{"x":1}}"#),
            .toolCallDelta(index: 0, id: "c0", name: "read_file", argumentsAppend: #"{"path":"a"}"#),
            .done(finishReason: "tool_calls"),
        ])
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls.first?.name, "read_file")
        XCTAssertFalse(r.usedInlineFallback)
    }

    // MARK: - usage + finalize purity

    func testUsageCaptured() {
        let r = assemble([
            .contentDelta("hi"),
            .usage(promptTokens: 123, completionTokens: 45),
            .done(finishReason: "stop"),
        ])
        XCTAssertEqual(r.promptTokens, 123)
        XCTAssertEqual(r.completionTokens, 45)
    }

    func testFinalizeIsPureAndRepeatable() {
        var a = StreamAssembler()
        a.ingest(.toolCallDelta(index: 0, id: "c0", name: "read_file", argumentsAppend: "{}"))
        a.ingest(.done(finishReason: "tool_calls"))
        XCTAssertEqual(a.finalize(), a.finalize())
    }

    // MARK: - live async drainer

    func testAssembleDrainsAsyncStream() async throws {
        let stream = AsyncThrowingStream<RawEvent, Error> { cont in
            cont.yield(.contentDelta("async "))
            cont.yield(.contentDelta("world"))
            cont.yield(.done(finishReason: "stop"))
            cont.finish()
        }
        let r = try await StreamAssembler.assemble(stream)
        XCTAssertEqual(r.content, "async world")
    }

    func testAssemblePropagatesProviderError() async {
        let stream = AsyncThrowingStream<RawEvent, Error> { cont in
            cont.yield(.contentDelta("partial"))
            cont.finish(throwing: ProviderError.transport("socket closed"))
        }
        do {
            _ = try await StreamAssembler.assemble(stream)
            XCTFail("expected the provider error to propagate")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .transport("socket closed"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
