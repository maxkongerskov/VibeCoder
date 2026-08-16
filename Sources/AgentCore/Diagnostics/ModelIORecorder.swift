//
//  ModelIORecorder.swift
//  AgentCore
//
//  Opt-in per-request model I/O recording (ZCode `rollout/model-io-*.jsonl`).
//  Off by default. Does not store full system prompts or raw API keys.
//

import Foundation

/// One JSONL row: metadata about a model request plus an optional response.
public struct ModelIORecord: Codable, Equatable, Sendable {
    public var timestamp: String
    public var sessionId: String
    public var request: Request
    public var response: Response?

    public init(timestamp: String, sessionId: String, request: Request, response: Response?) {
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.request = request
        self.response = response
    }

    public struct Request: Codable, Equatable, Sendable {
        public var modelId: String
        public var messageCount: Int
        public var toolNames: [String]
        /// Character count of system-role message bodies only — not the prompt text.
        public var systemPromptChars: Int
        /// Optional header-like fields. Authorization / API keys are redacted.
        public var headers: [String: String]?

        public init(
            modelId: String,
            messageCount: Int,
            toolNames: [String],
            systemPromptChars: Int,
            headers: [String: String]? = nil
        ) {
            self.modelId = modelId
            self.messageCount = messageCount
            self.toolNames = toolNames
            self.systemPromptChars = systemPromptChars
            self.headers = headers.map { ModelIORecorder.redactHeaders($0) }
        }

        /// Map from the loop-facing `ChatRequest`.
        public init(chatRequest: ChatRequest, headers: [String: String]? = nil) {
            self.init(
                modelId: chatRequest.model.id,
                messageCount: chatRequest.messages.count,
                toolNames: chatRequest.tools.map(\.name),
                systemPromptChars: Self.systemPromptCharCount(messages: chatRequest.messages),
                headers: headers
            )
        }

        /// Map from the HTTP `ChatCompletionRequestBody` used by `OpenAICompatibleClient`.
        public init(body: ChatCompletionRequestBody, headers: [String: String]? = nil) {
            self.init(
                modelId: body.model,
                messageCount: body.messages.count,
                toolNames: body.tools?.map(\.function.name) ?? [],
                systemPromptChars: Self.systemPromptCharCount(wireMessages: body.messages),
                headers: headers
            )
        }

        public static func systemPromptCharCount(messages: [ChatMessage]) -> Int {
            messages.reduce(0) { partial, message in
                guard message.role == .system else { return partial }
                return partial + message.content.count
            }
        }

        public static func systemPromptCharCount(
            wireMessages: [ChatCompletionRequestBody.WireMessage]
        ) -> Int {
            wireMessages.reduce(0) { partial, message in
                guard message.role.lowercased() == "system" else { return partial }
                return partial + Self.characterCount(message.content)
            }
        }

        private static func characterCount(_ content: ChatCompletionRequestBody.WireContent) -> Int {
            switch content {
            case .text(let text):
                return text?.count ?? 0
            case .parts(let parts):
                return parts.reduce(0) { $0 + ($1.text?.count ?? 0) }
            }
        }
    }

    public struct Usage: Codable, Equatable, Sendable {
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var totalTokens: Int?

        public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            if let totalTokens {
                self.totalTokens = totalTokens
            } else if let promptTokens, let completionTokens {
                self.totalTokens = promptTokens + completionTokens
            } else {
                self.totalTokens = nil
            }
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        public var finishReason: String?
        public var usage: Usage?
        /// Assistant text, truncated to ``ModelIORecorder.responseTextLimit``.
        public var responseText: String?
        public var error: String?

        public init(
            finishReason: String? = nil,
            usage: Usage? = nil,
            responseText: String? = nil,
            error: String? = nil
        ) {
            self.finishReason = finishReason
            self.usage = usage
            self.responseText = ModelIORecorder.truncatedResponseText(responseText)
            self.error = error
        }
    }
}

/// Process-wide opt-in writer for `rollout/model-io-<sessionId>.jsonl`.
public enum ModelIORecorder {
    /// Wave-2 may wire `AppSettings` later. Default stays off.
    public static let enabledDefault = false

