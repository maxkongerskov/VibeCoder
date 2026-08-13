//
//  AppSettings.swift
//
//  Persisted app-level settings. UserDefaults-backed (same shape as the
//  original AgentOS so users can migrate by copying their plist), with a
//  Codable schema and decodeIfPresent + defaults for every field — so
//  adding a new setting in a future build never wipes existing state.
//

import Foundation

/// User preference for `run_shell` seatbelt (PB8 / PC2).
/// Wired via env keys `VIBECODER_SHELL_SEATBELT` / `AGENTOS_SHELL_SEATBELT`
/// so SafeBash keeps Auto-mode defaults without redesign.
public enum ShellSeatbeltPreference: String, Codable, Sendable, Equatable, CaseIterable {
    /// Default: seatbelt on for Auto (`ExecutionMode.edit`) only (PB8 honesty).
    case auto
    /// Force seatbelt on for every execution mode.
    case always
    /// Force seatbelt off (not recommended for untrusted prompts).
    case never

    public var label: String {
        switch self {
        case .auto: return "Auto (Auto mode only)"
        case .always: return "Always on"
        case .never: return "Off"
        }
    }

    public var detail: String {
        switch self {
        case .auto:
            return "Uses sandbox-exec write fence when Permission mode is Auto. Off in Plan/Ask/Full unless you force Always."
        case .always:
            return "Always wrap run_shell with the seatbelt write fence (when sandbox-exec is available)."
        case .never:
            return "Never apply seatbelt. Shell still goes through Safe Mode / approval rules."
        }
    }

    /// Env value for SafeBash, or nil to leave unset (auto).
    public var environmentValue: String? {
        switch self {
        case .auto: return nil
        case .always: return "1"
        case .never: return "0"
        }
    }

    /// Apply preference to process environment for SafeBash.isSeatbeltEnabled.
    public func applyToProcessEnvironment() {
        let keys = ["VIBECODER_SHELL_SEATBELT", "AGENTOS_SHELL_SEATBELT"]
        if let v = environmentValue {
            for k in keys { setenv(k, v, 1) }
        } else {
            for k in keys { unsetenv(k) }
        }
    }
}

public struct AppSettings: Codable, Sendable, Equatable {

    // MARK: - Backend connection

    public var backend: BackendIdentifier
    public var lmStudioHost: String
    public var lmStudioPort: Int
    public var lmStudioAPIKey: String
    public var lmStudioAutoConnect: Bool
    public var exoHost: String
    public var exoPort: Int
    public var exoModelID: String
    public var exoAutoConnect: Bool
    public var omlxHost: String
    public var omlxPort: Int
    public var omlxAPIKey: String
    /// Ollama HTTP host (OpenAI-compatible `/v1`, default 11434).
    public var ollamaHost: String
    public var ollamaPort: Int
    public var ollamaAutoConnect: Bool
    /// Unsloth Studio HTTP host (OpenAI-compatible `/v1` + load/unload, default 8888).
    public var unslothHost: String
    public var unslothPort: Int
    /// Bearer token for Unsloth Studio. When empty, backend tries the local agent key file.
    public var unslothAPIKey: String
    public var unslothAutoConnect: Bool
    // MARK: - Custom OpenAI-compatible endpoint

    /// Base URL of a custom OpenAI-compatible API (e.g. OpenRouter, Groq,
    /// Together, vLLM, llama.cpp server, text-generation-webui).
    public var customEndpoint: String

    /// Optional API key for the custom endpoint. Passes as `Bearer <key>`
    /// in the Authorization header when non-empty.
    public var customAPIKey: String

    // MARK: - xAI Grok cloud

    /// xAI API key (`xai-…`). Used as `Bearer` for `https://api.x.ai/v1`.
    public var xaiAPIKey: String

    // MARK: - Safe Mode allow-lists

    /// Path prefixes the agent may read/write when Safe Mode is armed.
    /// Empty list = all mutating tools denied. Tilde paths are expanded
    /// at runtime when building `SafeModeConfig`.
    public var safeModeAllowedPaths: [String]

