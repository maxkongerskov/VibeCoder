//
//  ModelSettingsStore.swift
//
//  Per-model JSON persistence for sampling + load parameters. Lives
//  orthogonally to the 3-layer cascade (Global → Project → Conversation):
//  per-model overrides apply whenever that specific model is active,
//  regardless of which project or conversation is in foreground.
//
//  File layout per the DEV PLAN's BACKEND_PLAN.md §3.2:
//    <baseDirectory>/model-settings/<safeId>.json
//  where `safeId` is `modelId` with `/` replaced by `--` and `::` by `__`
//  so the filename is filesystem-safe.
//
//  Adaptation note: the DEV PLAN's `AppSettings` had top-level load and
//  inference fields (contextLength, gpuOffloadLayers, flashAttention,
//  kvCacheType, temperature, topP, topK, repeatPenalty). AgentCore's
//  `AppSettings` already exists in a slimmer shape — only
//  `defaultSampling: SamplingParams` (temperature/topP/topK/repeatPenalty).
//  So `ModelSettings.initial(modelId:from:)` here:
//    * pulls sampling defaults from the curated catalog entry (GGUF /
//      MLX) if any, otherwise from `settings.defaultSampling`;
//    * uses the catalog's `defaultContextLength` if available, else a
//      reasonable hardcoded fallback (32K) — AgentCore's AppSettings
//      doesn't carry a global context-length field yet.
//
//  // TODO: when AgentCore's AppSettings grows the load-settings fields
//  // (gpuOffloadLayers / flashAttention / kvCacheType), wire them here
//  // instead of the constants below.
//

import Foundation

/// Snapshot of per-model settings. Codable for direct JSON round-trip.
public struct ModelSettings: Codable, Sendable, Equatable {
    public var modelId: String
    public var loadSettings: LoadSettings
    public var inferenceSettings: InferenceSettings
    public var savedAt: Date

    public struct LoadSettings: Codable, Sendable, Equatable {
        public var contextLength: Int
        public var gpuOffloadLayers: Int
        public var flashAttention: Bool
        public var kvCacheType: String

        public init(contextLength: Int,
                    gpuOffloadLayers: Int,
                    flashAttention: Bool,
                    kvCacheType: String) {
            self.contextLength = contextLength
            self.gpuOffloadLayers = gpuOffloadLayers
            self.flashAttention = flashAttention
            self.kvCacheType = kvCacheType
        }
    }

    public struct InferenceSettings: Codable, Sendable, Equatable {
        public var temperature: Double
        public var topP: Double
        public var topK: Int
        public var repeatPenalty: Double
        /// Optional completion cap. nil = backend default.
        public var maxTokens: Int?

        public init(temperature: Double,
                    topP: Double,
                    topK: Int,
                    repeatPenalty: Double,
                    maxTokens: Int? = nil) {
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.repeatPenalty = repeatPenalty
            self.maxTokens = maxTokens
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            temperature = try c.decode(Double.self, forKey: .temperature)
            topP = try c.decode(Double.self, forKey: .topP)
            topK = try c.decode(Int.self, forKey: .topK)
            repeatPenalty = try c.decode(Double.self, forKey: .repeatPenalty)
            maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        }

        private enum CodingKeys: String, CodingKey {
            case temperature, topP, topK, repeatPenalty, maxTokens
        }
    }

    public init(modelId: String,
                loadSettings: LoadSettings,
                inferenceSettings: InferenceSettings,
                savedAt: Date) {
        self.modelId = modelId
        self.loadSettings = loadSettings
        self.inferenceSettings = inferenceSettings
        self.savedAt = savedAt
    }

    // MARK: Load-settings defaults
    //
    // AgentCore's AppSettings doesn't carry global load-settings fields
    // yet, so these are sensible static defaults. Drop them when
    // AppSettings grows the corresponding fields.
    public static let defaultContextLength: Int = 32_768
    public static let defaultGPUOffloadLayers: Int = -1   // -1 = "all available"
    public static let defaultFlashAttention: Bool = true
    public static let defaultKVCacheType: String = "f16"

    /// Build initial snapshot at first activation. Reads catalog-published
    /// per-model values FIRST (defaultContextLength + samplingDefaults),
    /// AppSettings.defaultSampling as fallback. This means new model
    /// activations get the FULL author-recommended capacity out of the
    /// box (e.g. gpt-oss 120B at 131K ctx, Qwen 3.6 27B at 262K) instead
    /// of a hardcoded fallback.
    public static func initial(modelId: String, from settings: AppSettings) -> ModelSettings {
        let mlx = CuratedMLXCatalog.model(forRepoId: modelId)
        let defaultCtx = mlx?.defaultContextLength ?? defaultContextLength
        let s = settings.defaultSampling
        let sampling = mlx?.samplingDefaults

        return ModelSettings(
            modelId: modelId,
            loadSettings: LoadSettings(
                contextLength: defaultCtx,
                gpuOffloadLayers: defaultGPUOffloadLayers,
                flashAttention: defaultFlashAttention,
                kvCacheType: defaultKVCacheType
            ),
            inferenceSettings: InferenceSettings(
                temperature: sampling?.temperature ?? s.temperature,
                topP: sampling?.topP ?? s.topP,
                topK: sampling?.topK ?? s.topK,
                repeatPenalty: sampling?.repeatPenalty ?? s.repeatPenalty,
                maxTokens: s.maxTokens
            ),
            savedAt: Date()
        )
    }

