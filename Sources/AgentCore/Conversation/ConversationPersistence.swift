//
//  ConversationPersistence.swift
//
//  Save a conversation snapshot and report idle status-line copy on disk
//  failure (Ada P2 — no silent `try?`). ChatViewModel delegates here so
//  persist + save-failure chip copy do not live inline in the frozen VM.
//

import Foundation

/// Persist + save-failure status for a conversation snapshot.
/// Disk I/O stays on `ConversationStore`; this type owns the Ada P2
/// contract: log the error, and when the turn is idle return the chip copy.
public enum ConversationPersistence: Sendable {

    /// Status chip copy when a snapshot save fails while idle.
    public static let saveFailureStatusLine = "Couldn't save conversation."

    public struct Outcome: Sendable, Equatable {
        public var didSave: Bool
        /// `"Couldn't save conversation."` when save failed and the turn is idle.
        public var statusLine: String?

        public init(didSave: Bool, statusLine: String?) {
            self.didSave = didSave
            self.statusLine = statusLine
        }
    }

    /// Persist `snapshot`. Logs on disk failure (Ada P2 — no silent `try?`).
    /// Returns status-line copy when the turn is idle so the existing chip can show it.
    public static func persistSnapshot(
        _ snapshot: Conversation,
        store: any ConversationStoring,
        suppressed: Bool = false,
        isRunning: Bool = false,
        logLabel: String = "ConversationPersistence.save"
    ) async -> Outcome {
        guard !suppressed else {
            return Outcome(didSave: false, statusLine: nil)
        }
        do {
            try await store.save(snapshot)
            return Outcome(didSave: true, statusLine: nil)
        } catch {
            Diagnostics.error("\(logLabel)(\(snapshot.id)): \(error.localizedDescription)")
            return Outcome(
                didSave: false,
                statusLine: isRunning ? nil : saveFailureStatusLine)
        }
    }
}