    /// Shell command prefixes allowed when Safe Mode is armed.
    public var safeModeAllowedShellPrefixes: [String]

    // MARK: - Privacy

    /// Whether anonymous crash-report telemetry is opted in. Off by
    /// default; toggling takes effect after restart (the crash handler
    /// installs at process boot). Sentry was removed — this flag is retained
    /// for schema compatibility and stays unused unless a reporter is re-added.
    public var crashReportingEnabled: Bool

    /// Master switch for macOS user notifications (turn complete, budget, etc.).
    /// Default **true**. Does not bypass OS permission prompts.
    public var notificationsEnabled: Bool

    // MARK: - Default sampling

    /// Default sampling params used when no per-model or per-conversation
    /// override is set. Tuned for coding.
    public var defaultSampling: SamplingParams

    // MARK: - System prompt

    /// Factory default for `systemPrompt` — Settings "Reset to default" uses this.
    public static let defaultSystemPrompt =
        "You are a careful, precise coding agent. Edit by patch when possible; verify your changes."

    /// Global system prompt prefix (user instructions). The agent loop
    /// injects this via `hostSystemPrompt` **before** project AGENTS.md /
    /// harness editing rules, so the user can pre-inform the agent.
    public var systemPrompt: String

    // MARK: - Agent loop

    public var maxAgentIterations: Int
    /// Iteration cap for HEADLESS / scheduled runs. Higher than the
    /// interactive cap because unattended overnight work (the
    /// build-an-app-while-you-sleep case) needs a long horizon. Bounded
    /// rather than unlimited so a runaway loop still terminates; the
    /// stall detector + verification gates remain the inner guards.
    public var headlessMaxIterations: Int
    public var verifyEdits: Bool
    /// Identical tool-call repetitions before the stall detector halts.
    public var stallWindow: Int

    /// Soft cap on the model's context window (tokens). `0` = use the
    /// backend-advertised / stored model length fully. When set, the
    /// effective window is `min(model, maxContextWindowTokens)`.
    public var maxContextWindowTokens: Int

    /// Auto-compact threshold as a percent of the effective context
    /// window (10…100). History is elided when estimated tokens exceed
    /// this fraction. Default 70 matches the historical “reserve ~30%
    /// for the reply” budget. Lower values compact earlier (safer for
    /// long agent runs); higher values keep more history.
    public var autoCompactThresholdPercent: Double

    /// **Chat mode** (legacy name `rawMode` in JSON): when true, pure
    /// chat with the model — empty system prompt, no harness nudges /
    /// BuildGuard / project rules. Tools limited to `web_search` +
    /// `read_file`. When false (**Agent mode**, default): full harness
    /// and the full tool surface. Toggle from the input bar.
    public var rawMode: Bool

    // MARK: - Grok-class memory / compaction (port flags)

    /// Hybrid cross-session memory (index + search + first-turn inject).
    public var memoryEnabled: Bool
    /// Background dream consolidation of session logs into MEMORY.md.
    public var dreamEnabled: Bool
    /// Full-replace compaction when over context budget.
    public var fullReplaceCompactEnabled: Bool
    /// Also inject project MEMORY.md / DECISIONS.md (retrieve + files).
    public var injectProjectMemory: Bool

    // MARK: - Tools

    /// Per-tool enable switches (Settings → Tools). Keyed by `Tool.name`;
    /// a missing key means ENABLED, so newly shipped tools default on.
    /// The agent loop consumes this via `disabledToolNames`.
    public var toolEnabled: [String: Bool]

    /// Names the user explicitly switched off — the shape AgentLoop's
    /// Configuration wants.
    public var disabledToolNames: Set<String> {
        Set(toolEnabled.filter { !$0.value }.keys)
    }

    // MARK: - LocalAPIServer (Xcode Intelligence integration)

