//
//  CloudBotHost.swift
//
//  Slice 0 — named CloudBot host stub.
//  Cloud teammate identity, not a local inference backend, not a storefront.
//  Default agent stays in-app AgentLoop + BYO HTTP. This type is a sibling;
//  it is not wired into AgentLoop.
//

import Foundation

/// Named cloud teammate. Kind is always `.cloud` — never LM Studio / oMLX /
/// Ollama / Unsloth / EXO / custom `/v1`.
public enum CloudBot: Sendable {

    /// Explicitly cloud. Not a `BackendIdentifier`.
    public enum Kind: String, Sendable, Codable, Equatable {
        case cloud
    }

    /// Identity of a cloud teammate. Constructing a handle does not start
    /// AgentLoop, does not send, and does not phone home.
    public struct Handle: Sendable, Equatable, Identifiable, Hashable, Codable {
        public let id: String
        public let name: String
        /// Always `.cloud`. Handles are not local backends.
        public let kind: Kind

        public init(id: String, name: String) {
            self.id = id
            self.name = name
            self.kind = .cloud
        }
    }
}

/// Why a CloudBot stub refuses to send.
public enum CloudBotHostError: Error, Equatable, LocalizedError, Sendable {
    /// Opt-in is off (the default). Nothing is sent.
    case disabled
    /// Slice 0 has no cloud runtime, even if the user opted in.
    case stubNotImplemented

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "CloudBots are off. Default agent stays in-app AgentLoop + BYO HTTP."
        case .stubNotImplemented:
            return "CloudBots host is a stub. No cloud runtime in this slice."
        }
    }
}

/// Opt-in CloudBots host. Not a marketplace, not Electron, not a cloud
/// runtime that replaces local inference.
///
/// Worktree: if a git project is bound, isolation stays `agentcore/<id>`
/// via `WorktreeService`. This host does not invent a second scheme.
public struct CloudBotHost: Sendable, Equatable {

    /// Settings + chrome label. Matches App `CloudBotCopy.cloudLabel`.
    public static let cloudLabel = "Cloud"

    /// No storefront in this slice (or as a host). Always nil.
    public static let marketplaceURL: URL? = nil

    /// Default agent remains AgentLoop + BYO HTTP.
    public static let replacesAgentLoop = false

    /// CloudBots are not a local-inference path.
    public static let replacesLocalInference = false

    /// Same prefix `WorktreeService` uses (`agentcore/<shortId>`).
    public static let worktreeBranchPrefix = "agentcore/"

    /// Opt-in. Default off.
    public var isEnabled: Bool

    /// Kind is always cloud — never a `BackendIdentifier` case.
    public var kind: CloudBot.Kind { .cloud }

    /// Slice 0 cannot send, even when opted in.
    public var canSend: Bool { false }

    public init(enabled: Bool = false) {
        self.isEnabled = enabled
    }

    /// Hook for Sable's Settings flag (`AppSettings.cloudBotsEnabled`).
    public init(settings: AppSettings) {
        self.isEnabled = settings.cloudBotsEnabled
    }

    /// Named handle. Does not start AgentLoop. Does not send.
    public func makeHandle(id: String, name: String) -> CloudBot.Handle {
        CloudBot.Handle(id: id, name: name)
    }

    /// Isolation for a bound git conversation: `agentcore/<shortId>`,
    /// same as `WorktreeService`. No second worktree scheme.
    public static func worktreeBranch(for conversationID: UUID) -> String {
        worktreeBranchPrefix + WorktreeService.conversationShortId(from: conversationID)
    }

    /// Stub: throws. Does not HTTP, does not catalog, does not start AgentLoop.
    public func send(_ message: String, as handle: CloudBot.Handle) async throws {
        _ = message
        _ = handle
        guard isEnabled else { throw CloudBotHostError.disabled }
        throw CloudBotHostError.stubNotImplemented
    }
}

extension AppSettings {
    /// CloudBots host reflecting this settings snapshot. UI stays in App.
    public var cloudBotHost: CloudBotHost {
        CloudBotHost(settings: self)
    }
}
