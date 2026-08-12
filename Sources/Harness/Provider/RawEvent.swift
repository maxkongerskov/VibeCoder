//
//  RawEvent.swift  (Harness)
//
//  The unit a `ModelProvider` streams. Every backend (llama.cpp, LM Studio,
//  MLX, EXO) emits the SAME RawEvent stream, so nothing above the provider
//  boundary knows which backend produced a turn.
//
//  The one subtlety every OpenAI-compatible backend forces on us: in a
//  streamed `tool_calls` payload the `id` (and usually the `name`) arrive
//  ONLY on the first fragment for a given call; later fragments carry the
//  argument text and identify themselves by `index`, with `id == nil`.
//  Consumers MUST therefore bucket fragments by `index`, never by `id`. The
//  StreamAssembler does exactly that, so the rest of the harness never has to
//  think about it.
//

import Foundation

public enum RawEvent: Sendable, Equatable {
    /// A chunk of assistant prose.
    case contentDelta(String)
    /// A fragment of a tool call. `index` is the stable bucket key for the
    /// whole stream; `id`/`name` appear on the first fragment per index and
    /// are nil thereafter; `argumentsAppend` is the next slice of the JSON
    /// argument string for that call.
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsAppend: String?)
    /// Token accounting, if the backend reports it.
    case usage(promptTokens: Int, completionTokens: Int)
    /// Terminal event. `finishReason` is the backend's stop reason
    /// ("stop", "tool_calls", "length", …).
    case done(finishReason: String)
}
