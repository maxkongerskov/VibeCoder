//
//  ShellApprovalCoordinatorService.swift
//
//  Bridges AgentCore's Sendable `ShellApprovalCoordinator` to MainActor UI.
//  Queues concurrent asks so a second `run_shell` does not hard-deny while
//  a sheet is open. Sheet dismiss / cancel fails closed with `.deny`.
//
//  Session grants ("Allow for this session") live in `sessionGrants` and
//  skip the sheet. They resolve as `.once` to AgentCore so Always/Never
//  disk persistence is unchanged.
//

import Foundation
import SwiftUI
import AgentCore

/// Sheet-facing choice. `session` is recorded in `SessionGrantStore` then
/// forwarded to AgentCore as `.once` (no durable grant).
enum ShellApprovalSheetDecision: String, Sendable, Equatable {
    case once
    case session
    case always
    case never
    case deny
}

@MainActor
final class ShellApprovalPending: Identifiable, ObservableObject {
    let id: UUID
    let request: ShellApprovalRequest
    /// Subagent type when the ask plumbing stamps one (nil today).
    let originTag: String?

    init(request: ShellApprovalRequest, originTag: String? = nil) {
        self.id = request.id
        self.request = request
        self.originTag = originTag
    }
}

@MainActor
final class ShellApprovalCoordinatorService: ObservableObject {

    /// Non-nil while a tool turn is suspended waiting on Once/Always/Never.
    @Published var pending: ShellApprovalPending?

    /// In-memory session grants (app-run lifetime). Host should bind
    /// `activeConversationID` and call `clearConversation` on delete.
    let sessionGrants: SessionGrantStore

    /// Conversation used when recording / matching session grants.
    /// `nil` falls back to `SessionGrantStore.unscopedConversationID`.
    var activeConversationID: UUID?

    /// Sheet reads this when ChatView still forwards only `ShellApprovalDecision`.
    static weak var presentedService: ShellApprovalCoordinatorService?

    private var pendingContinuation: CheckedContinuation<ShellApprovalDecision, Never>?
    /// FIFO queue when a sheet is already open.
    private var queue: [(ShellApprovalRequest, CheckedContinuation<ShellApprovalDecision, Never>)] = []
    /// Generation of the currently presented sheet; dismiss only denies that gen.
    private var sheetGeneration: UInt64 = 0
    private var resolvedGeneration: UInt64 = 0

    init(sessionGrants: SessionGrantStore = SessionGrantStore()) {
        self.sessionGrants = sessionGrants
    }

    /// Called by AgentCore (off-main via Sendable wrapper).
    func review(_ request: ShellApprovalRequest) async -> ShellApprovalDecision {
        // PermissionRequest must run before session grants skip the sheet.
        if Self.permissionRequestDenied(request) {
            return .deny
        }
        if sessionAllows(request) {
            return .once
        }
        if pending != nil {
            return await withCheckedContinuation { (cont: CheckedContinuation<ShellApprovalDecision, Never>) in
                self.queue.append((request, cont))
            }
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<ShellApprovalDecision, Never>) in
            self.present(request, continuation: cont)
        }
    }

    /// Called by the sheet when the user picks Once / Always / Never / Deny.
    /// `rememberSession` records a process-lifetime grant then acts as Once.
    func resolve(_ decision: ShellApprovalDecision, rememberSession: Bool = false) {
        if rememberSession {
            rememberSessionFromPending()
        }
        guard let cont = pendingContinuation else { return }
        resolvedGeneration = sheetGeneration
        pendingContinuation = nil
        pending = nil
        cont.resume(returning: decision)
        // Defer next sheet so SwiftUI finishes dismiss of the previous item.
        if !queue.isEmpty {
            Task { @MainActor in
                self.presentNextFromQueue()
            }
        }
    }

    /// Record a session grant for the presented request and approve once.
    func resolveSession() {
        resolve(.once, rememberSession: true)
    }

    func resolveSheet(_ choice: ShellApprovalSheetDecision) {
        switch choice {
        case .once:
            resolve(.once)
        case .session:
            resolveSession()
        case .always:
            resolve(.always)
        case .never:
            resolve(.never)
        case .deny:
            resolve(.deny)
        }
    }

    /// Fail-closed on Esc/close only when that sheet was not already resolved.
    func handleSheetDismiss() {
        // Button path already set resolvedGeneration == sheetGeneration.
        if resolvedGeneration == sheetGeneration { return }
        // First Esc: resolvedGeneration < sheetGeneration. Must deny the
        // pending continuation or the turn hangs. After resolve(), pending
        // is nil until the next sheet is presented, so the guard below
        // skips leftover dismiss of the previous sheet.
        guard pendingContinuation != nil else { return }
        denyPendingAndDrain()
    }

    /// Fail-closed: dismiss / cancel without a button choice.
    func denyPendingAndDrain() {
        if let cont = pendingContinuation {
            pendingContinuation = nil
            pending = nil
            cont.resume(returning: .deny)
        }
        let remaining = queue
        queue.removeAll()
        for (_, cont) in remaining {
            cont.resume(returning: .deny)
        }
    }

    /// Sendable handle for `ToolContext` / `AgentLoop.Configuration`.
    nonisolated func makeCoordinator() -> ShellApprovalCoordinator {
        ShellApprovalCoordinator { [weak self] request in
            guard let self else { return .deny }
            return await self.review(request)
        }
    }

    // MARK: - Session

    var sessionConversationID: UUID {
        activeConversationID ?? SessionGrantStore.unscopedConversationID
    }

    func sessionAllows(_ request: ShellApprovalRequest) -> Bool {
        if Self.isDangerous(request) { return false }
        return sessionGrants.matches(
            conversationID: sessionConversationID,
            toolName: request.toolName,
            command: request.command,
            originTag: nil
        ) == true
    }

    /// Fail closed when a PermissionRequest hook denies. Skipped when
    /// `resolveAsk` already evaluated the same request.
    static func permissionRequestDenied(_ request: ShellApprovalRequest) -> Bool {
        if request.permissionRequestAlreadyEvaluated { return false }
        return HookDispatcher.permissionRequestDenial(
            toolName: request.toolName,
            payload: request.command ?? request.detail,
            projectRoot: request.projectRoot,
            worktreeRoot: request.worktreeRoot
        ) != nil
    }

    static func isDangerous(_ request: ShellApprovalRequest) -> Bool {
        (request.toolName == "run_shell" || request.toolName == "run_shell_command")
            && (request.command.map { SafeBash.isDangerous($0) } ?? false)
    }

    private func rememberSessionFromPending() {
        guard let pending else { return }
        if Self.isDangerous(pending.request) { return }
        let grant = SessionGrantStore.grant(
            conversationID: sessionConversationID,
            toolName: pending.request.toolName,
            command: pending.request.command,
            originTag: pending.originTag
        )
        sessionGrants.add(grant: grant)
    }

    private func present(
        _ request: ShellApprovalRequest,
        continuation: CheckedContinuation<ShellApprovalDecision, Never>
    ) {
        pendingContinuation = continuation
        sheetGeneration += 1
        pending = ShellApprovalPending(request: request)
        Self.presentedService = self
    }

    private func presentNextFromQueue() {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if sessionAllows(next.0) {
                next.1.resume(returning: .once)
                continue
            }
            present(next.0, continuation: next.1)
            return
        }
    }
}
