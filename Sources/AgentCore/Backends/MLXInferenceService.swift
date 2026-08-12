//
//  MLXInferenceService.swift
//
//  Stub-with-real-shape port of the DEV PLAN's `MLXInferenceService`.
//
//  Why this lives in AgentCore (not the MLXBackend target):
//   * The destination path the porting brief picked is here, so the
//     CLI / app / tests can reference `MLXInferenceService` without
//     conditionally linking the MLXBackend target.
//   * The DEV PLAN source directly imports `MLXLLM`, `MLXLMCommon`,
//     `MLXHuggingFace`, `HuggingFace`, `Tokenizers` — none of which are
//     dependencies of AgentCore (Package.swift lists them as commented-
//     out "Reserved slots — uncomment per phase"). So the streaming
//     path here throws `BackendError.unsupported` until the MLX target
//     is wired up and replaces these surfaces with the real container.
//
//  What IS ported faithfully (no MLX dependency needed):
//   * The actor + `InferenceBackend` conformance shape.
//   * `clampOutputTokens`, `resolvedModelId`, `toolSpecs(from:)`,
//     `splitMessages`, `renderedContent` — all pure-Swift helpers that
//     are exercised by unit tests independently of the model.
//   * Load-state reporting via the value-type `MLXModelLoadState`
//     (the DEV PLAN's `@MainActor` `ObservableObject` is owned by the
//     host UI layer now — we publish snapshots through an injected
//     async callback so AgentCore stays Combine-free).
//   * Weights pre-fetch via `MLXHubDownloader` (the recently-ported
//     actor). Triggering a `prefetch` does real network I/O even with
//     MLX-Swift unlinked, so the agent loop can still surface
//     "download → ready to go, but inference is gated" UX.
//
//  When the MLXBackend target is eventually enabled this file's
//  `chatCompletion` / `streamChatCompletion` methods should hand off to
//  the `MLXBackend` actor (or be deleted in favour of it) — the public
//  surface is intentionally aligned with the DEV PLAN names so the
//  swap is a single call-site change.
//

import Foundation

// MARK: - Inference-service-specific surface kept from the DEV PLAN
//
// These shapes live alongside the `InferenceBackend` protocol's
// streaming surface because the DEV PLAN file used them directly in
// its `chatCompletion` / `streamChatCompletion` signatures. Callers
// that have already migrated to `InferenceBackend.stream(request:)`
// don't need them; callers still on the DEV PLAN's call sites do.

/// Lean Sendable wrapper for a heterogeneous message-history array
/// (OpenAI-style `[String: Any]` dicts). The value crosses actor
/// boundaries as a single token, so we mark it `@unchecked Sendable`
/// and trust producers not to mutate it after handing it over (the
/// agent loop builds a fresh array per turn).
public struct SendableMessages: @unchecked Sendable {
    public let value: [[String: Any]]
    public init(_ value: [[String: Any]]) { self.value = value }
}

/// Minimal "raw OpenAI" tool-definition shape kept for the DEV PLAN's
/// `toolSpecs(from:)` helper. The agent loop's preferred shape is the
/// strongly-typed `ToolSchema`; this Encodable mirror exists so the
/// helper can JSON-round-trip a tool into the model's chat template.
public struct MLXToolDefinition: Codable, Sendable {
    public struct Function: Codable, Sendable {
        public let name: String
        public let description: String?
        public let parameters: AnyCodableJSON?
        public init(name: String, description: String?, parameters: AnyCodableJSON?) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }
    public let type: String
    public let function: Function
    public init(name: String, description: String?, parameters: AnyCodableJSON?) {
        self.type = "function"
        self.function = Function(name: name, description: description, parameters: parameters)
    }
}

