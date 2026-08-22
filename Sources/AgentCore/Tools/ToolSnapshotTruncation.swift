//
//  ToolSnapshotTruncation.swift
//
//  ZCode-parity (docs/ui-parity-research/zcode-chat.md §3): oversized
//  tool args/result become a card preview plus omitted counts
//  (`chat.toolCall.snapshot.*` — "{fields} tool field(s) were truncated.
//  Showing preview X / Y. Load full tool data"). Pure functions so App
//  can paint later. Does not touch AgentLoop.swift.
//

import Foundation

/// Truncate tool-call snapshot fields (arguments / result) for chat cards.
public enum ToolSnapshotTruncation: Sendable {

    /// Per-field character cap for the card preview (not the persisted wire).
    public static let defaultLimit = 2_000

    /// One args or result body after applying `limit`.
    public struct Field: Sendable, Equatable {
        public let name: String
        public let preview: String
        /// Characters kept in `preview` (X contribution).
        public let shownCount: Int
        /// Original character count (Y contribution when truncated).
        public let fullCount: Int
        /// Characters dropped from the original body.
        public let omittedCount: Int

        public var isTruncated: Bool { omittedCount > 0 }
    }

    /// Combined args + result snapshot for a tool card.
    public struct Snapshot: Sendable, Equatable {
        public let args: Field
        public let result: Field
        /// How many of args/result exceeded the preview limit.
        public let truncatedFieldCount: Int
        /// Preview character total across truncated fields (X).
        public let previewCount: Int
        /// Original character total across truncated fields (Y).
        public let fullCount: Int
        /// Characters omitted across truncated fields.
        public let omittedCount: Int

        public var isTruncated: Bool { truncatedFieldCount > 0 }

        /// ZCode `chat.toolCall.snapshot` notice, or nil when nothing was cut.
        public var notice: String? {
            guard isTruncated else { return nil }
            return
                "\(truncatedFieldCount) tool field(s) were truncated. Showing preview \(previewCount) / \(fullCount). Load full tool data"
        }
    }

    /// Build a truncated snapshot from optional args/result text.
    public static func snapshot(
        args: String?,
        result: String?,
        limit: Int = defaultLimit
    ) -> Snapshot {
        let cap = max(0, limit)
        let argsField = field(name: "args", text: args ?? "", limit: cap)
        let resultField = field(name: "result", text: result ?? "", limit: cap)
        let truncated = [argsField, resultField].filter(\.isTruncated)
        return Snapshot(
            args: argsField,
            result: resultField,
            truncatedFieldCount: truncated.count,
            previewCount: truncated.reduce(0) { $0 + $1.shownCount },
            fullCount: truncated.reduce(0) { $0 + $1.fullCount },
            omittedCount: truncated.reduce(0) { $0 + $1.omittedCount }
        )
    }

    public static func field(name: String, text: String, limit: Int = defaultLimit) -> Field {
        let cap = max(0, limit)
        let full = text.count
        if full <= cap {
            return Field(
                name: name,
                preview: text,
                shownCount: full,
                fullCount: full,
                omittedCount: 0
            )
        }
        let preview = String(text.prefix(cap))
        return Field(
            name: name,
            preview: preview,
            shownCount: preview.count,
            fullCount: full,
            omittedCount: full - preview.count
        )
    }
}