    public var localAPIEnabled: Bool
    public var localAPIPort: Int
    /// Opt-in: run a **bounded multi-step AgentLoop** on LocalAPI
    /// `/v1/chat/completions` (tool execute + re-prompt). Default **false**
    /// (Xcode-safe proxy with `tools: []`). Hard-capped iterations on the
    /// server (see `LocalAPIServer.agentLoopMaxIterations`).
    public var localAPIAgentToolsEnabled: Bool

    /// Seatbelt write fence for `run_shell` (PB8). Default **auto**.
    public var shellSeatbeltPreference: ShellSeatbeltPreference

    // MARK: - Xcode MCP (mcpbridge)

    /// When true, AgentOS connects to Xcode's built-in MCP server via
    /// `mcpbridge` and proxies its native tools (BuildProject,
    /// XcodeRead, RenderPreview, …) into the agent loop.
    public var xcodeMCPEnabled: Bool

    // MARK: - MCP servers (user-configured, Streamable HTTP + stdio)
    //
    // Ported from Grok Build's config schema. Each entry is an MCP server
    // the user has registered (GitHub, Slack, a local tool, etc.). The
    // agent loop connects to all enabled servers at turn start and exposes
    // their tools alongside VibeCoder's builtins, namespaced `server__tool`.
    public var mcpServers: [MCPServerConfig]

    // MARK: - First-run

    public var hasCompletedOnboarding: Bool

    // MARK: - Appearance
    //
    // Surface in Settings → General. These were mock @State on the view
    // previously; persisting them on AppSettings so toggling Dark/Light
    // and Font Size actually sticks across launches.

    /// One of "system", "light", "dark". Applied at RootView via
    /// `.preferredColorScheme(...)`.
    public var colorScheme: String

    /// Multiplier applied to chat body text size. 0.875 = Small,
    /// 1.0 = Default, 1.25 = Large. Read by MessageBubbleViewV2,
    /// PendingAssistantBubble, and MarkdownTextView.
    public var chatFontScale: Double

    /// When true, PendingAssistantBubble cycles playful waiting phrases
    /// instead of context-aware tool labels. Off by default (Claude parity).
    public var playfulWaitingLabels: Bool

    /// When true (default), strip model control chrome (channel tokens,
    /// think-tag markup leaks) for **presentation** only. Turn off in
    /// Settings → Advanced to see raw model strings. Does not rewrite prose.
    public var cleanModelChrome: Bool

    // MARK: - Orchestrator / Worker roles (two-model architecture)
    //
    // When `orchestratorEnabled` is true, a small instruct "orchestrator"
    // model plans the task into one brief, then a "worker" model executes it.
    // Each role can target its own (backend, model). When false, the app runs
    // the classic single-model path off `backend` above.

    public var orchestratorEnabled: Bool
    public var orchestratorBackend: BackendIdentifier
    public var orchestratorModelID: String
    public var workerBackend: BackendIdentifier
    public var workerModelID: String
    /// Whether each role has been DELIBERATELY assigned by the user. Without
    /// these, an unset role still equals its default backend (.lmStudio) and
    /// would falsely light up — making O and W look coupled. A role's badge
    /// highlights only when its `…BackendSet` flag is true.
    public var orchestratorBackendSet: Bool
    public var workerBackendSet: Bool

    /// True only when both roles point at the EXACT same (backend, model) —
    /// "one-model mode" (allowed, but flagged in the UI).
    public var rolesCollide: Bool {
        orchestratorEnabled && orchestratorBackend == workerBackend
            && !orchestratorModelID.isEmpty && orchestratorModelID == workerModelID
    }

