//
//  ShellApprovalCoordinatorService.swift
//
//  Bridges AgentCore's Sendable `ShellApprovalCoordinator` to MainActor UI.
//  Queues concurrent asks so a second `run_shell` does not hard-deny while
//  a sheet is open. Sheet dismiss / cancel fails closed with `.deny`.
//

import Foundation
import SwiftUI
import AgentCore

@MainActor
final class ShellApprovalPending: Identifiable, ObservableObject {
    let id: UUID
    let request: ShellApprovalRequest

    init(request: ShellApprovalRequest) {
        self.id = request.id
        self.request = request
    }
}

@MainActor
final class ShellApprovalCoordinatorService: ObservableObject {

    /// Non-nil while a tool turn is suspended waiting on Once/Always/Never.
    @Published var pending: ShellApprovalPending?

    private var pendingContinuation: CheckedContinuation<ShellApprovalDecision, Never>?
    /// FIFO queue when a sheet is already open.
    private var queue: [(ShellApprovalRequest, CheckedContinuation<ShellApprovalDecision, Never>)] = []
    /// Generation of the currently presented sheet; dismiss only denies that gen.
    private var sheetGeneration: UInt64 = 0
    private var resolvedGeneration: UInt64 = 0

    /// Called by AgentCore (off-main via Sendable wrapper).
    func review(_ request: ShellApprovalRequest) async -> ShellApprovalDecision {
        if pending != nil {
            return await withCheckedContinuation { (cont: CheckedContinuation<ShellApprovalDecision, Never>) in
                self.queue.append((request, cont))
            }
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<ShellApprovalDecision, Never>) in
            self.pendingContinuation = cont
            self.sheetGeneration += 1
            self.pending = ShellApprovalPending(request: request)
        }
    }

    /// Called by the sheet when the user picks Once / Always / Never / Deny.
    func resolve(_ decision: ShellApprovalDecision) {
        guard let cont = pendingContinuation else { return }
        resolvedGeneration = sheetGeneration
        pendingContinuation = nil
        pending = nil
        cont.resume(returning: decision)
        // Defer next sheet so SwiftUI finishes dismiss of the previous item.
        if !queue.isEmpty {
            let next = queue.removeFirst()
            Task { @MainActor in
                self.pendingContinuation = next.1
                self.sheetGeneration += 1
                self.pending = ShellApprovalPending(request: next.0)
            }
        }
    }

    /// Fail-closed on Esc/close only when that sheet was not already resolved.
    func handleSheetDismiss() {
        // Button path already set resolvedGeneration == sheetGeneration.
        if resolvedGeneration == sheetGeneration { return }
        // If a new item was already presented via resolve() (generation incremented),
        // this dismiss is just the old sheet closing — do not deny the new item.
        if resolvedGeneration < sheetGeneration { return }
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
}
