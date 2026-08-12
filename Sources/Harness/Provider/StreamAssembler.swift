//
//  StreamAssembler.swift  (Harness)
//
//  THE normalize() seam — delegates ingestion/finalize to AgentCore.ResponseNormalizer.
//

import Foundation
import AgentCore

/// One fully-assembled assistant turn.
public struct AssembledResponse: Sendable, Equatable {
    public var content: String
    public var toolCalls: [ToolCall]
    public var finishReason: String
    public var promptTokens: Int
    public var completionTokens: Int
    public var usedInlineFallback: Bool

    public init(content: String,
                toolCalls: [ToolCall],
                finishReason: String = "",
                promptTokens: Int = 0,
                completionTokens: Int = 0,
                usedInlineFallback: Bool = false) {
        self.content = content
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.usedInlineFallback = usedInlineFallback
    }
}

public struct StreamAssembler {

    private var normalizer = ResponseNormalizer.Accumulator()
    private var finishReason = ""
    private var promptTokens = 0
    private var completionTokens = 0

    public init() {}

    public mutating func ingest(_ event: RawEvent) {
        switch event {
        case let .contentDelta(s):
            normalizer.ingestContentDelta(s)

        case let .toolCallDelta(index, id, name, argumentsAppend):
            normalizer.ingestToolCallDelta(
                index: index, id: id, name: name, argumentsAppend: argumentsAppend)

        case let .usage(p, c):
            promptTokens = p
            completionTokens = c

        case let .done(reason):
            finishReason = reason
        }
    }

    public func finalize() -> AssembledResponse {
        let normalized = normalizer.finalize()
        let harnessCalls = normalized.toolCalls.map {
            ToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
        }
        return AssembledResponse(
            content: normalized.content,
            toolCalls: harnessCalls,
            finishReason: finishReason,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            usedInlineFallback: normalized.usedInlineFallback)
    }

    public static func assemble(
        _ stream: AsyncThrowingStream<RawEvent, Error>
    ) async throws -> AssembledResponse {
        var assembler = StreamAssembler()
        for try await event in stream {
            try Task.checkCancellation()
            assembler.ingest(event)
        }
        return assembler.finalize()
    }
}