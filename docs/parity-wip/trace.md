# Model I/O recorder (`trace`)

Wave-1 owns `Sources/AgentCore/Diagnostics/ModelIORecorder.swift` only.
Do **not** edit `OpenAICompatibleClient.swift` or `AppSettings.swift` from this
wave. `ModelIORecorder.enabledDefault` / `isEnabled` stay `false` until a later
settings wire-up.

## Wave-2 `client` call site

Add this inside `OpenAICompatibleClient.streamChatCompletion(streamID:body:)`
after each HTTP attempt **settles** (success, non-2xx, decode failure, or
transport error) — once per attempt you want on disk, typically the final
attempt. Gate on `ModelIORecorder.isEnabled`. Failures in `record` are
silent; do not throw.

`OpenAICompatibleClient` sees `ChatCompletionRequestBody`, not `ChatRequest`.
`OpenAICompatibleBackend.encode(request:)` maps them 1:1. Use `Request(body:)`
here; `Request(chatRequest:)` is the equivalent if you hook
`InferenceBackend.stream(request:)` instead.

```swift
// OpenAICompatibleClient.streamChatCompletion — after the stream/error completes.
if ModelIORecorder.isEnabled {
    var authHeaders: [String: String] = [:]
    if let token = config.bearerToken, !token.isEmpty {
        authHeaders["Authorization"] = "Bearer \(token)"
    }
    ModelIORecorder.record(
        sessionId: sessionId ?? streamID.uuidString,
        request: ModelIORecord.Request(body: body, headers: authHeaders),
        response: ModelIORecord.Response(
            finishReason: finishReason,   // last ChatChunk.done(finishReason:)
            usage: ModelIORecord.Usage(
                promptTokens: promptTokens,         // last ChatChunk.usage
                completionTokens: completionTokens
            ),
            responseText: accumulatedContent,       // concat ChatChunk.contentDelta
            error: recordError                      // nil on success
        )
    )
}
```

### Suggested arguments from `ChatRequest`

When the hook has a `ChatRequest` (backend `stream(request:)` or a future
`streamChatCompletion` that accepts the loop request):

| `ModelIORecord` field | From `ChatRequest` / chunks |
|---|---|
| `sessionId` | Conversation UUID from the agent loop. Thread it in if you can; otherwise `request.streamID.uuidString`. |
| `request.modelId` | `request.model.id` |
| `request.messageCount` | `request.messages.count` |
| `request.toolNames` | `request.tools.map(\.name)` |
| `request.systemPromptChars` | `request.messages.filter { $0.role == .system }.reduce(0) { $0 + $1.content.count }` (or `ModelIORecord.Request.systemPromptCharCount(messages:)`) |
| `request.headers` | Optional. Pass `Authorization` / API-key headers only — `Request.init` redacts them. **Never** persist the raw bearer token. |
| `response.finishReason` | Last `.done(finishReason:)` |
| `response.usage` | Last `.usage(promptTokens:completionTokens:)` |
| `response.responseText` | Concatenated `.contentDelta` (capped at 8k inside `Response.init`) |
| `response.error` | `error.localizedDescription` / HTTP body snippet on failure |

Do **not** write the full system prompt, tool schemas, or unredacted
`Authorization` values. System prompt is char-count only.

### On-disk path

`~/Library/Application Support/VibeCoder/rollout/model-io-<sessionId>.jsonl`

Created on first write via `AppSupport.directory("rollout")`. Tests inject
`ModelIORecorder.directoryOverride`.