    public init(
        backend: BackendIdentifier = .lmStudio,
        lmStudioHost: String = "127.0.0.1",
        lmStudioPort: Int = 1234,
        lmStudioAPIKey: String = "",
        lmStudioAutoConnect: Bool = true,
        exoHost: String = "127.0.0.1",
        exoPort: Int = 52415,
        exoModelID: String = "",
        exoAutoConnect: Bool = false,
        omlxHost: String = "127.0.0.1",
        omlxPort: Int = 8080,
        omlxAPIKey: String = "",
        ollamaHost: String = "127.0.0.1",
        ollamaPort: Int = 11434,
        ollamaAutoConnect: Bool = false,
        unslothHost: String = "127.0.0.1",
        unslothPort: Int = 8888,
        unslothAPIKey: String = "",
        unslothAutoConnect: Bool = false,
        customEndpoint: String = "http://127.0.0.1:1234/v1",
        customAPIKey: String = "",
        xaiAPIKey: String = "",
        defaultSampling: SamplingParams = .coder,
        systemPrompt: String = AppSettings.defaultSystemPrompt,
        maxAgentIterations: Int = 30,
        headlessMaxIterations: Int = 100,
        verifyEdits: Bool = true,
        stallWindow: Int = 3,
        maxContextWindowTokens: Int = 0,
        autoCompactThresholdPercent: Double = 70,
        rawMode: Bool = false,
        toolEnabled: [String: Bool] = [:],
        safeModeAllowedPaths: [String] = ["~/code/", "~/Downloads/", "/tmp/"],
        safeModeAllowedShellPrefixes: [String] = ["swift build", "git", "ls"],
        localAPIEnabled: Bool = false,
        localAPIPort: Int = 11435,
        localAPIAgentToolsEnabled: Bool = false,
        shellSeatbeltPreference: ShellSeatbeltPreference = .auto,
        xcodeMCPEnabled: Bool = false,
        hasCompletedOnboarding: Bool = false,
        crashReportingEnabled: Bool = false,
        notificationsEnabled: Bool = true,
        colorScheme: String = "system",
        chatFontScale: Double = 1.0,
        playfulWaitingLabels: Bool = false,
        cleanModelChrome: Bool = true,
        orchestratorEnabled: Bool = false,
        orchestratorBackend: BackendIdentifier = .lmStudio,
        orchestratorModelID: String = "",
        workerBackend: BackendIdentifier = .lmStudio,
        workerModelID: String = "",
        orchestratorBackendSet: Bool = false,
        workerBackendSet: Bool = false,
        mcpServers: [MCPServerConfig] = [],
        memoryEnabled: Bool = true,
        dreamEnabled: Bool = true,
        fullReplaceCompactEnabled: Bool = true,
        injectProjectMemory: Bool = true
    ) {
        self.backend = backend
        self.lmStudioHost = lmStudioHost
        self.lmStudioPort = lmStudioPort
        self.lmStudioAPIKey = lmStudioAPIKey
        self.lmStudioAutoConnect = lmStudioAutoConnect
        self.exoHost = exoHost
        self.exoPort = exoPort
        self.exoModelID = exoModelID
        self.exoAutoConnect = exoAutoConnect
        self.omlxHost = omlxHost
        self.omlxPort = omlxPort
        self.omlxAPIKey = omlxAPIKey
        self.ollamaHost = ollamaHost
        self.ollamaPort = ollamaPort
        self.ollamaAutoConnect = ollamaAutoConnect
        self.unslothHost = unslothHost
        self.unslothPort = unslothPort
        self.unslothAPIKey = unslothAPIKey
        self.unslothAutoConnect = unslothAutoConnect
        self.defaultSampling = defaultSampling
        self.systemPrompt = systemPrompt
        self.maxAgentIterations = maxAgentIterations
        self.headlessMaxIterations = headlessMaxIterations
        self.verifyEdits = verifyEdits
        self.stallWindow = max(2, stallWindow)
        self.maxContextWindowTokens = max(0, maxContextWindowTokens)
        self.autoCompactThresholdPercent = min(100, max(10, autoCompactThresholdPercent))
        self.rawMode = rawMode
        self.toolEnabled = toolEnabled
        self.safeModeAllowedPaths = safeModeAllowedPaths
        self.safeModeAllowedShellPrefixes = safeModeAllowedShellPrefixes
        self.localAPIEnabled = localAPIEnabled
        self.localAPIPort = localAPIPort
        self.localAPIAgentToolsEnabled = localAPIAgentToolsEnabled
        self.shellSeatbeltPreference = shellSeatbeltPreference
        self.xcodeMCPEnabled = xcodeMCPEnabled
        self.mcpServers = mcpServers
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.crashReportingEnabled = crashReportingEnabled
        self.notificationsEnabled = notificationsEnabled
        self.colorScheme = colorScheme
        self.chatFontScale = chatFontScale
        self.playfulWaitingLabels = playfulWaitingLabels
        self.cleanModelChrome = cleanModelChrome
        self.customEndpoint = customEndpoint
        self.customAPIKey = customAPIKey
        self.xaiAPIKey = xaiAPIKey
        self.orchestratorEnabled = orchestratorEnabled
        self.orchestratorBackend = orchestratorBackend
        self.orchestratorModelID = orchestratorModelID
        self.workerBackend = workerBackend
        self.workerModelID = workerModelID
        self.orchestratorBackendSet = orchestratorBackendSet
        self.workerBackendSet = workerBackendSet
        self.memoryEnabled = memoryEnabled
        self.dreamEnabled = dreamEnabled
        self.fullReplaceCompactEnabled = fullReplaceCompactEnabled
        self.injectProjectMemory = injectProjectMemory
    }