    /// Convert inference settings to the sampling shape used by AgentLoop.
    public func samplingParams() -> SamplingParams {
        SamplingParams(
            temperature: inferenceSettings.temperature,
            topP: inferenceSettings.topP,
            topK: inferenceSettings.topK,
            repeatPenalty: inferenceSettings.repeatPenalty,
            maxTokens: inferenceSettings.maxTokens
        )
    }
}

/// Actor-based store. Per-model JSON files are light reads/writes; the
/// actor adds an in-memory cache so repeated `load(...)` calls within a
/// session don't re-hit disk. The base directory is injectable.
public actor ModelSettingsStore {

    public static let shared = ModelSettingsStore()

    private let directoryURL: URL
    private let log: SessionLog?
    private var cache: [String: ModelSettings] = [:]

    /// - Parameters:
    ///   - directoryURL: Directory the per-model JSON files live in.
    ///     Production passes
    ///     `~/Library/Application Support/VibeCoder/model-settings`; tests
    ///     pass a temp dir.
    ///   - log: Where persist failures get reported. Defaults to
    ///     `SessionLog.shared`.
    public init(directoryURL: URL? = nil, log: SessionLog? = nil) {
        if let custom = directoryURL {
            self.directoryURL = custom
        } else {
            self.directoryURL = AppSupport.directory("model-settings")
        }
        self.log = log ?? SessionLog.shared
    }

    /// Single activation seam: merge backend-advertised context into stored
    /// settings, persist when larger, return the effective snapshot.
    public func applyActivation(
        modelId: String,
        defaults: AppSettings,
        advertised: Int?
    ) async -> ModelSettings {
        var settings = await load(modelId: modelId, defaults: defaults)
        guard let advertised, advertised > 0 else { return settings }
        let effective = ContextBudget.effectiveContextLength(
            stored: settings.loadSettings.contextLength,
            advertised: advertised)
        guard effective > settings.loadSettings.contextLength else { return settings }
        settings.loadSettings.contextLength = effective
        await save(settings)
        return settings
    }

    /// Batch activation after `listModels()` — refreshModels, connection test.
    public func applyActivations(
        models: [ModelDescriptor],
        defaults: AppSettings
    ) async {
        for model in models {
            _ = await applyActivation(
                modelId: model.id,
                defaults: defaults,
                advertised: model.contextLength)
        }
    }

    /// Returns the cached or loaded settings for `modelId`. If no JSON
    /// file exists yet, creates initial state from `defaults` and persists
    /// it so subsequent loads (and UI sliders) have something to mutate.
    public func load(modelId: String, defaults: AppSettings) async -> ModelSettings {
        if let cached = cache[modelId] { return cached }
        let fileURL = url(for: modelId)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? Self.decoder.decode(ModelSettings.self, from: data) {
            cache[modelId] = decoded
            return decoded
        }
        // No saved state — initial population from catalog + globals.
        let initial = ModelSettings.initial(modelId: modelId, from: defaults)
        cache[modelId] = initial
        await persist(initial)
        return initial
    }

    /// Persist `settings` atomically. Caller can update specific fields
    /// then call save. Stamps `savedAt` to current time.
    public func save(_ settings: ModelSettings) async {
        var snapshot = settings
        snapshot.savedAt = Date()
        cache[snapshot.modelId] = snapshot
        await persist(snapshot)
    }

    /// Convenience for partial updates — used by the sliders UI. Loads
    /// current state (creating initial from defaults if needed), runs the
    /// caller's mutation, persists.
    public func update(modelId: String,
                       defaults: AppSettings,
                       mutate: @Sendable (inout ModelSettings) -> Void) async {
        var current = await load(modelId: modelId, defaults: defaults)
        mutate(&current)
        await save(current)
    }

    /// Remove the persisted settings for a model. Next `load(...)` will
    /// re-initialise from globals.
    public func remove(modelId: String) {
        cache.removeValue(forKey: modelId)
        try? FileManager.default.removeItem(at: url(for: modelId))
    }

    /// Test-visible: returns the on-disk filename the store will use for
    /// a given modelId.
    public func filenameForTesting(modelId: String) -> String {
        url(for: modelId).lastPathComponent
    }

    // MARK: Internals

    private func persist(_ snapshot: ModelSettings) async {
        do {
            try FileManager.default.createDirectory(at: directoryURL,
                                                    withIntermediateDirectories: true)
            let fileURL = url(for: snapshot.modelId)
            let data = try Self.encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            await log?.write("ModelSettingsStore: save failed for \(snapshot.modelId): \(error)")
        }
    }

    /// Converts "org/name::file.gguf" to a filesystem-safe filename.
    /// Catalog ids are typically "lmstudio-community/Foo-GGUF::bar.gguf";
    /// the "/" and "::" both need to be replaced.
    private func url(for modelId: String) -> URL {
        let safeId = modelId
            .replacingOccurrences(of: "/", with: "--")
            .replacingOccurrences(of: "::", with: "__")
        return directoryURL.appendingPathComponent("\(safeId).json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