    /// Max characters stored for `responseText` (not the live model output).
    public static let responseTextLimit = 8_000

    public static let directoryName = "rollout"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _isEnabled = enabledDefault
    nonisolated(unsafe) private static var _directoryOverride: URL?

    /// Process-wide gate. Default `false`.
    public static var isEnabled: Bool {
        get { lock.withLock { _isEnabled } }
        set { lock.withLock { _isEnabled = newValue } }
    }

    /// Test seam. When set, JSONL is written here instead of Application Support.
    public static var directoryOverride: URL? {
        get { lock.withLock { _directoryOverride } }
        set { lock.withLock { _directoryOverride = newValue } }
    }

    public static func defaultDirectoryURL() -> URL {
        AppSupport.directory(directoryName)
    }

    public static func resolvedDirectoryURL() -> URL {
        directoryOverride ?? defaultDirectoryURL()
    }

    public static func fileURL(sessionId: String) -> URL {
        resolvedDirectoryURL()
            .appendingPathComponent("model-io-\(sanitizedSessionId(sessionId)).jsonl")
    }

    /// Append one record when enabled. IO / encode failures are ignored.
    public static func record(
        sessionId: String,
        request: ModelIORecord.Request,
        response: ModelIORecord.Response?
    ) {
        guard isEnabled else { return }

        let entry = ModelIORecord(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sessionId: sessionId,
            request: ModelIORecord.Request(
                modelId: request.modelId,
                messageCount: request.messageCount,
                toolNames: request.toolNames,
                systemPromptChars: request.systemPromptChars,
                headers: request.headers
            ),
            response: response.map {
                ModelIORecord.Response(
                    finishReason: $0.finishReason,
                    usage: $0.usage,
                    responseText: $0.responseText,
                    error: $0.error
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        guard var payload = try? encoder.encode(entry) else { return }
        payload.append(0x0A)

        let directory = resolvedDirectoryURL()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(sessionId: sessionId)
        lock.lock()
        defer { lock.unlock() }
        _ = appendLine(payload, to: url)
    }

    // MARK: - Redaction

    /// Redact Authorization, API keys, and values that look like secrets.
    public static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(headers.count)
        for (key, value) in headers {
            if isSensitiveHeader(key) || looksLikeSecret(value) {
                out[key] = redactSecretValue(value)
            } else {
                out[key] = value
            }
        }
        return out
    }

    public static func isSensitiveHeader(_ name: String) -> Bool {
        let normalized = normalizeHeaderName(name)
        if sensitiveHeaderNames.contains(normalized) { return true }
        if normalized.contains("api-key") || normalized.contains("apikey") { return true }
        if normalized.contains("authorization") { return true }
        if normalized.hasSuffix("-token")
            || normalized.hasSuffix("-secret")
            || normalized.hasSuffix("-password") {
            return true
        }
        return false
    }

    public static func looksLikeSecret(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("bearer ") { return true }
        if trimmed.hasPrefix("sk-") { return true }
        let lower = trimmed.lowercased()
        if lower.contains("api_key=") || lower.contains("api-key=") { return true }
        return false
    }

    public static func redactSecretValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "Bearer ", options: [.caseInsensitive, .anchored]) != nil {
            return "Bearer [REDACTED]"
        }
        return "[REDACTED]"
    }

    public static func truncatedResponseText(_ text: String?) -> String? {
        guard let text else { return nil }
        if text.count <= responseTextLimit { return text }
        return String(text.prefix(responseTextLimit))
    }

    // MARK: - Internals

    private static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "api-key",
        "x-api-key",
        "x-auth-token",
        "x-access-token",
        "access-token",
        "refresh-token",
        "x-openai-api-key",
        "openai-api-key",
        "cookie",
        "set-cookie",
        "x-csrf-token",
    ]

    private static func normalizeHeaderName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    static func sanitizedSessionId(_ sessionId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = sessionId.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let cleaned = String(mapped)
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    private static func appendLine(_ line: Data, to url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return false }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                return true
            } catch {
                return false
            }
        } else {
            do {
                try line.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }
}
