# Wave 2 — `client`

Owner: `client`. Exclusive file: `Sources/AgentCore/Backends/OpenAICompatibleClient.swift`.

## What changed

`streamChatCompletion(streamID:body:)` records one JSONL row after **each HTTP attempt settles** (success, non-2xx, decode failure, or transport error), including attempts that later retry.

Gate: `ModelIORecorder.isEnabled` (still `enabledDefault == false`). `record` is diagnostics-only and does not throw; retry policy, yield order, and cancellation are unchanged.

Call site (success and both `catch` paths) uses the `trace.md` shape:

```swift
if ModelIORecorder.isEnabled {
    var authHeaders: [String: String] = [:]
    if let token = config.bearerToken, !token.isEmpty {
        authHeaders["Authorization"] = "Bearer \(token)"
    }
    ModelIORecorder.record(
        sessionId: streamID.uuidString,
        request: ModelIORecord.Request(body: body, headers: authHeaders),
        response: ModelIORecord.Response(
            finishReason: finishReason,
            usage: ModelIORecord.Usage(
                promptTokens: promptTokens,
                completionTokens: completionTokens
            ),
            responseText: accumulatedContent,
            error: recordError
        )
    )
}
```

| Field | Source |
|---|---|
| `sessionId` | `streamID.uuidString` — client has no conversation id |
| `request` | `Request(body:)` from `ChatCompletionRequestBody` |
| `headers` | `Authorization: Bearer …` only when `config.bearerToken` is non-empty; `Request.init` redacts the raw token |
| `finishReason` | last yielded `ChatChunk.done` (including synthetic `"stop"` on `[DONE]`) |
| `usage` | last yielded `ChatChunk.usage` |
| `responseText` | concatenated `ChatChunk.contentDelta` (8k cap inside `Response.init`) |
| `error` | `localizedDescription` on failure; `nil` on success |

Helpers live on the client (`recordSettledModelIO` / `accumulateModelIO`). Did not edit `ModelIORecorder`, `AgentLoop`, `AppSettings`, or `ToolRegistry`.

## Tests

`Tests/AgentCoreTests/ParityClientTraceTests.swift`

- Direct `ModelIORecorder.record` + `Request(body:)` (disabled writes nothing; enabled writes JSONL).
- Client path via the existing `URLProtocol` mock: enabled records session id / content / usage / redacted bearer; disabled writes nothing; HTTP 400 records `error` and still throws to the consumer.

```
swift test --filter ParityClientTraceTests
```

## Loop / settings

Wave-2 `loop` may later thread a conversation UUID; until then session id is the stream UUID. Settings wire-up of `isEnabled` is out of scope (`AppSettings` is not owned here).