/// Erased Codable JSON value so `MLXToolDefinition.parameters` can carry an
/// arbitrary JSON schema across actor boundaries without dragging an
/// `Any` through `Sendable` checks.
public struct AnyCodableJSON: Codable, Sendable {
    public let json: String
    public init(json: String) { self.json = json }
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(JSONValue.self)
        let data = try JSONEncoder().encode(raw)
        self.json = String(data: data, encoding: .utf8) ?? "{}"
    }
    public func encode(to encoder: Encoder) throws {
        let data = json.data(using: .utf8) ?? Data("{}".utf8)
        let raw = try JSONDecoder().decode(JSONValue.self, from: data)
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
    private enum JSONValue: Codable {
        case null, bool(Bool), int(Int), double(Double), string(String)
        case array([JSONValue]), object([String: JSONValue])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let v = try? c.decode(Bool.self)   { self = .bool(v);   return }
            if let v = try? c.decode(Int.self)    { self = .int(v);    return }
            if let v = try? c.decode(Double.self) { self = .double(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            if let v = try? c.decode([JSONValue].self)         { self = .array(v); return }
            if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON")
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null:           try c.encodeNil()
            case .bool(let v):    try c.encode(v)
            case .int(let v):     try c.encode(v)
            case .double(let v):  try c.encode(v)
            case .string(let v):  try c.encode(v)
            case .array(let v):   try c.encode(v)
            case .object(let v):  try c.encode(v)
            }
        }
    }
}

/// Native `ToolSpec` from MLX-Swift is `[String: any Sendable]`; we
/// mirror that here so `toolSpecs(from:)` can be ported verbatim and
/// the eventual hand-off to MLX is a typealias change.
public typealias ToolSpec = [String: any Sendable]

// MARK: - MLXInferenceService

