//
//  OpenAICompatibleClient.swift
//
//  Shared HTTP client used by LMStudioBackend, EXOBackend, and
//  LlamaCppBackend (each of which speaks the OpenAI HTTP surface, just
//  at a different port and with different topology semantics).
//
//  Streaming uses chunked SSE parsing identical to OpenAI's "stream":
//  `data: <json>\n\n`, terminated by `data: [DONE]`.
//

import Foundation

public actor OpenAICompatibleClient {
    public struct Config: Sendable {
        public let baseURL: URL
        public let bearerToken: String?
        /// Connection timeout in seconds. The default is generous because
        /// llama-server cold-loads can take 30+ seconds for big models;
        /// shrinking this in production is a foot-gun.
        public let requestTimeout: TimeInterval

        public init(baseURL: URL, bearerToken: String? = nil, requestTimeout: TimeInterval = 600) {
            self.baseURL = baseURL
            self.bearerToken = bearerToken
            self.requestTimeout = requestTimeout
        }
    }

    public let config: Config
    private let session: URLSession
    /// Chunk mapper — owns the `emittedDone` flag per-mapper-instance so
    /// non-compliant servers that send finish_reason on multiple choices
    /// don't produce duplicate .done chunks.
    private let chunkMapper = ChatChunkMapper()
    /// In-flight streaming tasks by streamID. Cancelling the Swift `Task`
    /// tears down the underlying `session.bytes(...)` iteration, so this
    /// is what makes `cancel(streamID:)` actually stop a stream.
    private var inflight: [UUID: Task<Void, Never>] = [:]

    public init(config: Config, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = config.requestTimeout
            cfg.timeoutIntervalForResource = config.requestTimeout
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public func listModels() async throws -> [ModelDescriptor] {
        let url = config.baseURL.appendingPathComponent("models")
        var req = URLRequest(url: url)
        if let t = config.bearerToken { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: req)
        try validate(response: response, data: data)

        struct ModelsResponse: Decodable {
            struct Item: Decodable {
                let id: String
                let object: String?
                let context_length: Int?
                let max_model_len: Int?
                let contextLength: Int?
                let max_context_length: Int?
                let native_context_length: Int?

                var resolvedContextLength: Int? {
                    ModelContextLengthResolver.advertisedMax(
                        nativeContextLength: native_context_length,
                        maxContextLength: max_context_length,
                        contextLength: context_length,
                        extra: [max_model_len, contextLength])
                }
            }
            let data: [Item]
        }
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { item in
            let ctx = ModelContextLengthResolver.resolve( // P0: parse context_length
                modelId: item.id,
                apiValue: item.resolvedContextLength)
            // Callers that care about provenance remount with their own
            // BackendIdentifier (LM Studio / Ollama / oMLX / custom). Using
            // `.custom` here avoids mis-tagging every HTTP list as LM Studio
            // when a wrapper forgets to remap (OpenAICompatibleBackend did).
            return ModelDescriptor(
                id: item.id,
                displayName: item.id,
                backend: .custom,
                supportsTools: true,
                contextLength: ctx,
                parameterCountB: nil)
        }
    }

    /// Stream a `/v1/chat/completions` request. Returns an async stream
    /// that yields ChatChunks until `[DONE]`.
    ///
    /// LAYER-3 RETRY LOOP: wraps the single HTTP attempt in a retry loop
    /// that consults `RetryClassifier` on failure. Retryable errors (5xx,
    /// connection failures, 429 rate-limits) get up to `maxRetries`
    /// attempts with jittered exponential backoff (2s→30s). Fatal errors
    /// (4xx client errors, cancellation) fail immediately.
    ///
    /// The SSE framing is handled by `SSEStreamDecoder` (Layer 2) and
    /// the chunk mapping by `ChatChunkMapper`, both extracted so future
    /// API-specific transforms can share them.
    public func streamChatCompletion(streamID: UUID, body: ChatCompletionRequestBody)
        -> AsyncThrowingStream<ChatChunk, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Clear our registration whenever the stream ends (success,
                // error, or cancellation). Runs in actor isolation because
                // the Task inherits this actor's context.
                defer { self.inflight[streamID] = nil }

                var attempt = 0
                /// Once we have yielded any chunk to the consumer, a retry
                /// would re-send the full request and **duplicate** partial
                /// content/tool deltas in the agent transcript. Fail closed.
                var emittedToConsumer = false

                // Retry loop: each iteration is one HTTP attempt. The loop
                // exits on success, a fatal error, or exhaustion of retries.
                attemptLoop: while true {
                    // Fresh decoder per attempt so a broken partial never
                    // bleeds across retries (decoder is line-stateless today,
                    // but this keeps the contract explicit).
                    let decoder = SSEStreamDecoder()
                    var finishReason: String?
                    var promptTokens: Int?
                    var completionTokens: Int?
                    var accumulatedContent = ""

                    do {
                        let url = config.baseURL.appendingPathComponent("chat/completions")
                        var req = URLRequest(url: url)
                        req.httpMethod = "POST"
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        if let t = config.bearerToken { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
                        let encoder = JSONEncoder()
                        encoder.keyEncodingStrategy = .convertToSnakeCase
                        req.httpBody = try encoder.encode(body)

                        let (bytes, response) = try await session.bytes(for: req)

                        // Read the body if status is non-2xx so the error
                        // carries the actual upstream message (was
                        // previously "HTTP 400: " because we never read
                        // the body on failure).
                        if let http = response as? HTTPURLResponse,
                           !(200..<300).contains(http.statusCode) {
                            var bodyData = Data()
                            for try await byte in bytes {
                                bodyData.append(byte)
                                if bodyData.count > 8192 { break }   // cap
                            }
                            let errBody = String(data: bodyData, encoding: .utf8) ?? ""
                            throw BackendError.http(status: http.statusCode, body: errBody)
                        }

                        // Some servers ignore `stream: true` and return a
                        // single `application/json` chat.completion. Yield
                        // that body (or throw) — never succeed with 0 chunks.
                        if let http = response as? HTTPURLResponse {
                            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                                .lowercased()
                            if contentType.contains("application/json")
                                && !contentType.contains("event-stream") {
                                var bodyData = Data()
                                for try await byte in bytes {
                                    bodyData.append(byte)
                                }
                                do {
                                    let mapped = try Self.mapNonStreamingCompletion(bodyData)
                                    guard !mapped.isEmpty else {
                                        throw BackendError.decoding(
                                            "non-SSE chat.completion produced no chunks")
                                    }
                                    for c in mapped {
                                        Self.accumulateModelIO(
                                            c,
                                            finishReason: &finishReason,
                                            promptTokens: &promptTokens,
                                            completionTokens: &completionTokens,
                                            content: &accumulatedContent)
                                        continuation.yield(c)
                                        emittedToConsumer = true
                                    }
                                    self.recordSettledModelIO(
                                        streamID: streamID,
                                        body: body,
                                        finishReason: finishReason,
                                        promptTokens: promptTokens,
                                        completionTokens: completionTokens,
                                        accumulatedContent: accumulatedContent,
                                        recordError: nil)
                                    continuation.finish()
                                    return
                                } catch let error as BackendError {
                                    throw error
                                } catch {
                                    throw BackendError.decoding(
                                        "non-SSE chat.completion: \(error.localizedDescription)")
                                }
                            }
                        }

                        // Success path: stream SSE lines through the decoder.
                        var emittedDoneChunk = false
                        for try await line in bytes.lines {
                            switch decoder.decode(line: line) {
                            case .done:
                                // [DONE] terminator only — do not overwrite a real
                                // finish_reason already emitted as .done(tool_calls/…).
                                // Still emit a terminal done if the stream never
                                // sent finish_reason (some servers only send [DONE]).
                                if !emittedDoneChunk {
                                    let terminal = ChatChunk.done(finishReason: "stop")
                                    Self.accumulateModelIO(
                                        terminal,
                                        finishReason: &finishReason,
                                        promptTokens: &promptTokens,
                                        completionTokens: &completionTokens,
                                        content: &accumulatedContent)
                                    continuation.yield(terminal)
                                    emittedToConsumer = true
                                    emittedDoneChunk = true
                                }
                                self.recordSettledModelIO(
                                    streamID: streamID,
                                    body: body,
                                    finishReason: finishReason,
                                    promptTokens: promptTokens,
                                    completionTokens: completionTokens,
                                    accumulatedContent: accumulatedContent,
                                    recordError: nil)
                                continuation.finish()
                                return
                            case .data(let data):
                                guard let chunk = try? JSONDecoder().decode(
                                    ChatCompletionChunk.self, from: data
                                ) else {
                                    // Tolerant skip, but surface once per stream
                                    // so schema drift is diagnosable (C1 O2).
                                    Diagnostics.warn(
                                        "SSE skip: unparseable chat.completion.chunk (\(data.count) bytes)")
                                    continue
                                }
                                for c in chunkMapper.map(chunk) {
                                    if case .done = c { emittedDoneChunk = true }
                                    Self.accumulateModelIO(
                                        c,
                                        finishReason: &finishReason,
                                        promptTokens: &promptTokens,
                                        completionTokens: &completionTokens,
                                        content: &accumulatedContent)
                                    continuation.yield(c)
                                    emittedToConsumer = true
                                }
                            case .skip:
                                continue
                            }
                        }
                        // Stream completed without an explicit [DONE] —
                        // finish normally (some servers omit the terminator).
                        self.recordSettledModelIO(
                            streamID: streamID,
                            body: body,
                            finishReason: finishReason,
                            promptTokens: promptTokens,
                            completionTokens: completionTokens,
                            accumulatedContent: accumulatedContent,
                            recordError: nil)
                        continuation.finish()
                        return

                    } catch let error as BackendError {
                        self.recordSettledModelIO(
                            streamID: streamID,
                            body: body,
                            finishReason: finishReason,
                            promptTokens: promptTokens,
                            completionTokens: completionTokens,
                            accumulatedContent: accumulatedContent,
                            recordError: error.localizedDescription)
                        if emittedToConsumer {
                            // Never retry after partial delivery (C1 O1).
                            if case .cancelled = error {
                                continuation.finish(throwing: BackendError.cancelled)
                            } else {
                                continuation.finish(throwing: error)
                            }
                            return
                        }
                        // Classify: retry, escalate, or fatal.
                        switch RetryClassifier.classify(error, attemptCount: attempt) {
                        case .retry(let delay):
                            // Backoff then retry. Check cancellation before
                            // sleeping so a user-initiated cancel is prompt.
                            if Task.isCancelled {
                                continuation.finish(throwing: BackendError.cancelled)
                                return
                            }
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            if Task.isCancelled {
                                continuation.finish(throwing: BackendError.cancelled)
                                return
                            }
                            attempt += 1
                            continue attemptLoop

                        case .escalate(let reason):
                            // Budget exhausted for this error category.
                            continuation.finish(throwing: BackendError.transport(reason))
                            return

                        case .fatal(let reason):
                            // Non-retryable — fail immediately.
                            continuation.finish(throwing: BackendError.transport(reason))
                            return
                        }

                    } catch {
                        // Non-BackendError exceptions (e.g. URLSession
                        // internal errors) — treat as transport failures.
                        self.recordSettledModelIO(
                            streamID: streamID,
                            body: body,
                            finishReason: finishReason,
                            promptTokens: promptTokens,
                            completionTokens: completionTokens,
                            accumulatedContent: accumulatedContent,
                            recordError: error.localizedDescription)
                        if emittedToConsumer {
                            continuation.finish(throwing: BackendError.transport(error.localizedDescription))
                            return
                        }
                        let mapped = BackendError.transport(error.localizedDescription)
                        switch RetryClassifier.classify(mapped, attemptCount: attempt) {
                        case .retry(let delay):
                            if Task.isCancelled {
                                continuation.finish(throwing: BackendError.cancelled)
                                return
                            }
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            if Task.isCancelled {
                                continuation.finish(throwing: BackendError.cancelled)
                                return
                            }
                            attempt += 1
                            continue attemptLoop

                        case .escalate(let reason):
                            continuation.finish(throwing: BackendError.transport(reason))
                            return

                        case .fatal(let reason):
                            continuation.finish(throwing: BackendError.transport(reason))
                            return
                        }
                    }
                }
            }
            // Register the task (actor-isolated; runs before the task body,
            // which can only execute once this synchronous build closure
            // yields the actor). Also cancel on consumer-side termination.
            self.inflight[streamID] = task
            continuation.onTermination = { [task] _ in task.cancel() }
        }
    }

    public func cancel(streamID: UUID) {
        inflight.removeValue(forKey: streamID)?.cancel()
    }

    /// Opt-in JSONL row after one HTTP attempt settles. Must not throw.
    private func recordSettledModelIO(
        streamID: UUID,
        body: ChatCompletionRequestBody,
        finishReason: String?,
        promptTokens: Int?,
        completionTokens: Int?,
        accumulatedContent: String,
        recordError: String?
    ) {
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
    }

    private static func accumulateModelIO(
        _ chunk: ChatChunk,
        finishReason: inout String?,
        promptTokens: inout Int?,
        completionTokens: inout Int?,
        content: inout String
    ) {
        switch chunk {
        case .contentDelta(let text):
            content += text
        case .done(let reason):
            finishReason = reason
        case .usage(let prompt, let completion):
            promptTokens = prompt
            completionTokens = completion
        case .reasoningDelta, .toolCallDelta:
            break
        }
    }

    // MARK: - Mapping
    //
    // Chunk mapping moved to `ChatChunkMapper` in SSEStreamDecoder.swift so
    // both the chat-completions path and future API-specific transforms can
    // share it. The old `mapToChatChunks` method lived here; see git history.

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw BackendError.http(status: http.statusCode, body: body)
        }
    }
}