    enum CodingKeys: String, CodingKey {
        case backend, lmStudioHost, lmStudioPort, lmStudioAPIKey,
             lmStudioAutoConnect, exoHost, exoPort, exoModelID,
             exoAutoConnect, omlxHost, omlxPort, omlxAPIKey,
             ollamaHost, ollamaPort, ollamaAutoConnect,
             unslothHost, unslothPort, unslothAPIKey, unslothAutoConnect,
              customEndpoint, customAPIKey, xaiAPIKey,
              defaultSampling, systemPrompt, maxAgentIterations,
             headlessMaxIterations,
             verifyEdits, stallWindow,
             maxContextWindowTokens, autoCompactThresholdPercent,
             rawMode, toolEnabled,
             safeModeAllowedPaths, safeModeAllowedShellPrefixes,
             localAPIEnabled, localAPIPort, localAPIAgentToolsEnabled,
             shellSeatbeltPreference,
             xcodeMCPEnabled,
             hasCompletedOnboarding, crashReportingEnabled, notificationsEnabled,
             colorScheme, chatFontScale, playfulWaitingLabels, cleanModelChrome,
             orchestratorEnabled, orchestratorBackend, orchestratorModelID,
             workerBackend, workerModelID,
             orchestratorBackendSet, workerBackendSet,
             mcpServers,
             memoryEnabled, dreamEnabled, fullReplaceCompactEnabled, injectProjectMemory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.backend = try c.decodeIfPresent(BackendIdentifier.self, forKey: .backend) ?? .lmStudio
        self.lmStudioHost = try c.decodeIfPresent(String.self, forKey: .lmStudioHost) ?? "127.0.0.1"
        self.lmStudioPort = try c.decodeIfPresent(Int.self, forKey: .lmStudioPort) ?? 1234
        self.lmStudioAPIKey = try c.decodeIfPresent(String.self, forKey: .lmStudioAPIKey) ?? ""
        self.lmStudioAutoConnect = try c.decodeIfPresent(Bool.self, forKey: .lmStudioAutoConnect) ?? true
        self.exoHost = try c.decodeIfPresent(String.self, forKey: .exoHost) ?? "127.0.0.1"
        self.exoPort = try c.decodeIfPresent(Int.self, forKey: .exoPort) ?? 52415
        self.exoModelID = try c.decodeIfPresent(String.self, forKey: .exoModelID) ?? ""
        self.exoAutoConnect = try c.decodeIfPresent(Bool.self, forKey: .exoAutoConnect) ?? false
        self.omlxHost = try c.decodeIfPresent(String.self, forKey: .omlxHost) ?? "127.0.0.1"
        self.omlxPort = try c.decodeIfPresent(Int.self, forKey: .omlxPort) ?? 8080
        self.omlxAPIKey = try c.decodeIfPresent(String.self, forKey: .omlxAPIKey) ?? ""
        self.ollamaHost = try c.decodeIfPresent(String.self, forKey: .ollamaHost) ?? "127.0.0.1"
        self.ollamaPort = try c.decodeIfPresent(Int.self, forKey: .ollamaPort) ?? 11434
        self.ollamaAutoConnect = try c.decodeIfPresent(Bool.self, forKey: .ollamaAutoConnect) ?? false
        self.unslothHost = try c.decodeIfPresent(String.self, forKey: .unslothHost) ?? "127.0.0.1"
        self.unslothPort = try c.decodeIfPresent(Int.self, forKey: .unslothPort) ?? 8888
        self.unslothAPIKey = try c.decodeIfPresent(String.self, forKey: .unslothAPIKey) ?? ""
        self.unslothAutoConnect = try c.decodeIfPresent(Bool.self, forKey: .unslothAutoConnect) ?? false
        // Legacy llamaHost/llamaPort/activeLlamaModelID/load overrides ignored —
        // bundled llama.cpp product removed; BackendIdentifier migrates "llamaCpp"→ollama.
        self.defaultSampling = try c.decodeIfPresent(SamplingParams.self, forKey: .defaultSampling) ?? .coder
        self.systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
            ?? AppSettings.defaultSystemPrompt
        self.maxAgentIterations = try c.decodeIfPresent(Int.self, forKey: .maxAgentIterations) ?? 30
        self.headlessMaxIterations = try c.decodeIfPresent(Int.self, forKey: .headlessMaxIterations) ?? 100
        self.verifyEdits = try c.decodeIfPresent(Bool.self, forKey: .verifyEdits) ?? true
        self.stallWindow = max(2, try c.decodeIfPresent(Int.self, forKey: .stallWindow) ?? 3)
        self.maxContextWindowTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .maxContextWindowTokens) ?? 0)
        self.autoCompactThresholdPercent = min(100, max(10,
            try c.decodeIfPresent(Double.self, forKey: .autoCompactThresholdPercent) ?? 70))
        self.rawMode = try c.decodeIfPresent(Bool.self, forKey: .rawMode) ?? false
        self.toolEnabled = try c.decodeIfPresent([String: Bool].self, forKey: .toolEnabled) ?? [:]
        self.safeModeAllowedPaths = try c.decodeIfPresent([String].self, forKey: .safeModeAllowedPaths)
            ?? LegacySettingsMigration.migrateSafeModePaths()
        self.safeModeAllowedShellPrefixes = try c.decodeIfPresent([String].self, forKey: .safeModeAllowedShellPrefixes)
            ?? LegacySettingsMigration.migrateSafeModeShell()
        self.localAPIEnabled = try c.decodeIfPresent(Bool.self, forKey: .localAPIEnabled) ?? false
        self.localAPIPort = try c.decodeIfPresent(Int.self, forKey: .localAPIPort) ?? 11435
        self.localAPIAgentToolsEnabled = try c.decodeIfPresent(Bool.self, forKey: .localAPIAgentToolsEnabled) ?? false
        self.shellSeatbeltPreference = try c.decodeIfPresent(ShellSeatbeltPreference.self, forKey: .shellSeatbeltPreference) ?? .auto
        self.xcodeMCPEnabled = try c.decodeIfPresent(Bool.self, forKey: .xcodeMCPEnabled) ?? false
        self.mcpServers = try c.decodeIfPresent([MCPServerConfig].self, forKey: .mcpServers) ?? []
        self.hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        self.crashReportingEnabled = try c.decodeIfPresent(Bool.self, forKey: .crashReportingEnabled) ?? false
        self.notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        self.colorScheme = try c.decodeIfPresent(String.self, forKey: .colorScheme) ?? "system"
        self.chatFontScale = try c.decodeIfPresent(Double.self, forKey: .chatFontScale) ?? 1.0
        self.playfulWaitingLabels = try c.decodeIfPresent(Bool.self, forKey: .playfulWaitingLabels) ?? false
        self.cleanModelChrome = try c.decodeIfPresent(Bool.self, forKey: .cleanModelChrome) ?? true
        self.customEndpoint = try c.decodeIfPresent(String.self, forKey: .customEndpoint) ?? "http://127.0.0.1:1234/v1"
        self.customAPIKey = try c.decodeIfPresent(String.self, forKey: .customAPIKey) ?? ""
        self.xaiAPIKey = try c.decodeIfPresent(String.self, forKey: .xaiAPIKey) ?? ""
        self.orchestratorEnabled = try c.decodeIfPresent(Bool.self, forKey: .orchestratorEnabled) ?? false
        self.orchestratorBackend = try c.decodeIfPresent(BackendIdentifier.self, forKey: .orchestratorBackend) ?? .lmStudio
        self.orchestratorModelID = try c.decodeIfPresent(String.self, forKey: .orchestratorModelID) ?? ""
        self.workerBackend = try c.decodeIfPresent(BackendIdentifier.self, forKey: .workerBackend) ?? .lmStudio
        self.workerModelID = try c.decodeIfPresent(String.self, forKey: .workerModelID) ?? ""
        self.orchestratorBackendSet = try c.decodeIfPresent(Bool.self, forKey: .orchestratorBackendSet) ?? false
        self.workerBackendSet = try c.decodeIfPresent(Bool.self, forKey: .workerBackendSet) ?? false
        self.memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? true
        self.dreamEnabled = try c.decodeIfPresent(Bool.self, forKey: .dreamEnabled) ?? true
        self.fullReplaceCompactEnabled = try c.decodeIfPresent(Bool.self, forKey: .fullReplaceCompactEnabled) ?? true
        self.injectProjectMemory = try c.decodeIfPresent(Bool.self, forKey: .injectProjectMemory) ?? true
    }

    /// Build the runtime `SafeModeConfig` from persisted allow-lists.
    public func safeModeConfig() -> SafeModeConfig {
        let expandedPaths = safeModeAllowedPaths.map {
            ($0 as NSString).expandingTildeInPath
        }
        return SafeModeConfig(
            allowedPathPrefixes: expandedPaths,
            allowedShellPrefixes: safeModeAllowedShellPrefixes
        )
    }

    /// Build Safe Mode for an agent turn, seeding open project/worktree roots
    /// and unioning SafeBash inspect shell primaries (Wave B S10a).
    ///
    /// Use this whenever Plan/Ask (or manual Safe Mode) installs Safe Mode so
    /// inspect shell and in-project paths are not dual-denied by narrow
    /// defaults (`swift build`/`git`/`ls` + `~/code/` only).
    public func safeModeConfig(
        projectRoots: [URL],
        unionReadOnlyShellPrefixes: Bool = true
    ) -> SafeModeConfig {
        safeModeConfig().reconciledForAutoSafeMode(
            projectRoots: projectRoots,
            unionReadOnlyShellPrefixes: unionReadOnlyShellPrefixes
        )
    }
}

public actor SettingsStore {

    public static let shared = SettingsStore()

    private let defaultsKey = LegacySettingsMigration.appSettingsDefaultsKey
    private var cached: AppSettings

    public init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.cached = decoded
        } else {
            // First run: source legacy Safe Mode allow-lists before they
            // can be cleared. Persist so subsequent `clearLegacyKeys` is safe.
            var fresh = AppSettings()
            fresh.safeModeAllowedPaths = LegacySettingsMigration.migrateSafeModePaths()
            fresh.safeModeAllowedShellPrefixes = LegacySettingsMigration.migrateSafeModeShell()
            self.cached = fresh
            if let data = try? JSONEncoder().encode(fresh) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
        // Clear legacy keys after first load so AppSettings is sole source.
        LegacySettingsMigration.clearLegacyKeys()
    }

    public func current() -> AppSettings { cached }

    public func update(_ change: @Sendable (inout AppSettings) -> Void) {
        var copy = cached
        change(&copy)
        cached = copy
        persist()
    }

    public func replace(_ new: AppSettings) {
        cached = new
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(cached)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            Diagnostics.error("Failed to persist settings: \(error.localizedDescription)")
        }
    }
}
