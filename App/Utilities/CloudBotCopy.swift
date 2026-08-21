//
//  CloudBotCopy.swift
//  Slice 0 — CloudBots labeled cloud (not local BYO HTTP).
//

import Foundation

/// Settings + chat-chrome honesty copy for CloudBots.
/// Always cloud. Never "nothing leaves your Mac." Not a storefront.
enum CloudBotCopy {
    static let settingsTitle = "CloudBots"
    static let cloudLabel = "Cloud"
    static let toggleTitle = "Enable CloudBots (opt-in)"

    static let intro =
        "CloudBots are named cloud teammates. They are not a local-inference path and not a BYO HTTP backend (LM Studio, Ollama, oMLX, EXO, Unsloth). Prompts, tool context, and any weights they need leave this Mac."

    static let honesty =
        "Not local-first. Not a storefront. Default agent stays in-app AgentLoop against your BYO HTTP server."

    static func status(enabled: Bool) -> String {
        enabled
            ? "On. CloudBots run in the cloud. Data leaves this Mac."
            : "Off (default). In-app AgentLoop stays on your BYO HTTP server."
    }

    static let privacyBlurb =
        "Default agent is BYO HTTP on this Mac (LM Studio, Ollama, oMLX, EXO, Unsloth, or a custom /v1 you point at loopback). CloudBots are cloud teammates: prompts, tool context, and any weights they need leave this Mac. Custom remote /v1, cloud API keys, MCP tools, and agent shell/network commands can also send data off-box when you configure or allow them. See LEGAL.md."

    static let chipHelp =
        "CloudBots: cloud, not local. Prompts leave this Mac."

    static let chipAccessibility = "CloudBots, cloud. Data leaves this Mac."
}
