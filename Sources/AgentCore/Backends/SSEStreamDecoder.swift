//
//  SSEStreamDecoder.swift
//
//  Layer-2 of the streaming stack: a reusable SSE (Server-Sent Events)
//  line parser. Takes raw text lines from an HTTP byte stream and yields
//  decoded payloads, handling the `data: <json>\n\n` framing that
//  OpenAI-compatible servers (llama.cpp, LM Studio, EXO) emit.
//
//  Extracted from OpenAICompatibleClient's inline parser so both the
//  existing chat-completions path and future API-specific transforms
//  (Responses API, Anthropic Messages) can share the same robust framing.
//
//  This is Grok Build's split: the raw HTTP byte stream (Layer 1) feeds
//  a per-API transform (Layer 2 = this type), which the retry/cancel
//  actor (Layer 3 in OpenAICompatibleClient) drives.
//
//  TOLERANT BY DESIGN: SSE lines from real servers are messy. We skip
//  un-parseable `data:` payloads rather than aborting the stream, and we
//  treat `[DONE]` as a terminator — both match Grok Build's behavior and
//  the prior inline implementation.
//

import Foundation

/// Decodes SSE-formatted text lines into JSON payloads. Stateless
/// across attempts — the actor creates a fresh instance per request so
/// partial frames from a failed attempt can never leak into the next.
public struct SSEStreamDecoder: Sendable {

    public init() {}

    /// The result of decoding one `data:` line.
    public enum DecodedLine: Sendable {
        /// A `[DONE]` terminator — the stream is complete. The caller
        /// should stop reading and finish normally.
        case done
        /// A decoded JSON payload (the bytes of the `data:` value).
        case data(Data)
        /// A non-data line (comment, keep-alive ping, empty separator).
        /// The caller should ignore it and continue reading.
        case skip
    }

    /// Decode one raw line from `URLSession.bytes(for:).lines`.
    ///
    /// SSE framing: a payload line looks like `data: <json>` and is
    /// terminated by `\n\n`. Within a single line from `.lines`, the
    /// `data:` prefix identifies payload; everything else (empty lines,
    /// comments starting with `:`, `event:`/`id:` headers) is skipped.
    public func decode(line: String) -> DecodedLine {
        // Lines without the `data:` prefix are control frames or
        // separators — ignore them. This includes keep-alive comments
        // (`: ping`) and the blank line between events.
        guard line.hasPrefix("data:") else { return .skip }

        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)

        // OpenAI's stream terminator. When the server sends this, the
        // response is complete regardless of what the HTTP layer says.
        if payload == "[DONE]" { return .done }

        guard let data = payload.data(using: .utf8) else { return .skip }
        return .data(data)
    }

    /// Decode a raw `data:` payload string directly (for tests and
    /// non-streaming contexts where the framing has already been stripped).
    public func decode(payload: String) -> DecodedLine {
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8) else { return .skip }
        return .data(data)
    }
}

// MARK: - Chunk mapping (OpenAI chat-completions)

/// Maps a decoded `ChatCompletionChunk` (the OpenAI wire type) into
/// VibeCoder's backend-agnostic `ChatChunk` enum. This is the second
/// half of Layer 2: once the SSE framing is stripped, this converts
/// the provider's JSON shape into what the agent loop consumes.
///
/// Lives here so both `OpenAICompatibleClient` and any future
/// per-API transform can share the same mapping logic.
public final class ChatChunkMapper: Sendable {

    /// Map a decoded OpenAI `ChatCompletionChunk` into zero or more
    /// VibeCoder `ChatChunk`s. One wire chunk can yield several logical
    /// chunks (content + tool calls + finish reason in one delta).
    public func map(_ raw: ChatCompletionChunk) -> [ChatChunk] {
        var out: [ChatChunk] = []
        var emittedDone = false
        for choice in raw.choices {
            // `delta` is optional: finish_reason-only terminator chunks
            // omit it. Do not invent a delta just to keep mapping happy.
            if let delta = choice.delta {
                if let reasoning = delta.reasoningText, !reasoning.isEmpty {
                    out.append(.reasoningDelta(reasoning))
                }
                if let content = delta.content, !content.isEmpty {
                    out.append(.contentDelta(content))
                }
                if let toolCalls = delta.toolCalls {
                    for tc in toolCalls {
                        // `index` is REQUIRED to merge fragments correctly. If
                        // upstream omitted it (shouldn't happen with compliant
                        // OpenAI-format servers), default to 0 so a single
                        // call still works.
                        out.append(.toolCallDelta(
                            index: tc.index ?? 0,
                            id: tc.id,
                            name: tc.function?.name,
                            argumentsAppend: tc.function?.arguments
                        ))
                    }
                }
            }
            if !emittedDone, let reason = choice.finishReason {
                out.append(.done(finishReason: reason))
                emittedDone = true
            }
        }
        if let u = raw.usage {
            out.append(.usage(
                promptTokens: u.promptTokens ?? 0,
                completionTokens: u.completionTokens ?? 0
            ))
        }
        return out
    }
}