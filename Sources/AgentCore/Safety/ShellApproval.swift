//
//  ShellApproval.swift
//
//  Wave B S4 — CANONICAL types for interactive Once/Always/Never on
//  ToolAuthorization `.ask` (shell, MCP, executes).
//
//  W03: ToolRegistry  ·  W04: AgentLoop MCP  ·  W09: App sheet
//  ALL types live in THIS file only (avoid parallel-worker redefinition races).
//

import Foundation

// MARK: - Kind

public enum ShellApprovalKind: String, Sendable, Equatable {
    case shell
    case mcp
    case executes
}

// MARK: - Request / Decision

public struct ShellApprovalRequest: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let toolName: String
    public let reason: String
    public let command: String?
    public let detail: String
    /// Used when the App coordinator evaluates PermissionRequest itself.
    public let projectRoot: URL?
    public let worktreeRoot: URL?
    /// True when `ShellApproval.resolveAsk` already ran PermissionRequest.
    public let permissionRequestAlreadyEvaluated: Bool

    public init(
        id: UUID = UUID(),
        toolName: String,
        reason: String,
        command: String? = nil,
        detail: String? = nil,
        projectRoot: URL? = nil,
        worktreeRoot: URL? = nil,
        permissionRequestAlreadyEvaluated: Bool = false
    ) {
        self.id = id
        self.toolName = toolName
        self.reason = reason
        self.command = command
        self.projectRoot = projectRoot
        self.worktreeRoot = worktreeRoot
        self.permissionRequestAlreadyEvaluated = permissionRequestAlreadyEvaluated
        if let detail, !detail.isEmpty {
            self.detail = detail
        } else if let command, !command.isEmpty {
            self.detail = command
        } else {
            self.detail = toolName
        }
    }
}

public enum ShellApprovalDecision: String, Sendable, Equatable {
    case once
    case always
    case never
    case deny

    public static var allowOnce: ShellApprovalDecision { .once }
    public static var allowAlways: ShellApprovalDecision { .always }
    public static var denyAlways: ShellApprovalDecision { .never }
}

// MARK: - Host handle (Sendable)

public struct ShellApprovalReviewer: Sendable {
    public let review: @Sendable (ShellApprovalRequest) async -> ShellApprovalDecision

    public init(review: @escaping @Sendable (ShellApprovalRequest) async -> ShellApprovalDecision) {
        self.review = review
    }
}

/// Host-facing name used by ToolContext / AgentLoop / App.
public typealias ShellApprovalCoordinator = ShellApprovalReviewer

// MARK: - Resolve

public enum ShellApproval {

    public static func grantKey(
        toolName: String,
        arguments: ToolArguments,
        context: ToolContext
    ) -> GrantKey {
        let projectKey = RememberedGrants.projectKey(from: context)
        if toolName == "run_shell" || toolName == "run_shell_command",
           let command = arguments.stringOptional("command") {
            return GrantKey(
                projectKey: projectKey,
                toolName: "run_shell",
                commandFingerprint: RememberedGrants.fingerprint(command: command)
            )
        }
        return GrantKey(projectKey: projectKey, toolName: toolName, commandFingerprint: nil)
    }

    public static func makeRequest(
        toolName: String,
        arguments: ToolArguments,
        reason: String,
        projectRoot: URL? = nil,
        worktreeRoot: URL? = nil,
        permissionRequestAlreadyEvaluated: Bool = false
    ) -> ShellApprovalRequest {
        let command = arguments.stringOptional("command")
        var detail = command ?? toolName
        if command == nil {
            let raw = arguments.raw
            let keys = raw.keys.sorted().prefix(4)
            let parts = keys.compactMap { k -> String? in
                guard let v = raw[k] else { return nil }
                return "\(k)=\(String(describing: v).prefix(40))"
            }
            if !parts.isEmpty {
                detail = parts.joined(separator: " · ")
            }
        }
        return ShellApprovalRequest(
            toolName: toolName,
            reason: reason,
            command: command,
            detail: detail,
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            permissionRequestAlreadyEvaluated: permissionRequestAlreadyEvaluated
        )
    }

    public static func resolveAsk(
        toolName: String,
        arguments: ToolArguments,
        reason: String,
        context: ToolContext
    ) async throws {
        let payload = arguments.stringOptional("command")
            ?? arguments.stringOptional("description")
            ?? reason
        if let deny = HookDispatcher.permissionRequestDenial(
            toolName: toolName,
            payload: payload,
            projectRoot: context.projectRoot,
            worktreeRoot: context.worktreeRoot
        ) {
            throw ToolError.permissionDenied(deny)
        }
        guard let coordinator = context.shellApprovalCoordinator else {
            throw ToolError.permissionDenied(reason)
        }
        let request = makeRequest(
            toolName: toolName,
            arguments: arguments,
            reason: reason,
            projectRoot: context.projectRoot,
            worktreeRoot: context.worktreeRoot,
            permissionRequestAlreadyEvaluated: true
        )
        let decision = await coordinator.review(request)
        let key = grantKey(toolName: toolName, arguments: arguments, context: context)
        let command = arguments.stringOptional("command")
        let isDangerousShell = (toolName == "run_shell" || toolName == "run_shell_command")
            && command.map { SafeBash.isDangerous($0) } == true

        switch decision {
        case .once:
            return
        case .always:
            if isDangerousShell { return }
            if !context.authorization.useInlineRememberedOnly {
                await RememberedGrants.shared.remember(.allow, for: key)
            }
            return
        case .deny:
            throw ToolError.permissionDenied(
                "User denied '\(toolName)': \(reason)")
        case .never:
            if !isDangerousShell, !context.authorization.useInlineRememberedOnly {
                await RememberedGrants.shared.remember(.never, for: key)
            }
            throw ToolError.permissionDenied(
                "User chose Never allow for '\(toolName)'")
        }
    }
}

// MARK: - Gate (bool form for Registry / MCP)

public enum ShellApprovalGate {

    public static func kind(for toolName: String) -> ShellApprovalKind {
        if ToolAuthorization.isMCPToolName(toolName) { return .mcp }
        if toolName == "run_shell" || toolName == "run_shell_command" { return .shell }
        return .executes
    }

    public static func resolve(
        toolName: String,
        reason: String,
        kind: ShellApprovalKind = .executes,
        command: String? = nil,
        argumentsSummary: String? = nil,
        context: ToolContext
    ) async -> (allowed: Bool, denialMessage: String) {
        _ = kind
        var dict: [String: Any] = [:]
        if let command { dict["command"] = command }
        if let argumentsSummary { dict["description"] = argumentsSummary }
        let arguments = ToolArguments(dictionary: dict)
        do {
            try await ShellApproval.resolveAsk(
                toolName: toolName,
                arguments: arguments,
                reason: reason,
                context: context)
            return (true, "")
        } catch {
            if let te = error as? ToolError, case .permissionDenied(let r) = te {
                return (false, r.hasPrefix("Permission denied") ? r : "Permission denied: \(r)")
            }
            return (false, "Permission denied: \(error.localizedDescription)")
        }
    }
}
