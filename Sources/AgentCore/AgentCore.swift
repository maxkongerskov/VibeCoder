//
//  AgentCore.swift
//  VibeCoder
//
//  Module entry point. Carries the version constant and a single
//  `AgentCore.bootstrap()` call that the app and CLI both invoke before
//  doing anything else — registers built-in tools, opens the diagnostics
//  channel, primes the model catalog.
//

import Foundation

/// User-facing product identity and on-disk app-support folder name.
public enum AppBranding {
    public static let displayName = "VibeCoder"
    /// `~/Library/Application Support/VibeCoder/`
    public static let appSupportFolderName = "VibeCoder"
    public static let projectsFolderName = "VibeCoder Projects"

    public static var versionLine: String {
        "\(displayName) \(AgentCore.version) (\(AgentCore.build))"
    }
}

public enum AgentCore {

    /// Semantic version of the core library. Bumped on every shipped DMG.
    public static let version = "1.0.5"

    /// Build identifier the app surfaces in About. Filled by the build
    /// script if present, otherwise "dev".
    public static let build = ProcessInfo.processInfo.environment["VIBECODER_BUILD"] ?? "dev"

    /// One-shot bootstrap. Idempotent; safe to call from both the app
    /// launch path and the CLI's first command. Holds a flag so a second
    /// call is a fast no-op.
    public static func bootstrap() async {
        guard await BootstrapState.shared.beginIfNeeded() else { return }

        // Migrate legacy AgentOS Application Support trees before any
        // store opens files under the new VibeCoder root.
        AppSupport.migrateLegacyIfNeeded()

        // Register the built-in tools. Order doesn't matter — registration
        // is keyed by `Tool.name`. The registry rejects duplicates loudly,
        // not silently (see ToolRegistry.register).
        await ToolRegistry.shared.registerBuiltins()

        // Hydrate process grants from durable store (Always/Never across restarts).
        await DurableGrantStore.shared.loadIntoRememberedGrants()

        // Surface the working directory as the default project root. The
        // CLI may override this via --project; the app sets it when a
        // conversation binds to a folder.
        await ProjectContext.shared.setRoot(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        Diagnostics.info("AgentCore \(version) (\(build)) bootstrapped")
    }
}

/// Internal state — guarantees a single bootstrap pass even under
/// parallel callers (e.g., app launch racing with a CLI shim).
private actor BootstrapState {
    static let shared = BootstrapState()
    private var done = false
    func beginIfNeeded() -> Bool {
        if done { return false }
        done = true
        return true
    }
}
