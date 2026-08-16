//
//  FindInTaskSearch.swift
//  Wave U2 — Find in task (⌘F). Pure message search; v1 is one hit per message.
//

import Foundation
import AgentCore

/// One transcript match. `id` is the ScrollViewReader / highlight key:
/// `message.id.uuidString` for persisted rows, ``pending`` for the live stream.
struct FindInTaskHit: Equatable, Identifiable, Sendable {
    let id: String
    let messageID: UUID?
    /// UTF-16 offset of the first case-insensitive match in the searched text.
    let matchOffset: Int
    let matchLength: Int
    let snippet: String
}

enum FindInTaskSearch {
    static let pendingHitID = "pending"

    /// Case-insensitive substring search over transcript-visible messages.
    /// Empty / whitespace query → no hits. Tool / system / wire-only user
    /// rows are skipped (`appearsInTranscript == false`).
    ///
    /// v1: **one hit per matching message** (first range only), plus an
    /// optional trailing `"pending"` hit for live `streamingContent`.
    static func hits(
        query: String,
        messages: [ChatMessage],
        streamingContent: String = ""
    ) -> [FindInTaskHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var out: [FindInTaskHit] = []
        out.reserveCapacity(messages.count + 1)

        for message in messages where message.appearsInTranscript {
            if let hit = firstHit(
                in: message.content,
                needle: needle,
                id: message.id.uuidString,
                messageID: message.id
            ) {
                out.append(hit)
            }
        }

        if let pending = firstHit(
            in: streamingContent,
            needle: needle,
            id: pendingHitID,
            messageID: nil
        ) {
            out.append(pending)
        }

        return out
    }

    /// 1-based `N of M` label. `0 of 0` when there are no hits.
    static func countLabel(currentIndex: Int, count: Int) -> String {
        guard count > 0 else { return "0 of 0" }
        let clamped = min(max(currentIndex, 0), count - 1)
        return "\(clamped + 1) of \(count)"
    }

    /// Wraps to `0` after the last hit. Stays `0` when `count == 0`.
    static func nextIndex(_ current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(max(currentIndexSafe(current, count: count), 0), count - 1)
        return (clamped + 1) % count
    }

    /// Wraps to the last hit from `0`. Stays `0` when `count == 0`.
    static func previousIndex(_ current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(max(currentIndexSafe(current, count: count), 0), count - 1)
        return (clamped - 1 + count) % count
    }

    // MARK: - Private

    private static func currentIndexSafe(_ current: Int, count: Int) -> Int {
        if current < 0 || current >= count { return 0 }
        return current
    }

    private static func firstHit(
        in content: String,
        needle: String,
        id: String,
        messageID: UUID?
    ) -> FindInTaskHit? {
        guard !content.isEmpty,
              let range = content.range(of: needle, options: [.caseInsensitive]) else {
            return nil
        }
        let (offset, length) = utf16Range(of: range, in: content)
        return FindInTaskHit(
            id: id,
            messageID: messageID,
            matchOffset: offset,
            matchLength: length,
            snippet: snippet(from: content, match: range)
        )
    }

    private static func utf16Range(
        of match: Range<String.Index>,
        in content: String
    ) -> (Int, Int) {
        let utf16 = content.utf16
        let lower = match.lowerBound.samePosition(in: utf16) ?? utf16.startIndex
        let upper = match.upperBound.samePosition(in: utf16) ?? utf16.endIndex
        return (
            utf16.distance(from: utf16.startIndex, to: lower),
            utf16.distance(from: lower, to: upper)
        )
    }

    private static func snippet(
        from content: String,
        match: Range<String.Index>,
        radius: Int = 36
    ) -> String {
        let start = content.index(match.lowerBound, offsetBy: -radius, limitedBy: content.startIndex)
            ?? content.startIndex
        let end = content.index(match.upperBound, offsetBy: radius, limitedBy: content.endIndex)
            ?? content.endIndex
        var piece = String(content[start..<end])
        piece = piece.replacingOccurrences(of: "\n", with: " ")
        piece = piece.replacingOccurrences(of: "\t", with: " ")
        let prefix = start > content.startIndex ? "…" : ""
        let suffix = end < content.endIndex ? "…" : ""
        return prefix + piece + suffix
    }
}
