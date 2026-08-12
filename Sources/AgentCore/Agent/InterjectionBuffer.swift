//
//  InterjectionBuffer.swift
//  Mid-turn user interjections (Grok xai-interjection-core behavioral port).
//
//  App path: when a turn is already running, `ChatViewModel.send` enqueues
//  here instead of starting a second loop. `AgentLoop` drains at:
//    • start of each iteration
//    • mid tool-dispatch (long batches)
//    • natural finish (no tool calls) — PC6: continue turn if any steers
//  Injected as user messages + system-reminder nudges for the next model call.
//
//  Hard-stop fail-closed (P4 / cancel / finish):
//    On cancel or natural end, AgentLoop calls `clear(conversationId:)`.
//    That **discards** undelivered steers (never injects after hard-stop) and
//    **bumps the generation epoch** so a late `enqueue(..., expectedEpoch:)`
//    from a cancelled turn is rejected. Fail-open would leak steers into the
//    next user turn as phantom user messages — we deliberately fail closed.
//
//  Generation epochs (Wave C2): cancel/finish bumps the epoch so a late
//  `enqueue` Task started before cancel cannot land after clear.
//

import Foundation

public actor InterjectionBuffer {
    public static let shared = InterjectionBuffer()

    private var pending: [UUID: [String]] = [:]
    /// Per-conversation generation; bumped on clear. Enqueue must pass the
    /// epoch observed while the turn was still live.
    private var epoch: [UUID: UInt64] = [:]

    /// Current generation for a conversation (0 if never touched).
    public func currentEpoch(conversationId: UUID) -> UInt64 {
        epoch[conversationId] ?? 0
    }

    /// Enqueue only if `expectedEpoch` still matches (or is omitted for
    /// legacy callers — then always accepts).
    @discardableResult
    public func enqueue(
        conversationId: UUID,
        text: String,
        expectedEpoch: UInt64? = nil
    ) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if let expectedEpoch {
            let live = epoch[conversationId] ?? 0
            guard live == expectedEpoch else { return false }
        }
        pending[conversationId, default: []].append(t)
        return true
    }

    /// Sample epoch and enqueue in one actor hop (no race with clear).
    @discardableResult
    public func enqueueCurrentEpoch(conversationId: UUID, text: String) -> Bool {
        let live = epoch[conversationId] ?? 0
        return enqueue(conversationId: conversationId, text: text, expectedEpoch: live)
    }

    /// Atomically take all pending texts for a conversation (FIFO).
    public func drain(conversationId: UUID) -> [String] {
        let items = pending[conversationId] ?? []
        pending[conversationId] = nil
        return items
    }

    public func peekCount(conversationId: UUID) -> Int {
        pending[conversationId]?.count ?? 0
    }

    /// True when at least one undelivered interjection is waiting.
    public func hasPending(conversationId: UUID) -> Bool {
        !(pending[conversationId] ?? []).isEmpty
    }

    /// Drop undelivered interjections and bump generation so straggler
    /// enqueues from a cancelled turn are rejected.
    public func clear(conversationId: UUID) {
        pending[conversationId] = nil
        epoch[conversationId, default: 0] += 1
    }
}