// MARK: - Wire types

public struct ChatCompletionRequestBody: Encodable, @unchecked Sendable {
    public var model: String
    public var messages: [WireMessage]
    public var tools: [WireTool]?
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int?
    public var stream: Bool
    /// Extra keys injected at encode time (thinking/reasoning params).
    ///
    /// `[String: Any]` is non-Sendable because `Any` cannot be statically
    /// verified. The values are always immutable Foundation types inserted by
    /// `ThinkingModelScanner.applyThinking`; the struct is mutated only at body
    /// construction time, never after it crosses an isolation boundary. We mark
    /// the enclosing struct `@unchecked Sendable` to silence Swift 6's check.
    public var extraBody: [String: Any] = [:]

    public init(model: String, messages: [WireMessage], tools: [WireTool]? = nil,
                sampling: SamplingParams, stream: Bool = true) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.temperature = sampling.temperature
        self.topP = sampling.topP
        self.maxTokens = sampling.maxTokens
        self.stream = stream
    }

    /// `stream_options: {include_usage: true}` — asks the server to append a
    /// final usage chunk (prompt/completion token counts) to a streaming
    /// response. OpenAI-standard; only valid with `stream: true`, and safely
    /// ignored (not an error) by servers that lack the feature.
    struct StreamOptions: Encodable {
        let includeUsage: Bool
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    // Custom encoder: standard fields first, then merge extraBody.
    //
    // We use a single DynamicKey-keyed container so arbitrary top-level
    // keys (reasoning_effort, thinking:{…}, …) can be written through
    // the same KeyedEncodingContainer as our known fields. JSONEncoder's
    // convertToSnakeCase strategy is a no-op here because every key we
    // emit (including extraBody) is already in snake_case form.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(model, forKey: DynamicKey(stringValue: "model"))
        try c.encode(messages, forKey: DynamicKey(stringValue: "messages"))
        try c.encodeIfPresent(tools, forKey: DynamicKey(stringValue: "tools"))
        try c.encode(temperature, forKey: DynamicKey(stringValue: "temperature"))
        try c.encode(topP, forKey: DynamicKey(stringValue: "top_p"))
        try c.encodeIfPresent(maxTokens, forKey: DynamicKey(stringValue: "max_tokens"))
        try c.encode(stream, forKey: DynamicKey(stringValue: "stream"))
        // Request per-response usage stats so the context meter can calibrate
        // to the model's actual token counts instead of the chars/4 estimate.
        if stream {
            try c.encode(StreamOptions(includeUsage: true),
                         forKey: DynamicKey(stringValue: "stream_options"))
        }
        // Merge thinking/reasoning params from extraBody into the JSON.
        for (key, value) in extraBody {
            if let s = value as? String {
                try c.encode(s, forKey: DynamicKey(stringValue: key))
            } else if let dict = value as? [String: Any] {
                try c.encode(JSONValue(dict), forKey: DynamicKey(stringValue: key))
            }
        }
    }

    /// Message content: plain string (text-only) or multimodal parts
    /// (text + `image_url`) for vision models.
    public enum WireContent: Encodable, Sendable {
        case text(String?)
        case parts([Part])

        public struct Part: Encodable, Sendable {
            public let type: String
            public let text: String?
            public let imageURL: ImageURL?

            public struct ImageURL: Encodable, Sendable {
                public let url: String
                public init(url: String) { self.url = url }
            }

            enum CodingKeys: String, CodingKey {
                case type, text
                case imageURL = "image_url"
            }

            public init(type: String, text: String? = nil, imageURL: ImageURL? = nil) {
                self.type = type
                self.text = text
                self.imageURL = imageURL
            }

            public static func text(_ s: String) -> Part {
                Part(type: "text", text: s)
            }

            public static func imageURL(_ url: String) -> Part {
                Part(type: "image_url", imageURL: ImageURL(url: url))
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(type, forKey: .type)
                try c.encodeIfPresent(text, forKey: .text)
                try c.encodeIfPresent(imageURL, forKey: .imageURL)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s):
                if let s {
                    try c.encode(s)
                } else {
                    try c.encodeNil()
                }
            case .parts(let parts):
                try c.encode(parts)
            }
        }
    }

    public struct WireMessage: Encodable, Sendable {
        public let role: String
        public let content: WireContent
        public let toolCalls: [WireToolCall]?
        public let toolCallId: String?

        public init(
            role: String,
            content: WireContent,
            toolCalls: [WireToolCall]? = nil,
            toolCallId: String? = nil
        ) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallId = toolCallId
        }

        /// Convenience for text-only messages (nil content → JSON null).
        public init(
            role: String,
            content: String?,
            toolCalls: [WireToolCall]? = nil,
            toolCallId: String? = nil
        ) {
            self.init(
                role: role,
                content: .text(content),
                toolCalls: toolCalls,
                toolCallId: toolCallId
            )
        }

        /// Build wire content from a `ChatMessage`, including vision parts.
        ///
        /// - Parameter emptyTextAsEmptyString: When true and there are no
        ///   images, empty text becomes `""` (oMLX prefers this over null
        ///   for non-tool assistant turns). When false, empty text → null.
        public static func from(
            _ msg: ChatMessage,
            emptyTextAsEmptyString: Bool = false
        ) -> WireMessage {
            let wireToolCalls: [WireToolCall]? = msg.toolCalls.isEmpty
                ? nil
                : msg.toolCalls.map {
                    .init(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments))
                }
            let content = wireContent(
                for: msg,
                emptyTextAsEmptyString: emptyTextAsEmptyString
            )
            return WireMessage(
                role: msg.role.rawValue,
                content: content,
                toolCalls: wireToolCalls,
                toolCallId: msg.toolCallID
            )
        }

        public static func wireContent(
            for msg: ChatMessage,
            emptyTextAsEmptyString: Bool
        ) -> WireContent {
            if !msg.images.isEmpty {
                var parts: [WireContent.Part] = []
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(.text(msg.content))
                }
                for image in msg.images {
                    parts.append(.imageURL(image.dataURL))
                }
                // Vision servers require at least one part.
                if parts.isEmpty {
                    parts.append(.text(""))
                }
                return .parts(parts)
            }
            if msg.content.isEmpty {
                return .text(emptyTextAsEmptyString ? "" : nil)
            }
            return .text(msg.content)
        }
    }

    public struct WireToolCall: Encodable, Sendable {
        public let id: String
        public let type: String = "function"
        public let function: WireFunction
        public init(id: String, function: WireFunction) {
            self.id = id; self.function = function
        }
    }
    public struct WireFunction: Encodable, Sendable {
        public let name: String
        public let arguments: String
    }
    public struct WireTool: Encodable, Sendable {
        public let type: String = "function"
        public let function: WireToolFunction
    }
    public struct WireToolFunction: Encodable, Sendable {
        public let name: String
        public let description: String
        public let parameters: ToolSchema.Parameters
    }
}

