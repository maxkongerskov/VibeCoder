//
//  PatchReviewCoordinator.swift
//
//  Bridges AgentCore's `PatchReviewer` (Sendable, off-main) to the
//  SwiftUI sheet (`PatchReviewSheetV2`) which renders on MainActor.
//
//  Flow:
//    1. AgentLoop is configured with a `PatchReviewer` value whose
//       closure calls `await coordinator.review(previews)`.
//    2. `review` stores the previews + a `CheckedContinuation` on the
//       coordinator's @Published `pendingBatch` and suspends.
//    3. ChatView observes `pendingBatch`, presents
//       `PatchReviewSheetV2` populated from the previews.
//    4. The sheet's onApply/onCancel callback hits
//       `coordinator.resolve(decision:)`, which resumes the
//       continuation and clears `pendingBatch`.
//
//  Concurrency:
//    * The coordinator is `@MainActor` because SwiftUI sheets bind to
//      it. The reviewer struct it produces wraps a `@Sendable`
//      closure that hops to main when invoking the coordinator's
//      async method, which keeps the contract Sendable-clean.
//

import Foundation
import SwiftUI
import AgentCore

/// One pending review batch — what the sheet renders, plus the
/// continuation the coordinator resumes when the user decides.
///
/// The continuation is captured inside the coordinator (not exposed
/// to the sheet) because it can only be resumed once; the sheet
/// instead calls `coordinator.resolve(decision:)`.
@MainActor
final class PatchReviewBatch: Identifiable, ObservableObject {
    let id = UUID()
    let previews: [PatchPreview]

    init(previews: [PatchPreview]) {
        self.previews = previews
    }
}

@MainActor
final class PatchReviewCoordinator: ObservableObject {

    /// Non-nil when a tool turn is suspended waiting on user input.
    /// ChatView observes this to present the sheet.
    @Published var pendingBatch: PatchReviewBatch?

    /// The continuation paired with `pendingBatch`. Captured here so
    /// the sheet's resolve callback doesn't need to thread it through
    /// SwiftUI state.
    private var pendingContinuation: CheckedContinuation<PatchDecision, Never>?

    // MARK: - Reviewer entry point

    /// Called by AgentCore (off-main, via the `PatchReviewer` wrapper).
    /// Publishes the batch, suspends until the sheet resolves it. If
    /// a previous review is somehow still open, we auto-reject the new
    /// one rather than queue (queuing would block the agent loop on
    /// stale UI state).
    func review(_ previews: [PatchPreview]) async -> PatchDecision {
        guard pendingBatch == nil else { return .rejectAll }
        return await withCheckedContinuation { (cont: CheckedContinuation<PatchDecision, Never>) in
            self.pendingContinuation = cont
            self.pendingBatch = PatchReviewBatch(previews: previews)
        }
    }

    /// Called by the sheet when the user hits Apply / Reject / Cancel.
    /// Resumes the suspended tool and clears state. Calling resolve
    /// twice is a no-op — guard against accidental double-fire from
    /// the sheet's dismiss animation.
    func resolve(_ decision: PatchDecision) {
        guard let cont = pendingContinuation else { return }
        self.pendingContinuation = nil
        self.pendingBatch = nil
        cont.resume(returning: decision)
    }

    /// Fail-closed on sheet dismiss / cancel without an explicit decision.
    func rejectIfStillPending() {
        guard pendingContinuation != nil else { return }
        resolve(.rejectAll)
    }

    // MARK: - Sendable bridge

    /// Build a Sendable `PatchReviewer` that AgentCore can hold in a
    /// `ToolContext`. Captures the coordinator weakly so an outlived
    /// configuration doesn't keep a stale view-model around; if the
    /// coordinator's gone we auto-reject (failing closed).
    nonisolated func makeReviewer() -> PatchReviewer {
        PatchReviewer { [weak self] previews in
            guard let self else { return .rejectAll }
            return await self.review(previews)
        }
    }
}
