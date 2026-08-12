//
//  SettingsDiscoverabilityCopy.swift
//  Polish P2 — pure strings for Settings help (defaults stay honest).
//

import Foundation
import AgentCore

/// View-layer discoverability copy. Does not change persisted defaults.
enum SettingsDiscoverabilityCopy {
    static let localAPIIntro =
        "Loopback-only OpenAI-compatible server for Xcode Intelligence and other clients on this Mac. Default: completions proxy (tools: []). Optional multi-step agent loop is opt-in below — not Cursor-style Xcode agents by default. No auth token; bind is localhost."

    static let agentToolsToggleTitle = "Agent loop on Local API (opt-in)"

    static let agentToolsHelpDefaultOff =
        "Default: Off (recommended for Xcode). When On, chat completions run a bounded multi-step tool loop (model → tools → model) with a hard iteration cap. Leave Off for Xcode Intelligence. Tools use the same permissions as in-app chat (unsandboxed app)."

    static func agentToolsStatus(enabled: Bool) -> String {
        enabled
            ? "Status: agent loop On — tools execute server-side (capped iterations; not unbounded)."
            : "Status: agent loop off (default) — completions proxy only, tools: []."
    }

    static let seatbeltIntro =
        "Optional write fence for run_shell (sandbox-exec). Default is Auto: on only when Permission mode is Auto. This is not macOS App Sandbox — the app entitlements file is empty (full-trust agent)."

    static func seatbeltCurrent(_ pref: ShellSeatbeltPreference) -> String {
        switch pref {
        case .auto: return "Auto (default) — fence when Permission mode is Auto"
        case .always: return "Always on"
        case .never: return "Off"
        }
    }

    static let grantsIntro =
        "Settings → Tools. Durable Always allow / Never allow from shell and path prompts. Not Permission mode, Safe Mode allow-lists, or shell seatbelt."

    static let grantsEmpty =
        "No Always/Never grants yet. When the agent asks for shell or path approval, choose Always or Never to pin a grant here."
}