/// One streamed chunk as emitted by OpenAI/LM Studio/llama.cpp.
///
/// Made public so the extracted `ChatChunkMapper` (in SSEStreamDecoder.swift)
/// can consume it. The fields stay internal to this file's namespace but
/// the type itself is visible across the module boundary.
public struct ChatCompletionChunk: Decodable {
    public let choices: [Choice]
    public let usage: Usage?
    public struct Choice: Decodable {
        /// Optional: finish_reason-only terminator chunks omit `delta`.
        public let delta: Delta?
        public let finishReason: String?
        enum CodingKeys: String, CodingKey { case delta; case finishReason = "finish_reason" }
    }
    public struct Delta: Decodable {
        public let content: String?
        public let reasoningContent: String?
        public let thinking: String?
        public var toolCalls: [ToolCall]?
        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
            case thinking
            case toolCalls = "tool_calls"
        }

        public var reasoningText: String? {
            if let reasoningContent, !reasoningContent.isEmpty { return reasoningContent }
            if let thinking, !thinking.isEmpty { return thinking }
            return nil
        }
    }
    public struct ToolCall: Decodable {
        public let index: Int?
        public let id: String?
        public let function: Function?
        public struct Function: Decodable {
            public let name: String?
            /// Wire `arguments` may be a JSON string (OpenAI) or a JSON
            /// object (Ollama / some llama.cpp builds). Objects are
            /// re-encoded so the rest of the stack still sees a String.
            public let arguments: String?

            enum CodingKeys: String, CodingKey { case name, arguments }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decodeIfPresent(String.self, forKey: .name)
                guard c.contains(.arguments), try !c.decodeNil(forKey: .arguments) else {
                    arguments = nil
                    return
                }
                if let s = try? c.decode(String.self, forKey: .arguments) {
                    arguments = s
                    return
                }
                let raw = try c.decode(FlexibleJSON.self, forKey: .arguments)
                arguments = raw.jsonString
            }
        }
    }
    public struct Usage: Decodable {
        /// Optional so a partial `usage` object does not fail-closed and
        /// drop sibling `choices` / content on the same event.
        public let promptTokens: Int?
        public let completionTokens: Int?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

/// Non-streaming `/v1/chat/completions` body (server ignored `stream: true`).
struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String?
            let content: String?
            let reasoningContent: String?
            let toolCalls: [ChatCompletionChunk.ToolCall]?
            enum CodingKeys: String, CodingKey {
                case role, content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }
        let message: Message?
        let delta: ChatCompletionChunk.Delta?
        let finishReason: String?
        enum CodingKeys: String, CodingKey {
            case message, delta
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
    let usage: ChatCompletionChunk.Usage?
}

extension OpenAICompatibleClient {
    /// Map a full (non-SSE) chat.completion JSON body into ChatChunks.
    fileprivate static func mapNonStreamingCompletion(_ data: Data) throws -> [ChatChunk] {
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        var out: [ChatChunk] = []
        var emittedDone = false
        for choice in decoded.choices {
            let reasoning = choice.message?.reasoningContent ?? choice.delta?.reasoningText
            if let reasoning, !reasoning.isEmpty {
                out.append(.reasoningDelta(reasoning))
            }
            let content = choice.message?.content ?? choice.delta?.content
            if let content, !content.isEmpty {
                out.append(.contentDelta(content))
            }
            let toolCalls = choice.message?.toolCalls ?? choice.delta?.toolCalls
            if let toolCalls {
                for tc in toolCalls {
                    out.append(.toolCallDelta(
                        index: tc.index ?? 0,
                        id: tc.id,
                        name: tc.function?.name,
                        argumentsAppend: tc.function?.arguments
                    ))
                }
            }
            if !emittedDone, let reason = choice.finishReason {
                out.append(.done(finishReason: reason))
                emittedDone = true
            }
        }
        if let u = decoded.usage {
            out.append(.usage(
                promptTokens: u.promptTokens ?? 0,
                completionTokens: u.completionTokens ?? 0
            ))
        }
        if out.isEmpty {
            throw BackendError.decoding("non-SSE chat.completion had no choices/content")
        }
        return out
    }
}

/// Decodes any JSON value and re-encodes it as a compact JSON string.
private struct FlexibleJSON: Decodable {
    let jsonString: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            jsonString = "null"
            return
        }
        if let b = try? c.decode(Bool.self) {
            jsonString = b ? "true" : "false"
            return
        }
        if let i = try? c.decode(Int.self) {
            jsonString = String(i)
            return
        }
        if let d = try? c.decode(Double.self) {
            jsonString = String(d)
            return
        }
        if let s = try? c.decode(String.self) {
            jsonString = s
            return
        }
        if let arr = try? c.decode([FlexibleJSON].self) {
            jsonString = "[\(arr.map(\.jsonString).joined(separator: ","))]"
            return
        }
        if let obj = try? c.decode([String: FlexibleJSON].self) {
            let parts = obj.map { key, value in
                "\(Self.encodeJSONString(key)):\(value.jsonString)"
            }
            jsonString = "{\(parts.joined(separator: ","))}"
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON")
    }

    private static func encodeJSONString(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s),
              let out = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return out
    }
}

public enum BackendError: Error, LocalizedError {
    case transport(String)
    case http(status: Int, body: String)
    case decoding(String)
    case unsupported(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .transport(let s): return "Transport: \(s)"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(500))"
        case .decoding(let s): return "Decode: \(s)"
        case .unsupported(let s): return "Unsupported: \(s)"
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Extra-body encoding helper
//
// KeyedEncodingContainer only accepts CodingKey-conforming keys. To inject
// dynamic thinking params (e.g. "reasoning_effort", "thinking") we use a
// dynamic CodingKey backed by a raw string. This lets us merge arbitrary
// keys into the JSON output without a separate serialization pass.

private struct DynamicKey: CodingKey {
    var stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

private struct JSONValue: Encodable {
    let value: Any
    init(_ v: Any) { self.value = v }

    func encode(to encoder: Encoder) throws {
        if let s = value as? String {
            try s.encode(to: encoder)
        } else if let i = value as? Int {
            try i.encode(to: encoder)
        } else if let d = value as? [String: Any] {
            var nested = encoder.container(keyedBy: DynamicKey.self)
            for (k, v) in d {
                try nested.encode(JSONValue(v), forKey: DynamicKey(stringValue: k))
            }
        }
    }
}