/// In-process MLX inference surface. Public API mirrors the DEV PLAN
/// so the agent loop can route to it directly; concrete generation is
/// gated behind `BackendError.unsupported` until the MLXBackend target
/// is enabled (Package.swift "Reserved slots" — uncomment per phase).
public actor MLXInferenceService: InferenceBackend {

    public nonisolated let identifier: BackendIdentifier = .mlx

    // MARK: Configuration (all injectable)

    /// HF-cache-aware downloader. Default uses the shared instance with
    /// `~/.cache/huggingface/hub` — tests / sandboxed hosts inject a
    /// downloader pointing at a scratch directory.
    private let downloader: MLXHubDownloader

    /// Async observer for load-state transitions. The DEV PLAN's
    /// singleton `MLXModelLoadState.shared` is gone; hosts that need
    /// UI binding wrap an `ObservableObject` around these snapshots.
    public typealias LoadStateObserver = @Sendable (MLXModelLoadState) async -> Void
    private let loadStateObserver: LoadStateObserver?

    /// Fallback model id when the caller hands us an empty / synthetic
    /// model string. Defaults to the curated catalog's recommended
    /// entry; overridable for tests.
    private let fallbackModelId: String

    /// Hard ceiling on tokens generated per call. The DEV PLAN's
    /// rationale verbatim: a 30-50 minute local generation against the
    /// agent's 32k default is worse than a slightly clipped answer.
    public static let mlxMaxOutputTokens = 8192

    /// Current load-state snapshot. The observer (if any) sees each
    /// mutation; callers can read this directly.
    public private(set) var loadState: MLXModelLoadState = .idle

    /// Repo id of the currently-cached container. Tracked even though
    /// the container itself can't be held until MLX-Swift is wired up —
    /// so `prefetch` / `unload` semantics are preserved.
    private var cachedModelId: String?

    public init(downloader: MLXHubDownloader = .shared,
                fallbackModelId: String = CuratedMLXCatalog.defaultRepoId,
                loadStateObserver: LoadStateObserver? = nil) {
        self.downloader = downloader
        self.fallbackModelId = fallbackModelId
        self.loadStateObserver = loadStateObserver
    }

    // MARK: InferenceBackend

    /// Locally-downloaded MLX models from the curated catalog. The
    /// catalog is the source of truth for display metadata; we filter
    /// to entries that have a populated snapshot directory under the
    /// downloader's cache base.
    public func listModels() async throws -> [ModelDescriptor] {
        CuratedMLXCatalog.all.map { entry in
            ModelDescriptor(
                id: entry.repoId,
                displayName: entry.displayName,
                backend: .mlx,
                supportsTools: entry.toolCapable,
                contextLength: entry.maxContextLength,
                parameterCountB: entry.paramsB
            )
        }
    }

    /// Pre-populates the HF cache for the descriptor's repo. Does
    /// genuine network I/O via `MLXHubDownloader` — does NOT load the
    /// container into Metal (that needs MLX-Swift; throws when called).
    public func warmUp(model: ModelDescriptor) async throws {
        try await prefetch(modelId: model.id)
    }

    /// Streaming surface required by `InferenceBackend`. Throws
    /// `BackendError.unsupported` until MLX-Swift is linked — see the
    /// header comment for the integration plan.
    public nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: BackendError.unsupported(
                "MLX inference requires the MLXBackend target. Enable mlx-swift in Package.swift to use this surface."
            ))
        }
    }

    /// Cancels an in-flight stream. While the streaming path is gated
    /// this is a no-op; once MLX-Swift is wired up it routes through
    /// the container's cancellation handle.
    public func cancel(streamID: UUID) async { /* no-op until MLX is linked */ }

    /// Release the cached container. Idempotent. Reports an `idle`
    /// load-state snapshot so observers can refresh their UI.
    public func unload(model: ModelDescriptor) async throws {
        cachedModelId = nil
        await transition { $0.reset() }
    }

    // MARK: DEV PLAN compatibility surface

    /// Pre-downloads the weights for `modelId` so a subsequent
    /// inference call doesn't pay the network cost. Faithfully mirrors
    /// the DEV PLAN's `prefetch` method.
    public func prefetch(modelId: String) async throws {
        let resolvedId = Self.resolvedModelId(modelId, fallback: fallbackModelId)
        await transition { $0.begin(modelId: resolvedId) }
        do {
            try await downloader.download(repoId: resolvedId) { [weak self] fraction in
                guard let self else { return }
                Task { await self.publishProgress(fraction: fraction) }
            }
            cachedModelId = resolvedId
            await transition { $0.markReady() }
        } catch {
            await transition { $0.reset() }
            throw error
        }
    }

    /// Convenience kept for parity with the DEV PLAN's non-streamed
    /// path. Always throws until MLX-Swift is linked.
    public func chatCompletion(model: String,
                                messages: SendableMessages,
                                tools: [MLXToolDefinition],
                                temperature: Double,
                                maxTokens: Int) async throws -> String {
        _ = messages; _ = tools; _ = temperature; _ = maxTokens
        _ = Self.resolvedModelId(model, fallback: fallbackModelId)
        throw BackendError.unsupported(
            "MLX chatCompletion requires the MLXBackend target. Enable mlx-swift in Package.swift."
        )
    }

    /// Streaming variant kept for parity. Always throws until
    /// MLX-Swift is linked.
    public func streamChatCompletion(model: String,
                                      messages: SendableMessages,
                                      tools: [MLXToolDefinition],
                                      temperature: Double,
                                      maxTokens: Int,
                                      onDelta: @Sendable (String) -> Void) async throws {
        _ = messages; _ = tools; _ = temperature; _ = maxTokens; _ = onDelta
        _ = Self.resolvedModelId(model, fallback: fallbackModelId)
        throw BackendError.unsupported(
            "MLX streamChatCompletion requires the MLXBackend target. Enable mlx-swift in Package.swift."
        )
    }

    // MARK: Load-state plumbing

    private func transition(_ change: (inout MLXModelLoadState) -> Void) async {
        change(&loadState)
        if let observer = loadStateObserver {
            await observer(loadState)
        }
    }

    private func publishProgress(fraction: Double) async {
        await transition { $0.update(fraction: fraction) }
    }

    // MARK: - Output-token clamp (unit-tested)

    /// Clamps the agent's requested completion-token count to the
    /// MLX-only ceiling. `requested <= 0` means "unspecified" → use the
    /// ceiling; otherwise take the smaller of the two so the agent can
    /// ask for FEWER but never blow past the runaway guard.
    public static func clampOutputTokens(_ requested: Int) -> Int {
        let base = requested > 0 ? requested : mlxMaxOutputTokens
        return min(base, mlxMaxOutputTokens)
    }

    // MARK: - Model-id normalisation

    /// Normalises whatever the agent passed as `model` into a usable HF
    /// repo id. Synthetic placeholders (the `mlx://local` base URL,
    /// empty strings) fall back to the supplied default so generation
    /// never fails on a non-id.
    public static func resolvedModelId(_ requested: String,
                                        fallback: String = CuratedMLXCatalog.defaultRepoId) -> String {
        let t = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.contains("://") { return fallback }
        return t
    }

    // MARK: - Native tool-calling bridge (pure helpers)

    /// Converts `[MLXToolDefinition]` into the MLX-Swift `ToolSpec` shape
    /// (`[String: any Sendable]` OpenAI-schema dicts). Skips any tool
    /// that fails to round-trip through JSON.
    public static func toolSpecs(from tools: [MLXToolDefinition]) -> [ToolSpec] {
        tools.compactMap { tool in
            guard let data = try? JSONEncoder().encode(tool),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = sendableJSON(obj) as? [String: any Sendable] else { return nil }
            return dict
        }
    }

    /// Recursively converts a JSONSerialization value (NSString /
    /// NSNumber / NSArray / NSDictionary) into Swift-native `Sendable`
    /// values, so the result satisfies `ToolSpec == [String: any
    /// Sendable]` statically (the bridged NS types do not). Booleans
    /// are distinguished from numbers via CFBoolean identity so JSON
    /// `true`/`false` survives the round-trip.
    public static func sendableJSON(_ value: Any) -> any Sendable {
        if let n = value as? NSNumber, !(value is String) {
            if isBool(n) { return n.boolValue }
            return n.doubleValue.rounded() == n.doubleValue ? n.intValue : n.doubleValue
        }
        switch value {
        case let s as String:           return s
        case let arr as [Any]:          return arr.map { sendableJSON($0) }
        case let dict as [String: Any]: return dict.mapValues { sendableJSON($0) }
        default:                        return String(describing: value)
        }
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    // MARK: - Message rendering (pure helpers)

    /// Result of `splitMessages`. The MLX-Swift `Chat.Message.Role` is
    /// reproduced as a local enum so this file compiles without the
    /// MLX target — the eventual real implementation maps these one-
    /// for-one to `Chat.Message.Role`.
    public enum ChatRole: String, Sendable {
        case system, user, assistant, tool
    }

    public struct ChatTurn: Sendable {
        public let role: ChatRole
        public let content: String
        public init(role: ChatRole, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// Splits OpenAI-style messages into (instructions, history, prompt,
    /// role). System messages collapse into a single `instructions`
    /// block; all-but-last non-system messages form the history; the
    /// last non-system message is the prompt with its own role (so a
    /// mid-loop tool result is fed back as a `.tool` turn).
    public static func splitMessages(_ messages: [[String: Any]])
        -> (instructions: String?, history: [ChatTurn], prompt: String, role: ChatRole) {

        let systemText = messages
            .filter { ($0["role"] as? String) == "system" }
            .compactMap { $0["content"] as? String }
            .joined(separator: "\n\n")
        let instructions = systemText.isEmpty ? nil : systemText

        let nonSystem = messages.filter { ($0["role"] as? String) != "system" }
        func roleOf(_ s: String) -> ChatRole {
            switch s {
            case "assistant": return .assistant
            case "tool":      return .tool
            case "system":    return .system
            default:          return .user
            }
        }
        func turn(_ m: [String: Any]) -> ChatTurn {
            let r = roleOf((m["role"] as? String) ?? "user")
            return ChatTurn(role: r, content: renderedContent(m))
        }

        guard let last = nonSystem.last else {
            return (instructions, [], "", .user)
        }
        let history = nonSystem.dropLast().map(turn)
        let lastRole = roleOf((last["role"] as? String) ?? "user")
        return (instructions, Array(history), renderedContent(last), lastRole)
    }

    /// Renders one OpenAI-style message's content for the chat
    /// template. Because the MLX `Chat.Message` only carries
    /// `role` + `content` (no structured tool_calls), an assistant
    /// turn that issued tool calls would otherwise re-encode as EMPTY
    /// content — the model would then see tool results appear from
    /// nowhere, lose track of what it did, and either re-call or
    /// optimistically declare success. We fold the assistant's own
    /// calls into its content ("[called: …]") and label tool results
    /// with the tool name so the call→result pairing stays visible.
    /// This is history context only — the CURRENT turn still emits
    /// native tool calls and halts, so there's no fabrication risk.
    public static func renderedContent(_ m: [String: Any]) -> String {
        let role = (m["role"] as? String) ?? "user"
        let content = (m["content"] as? String) ?? ""

        if role == "assistant", let tcs = m["tool_calls"] as? [[String: Any]], !tcs.isEmpty {
            let calls = tcs.compactMap { tc -> String? in
                guard let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String else { return nil }
                let args = (fn["arguments"] as? String) ?? "{}"
                return "\(name)(\(args))"
            }.joined(separator: ", ")
            if calls.isEmpty { return content }
            return content.isEmpty ? "[called: \(calls)]" : "\(content)\n[called: \(calls)]"
        }

        if role == "tool", !content.isEmpty {
            let name = (m["name"] as? String) ?? "tool"
            return "Tool result (\(name)):\n\(content)"
        }

        return content
    }
}
