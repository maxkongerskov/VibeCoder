//
//  FindInTaskFileChangeSearch.swift
//
//  Find in task — file-changes scope. Searches TurnChangeSummary paths
//  and +/− labels. Hits scroll to the turn-end card file row.
//

import Foundation
import AgentCore

enum FindInTaskScope: String, CaseIterable, Sendable, Equatable {
    case messages
    case fileChanges

    var title: String {
        switch self {
        case .messages: return "Messages"
        case .fileChanges: return "Files"
        }
    }
}

enum FindInTaskFileChangeSearch {
    static let idPrefix = "chg:"

    static func hitID(path: String) -> String {
        idPrefix + TurnChangeSummary.pathKey(path)
    }

    static func isFileChangeHitID(_ id: String) -> Bool {
        id.hasPrefix(idPrefix)
    }

    /// One hit per matching file across all turns. Empty / whitespace → [].
    static func hits(query: String, messages: [ChatMessage]) -> [FindInTaskHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var out: [FindInTaskHit] = []
        var seen = Set<String>()
        for summary in TurnChangeSummary.summarizeEachTurn(in: messages) {
            for file in summary.files {
                let id = hitID(path: file.path)
                guard !seen.contains(id) else { continue }
                let haystack = haystack(for: file)
                guard let range = haystack.range(of: needle, options: [.caseInsensitive]) else {
                    continue
                }
                seen.insert(id)
                let utf16 = haystack.utf16
                let lower = range.lowerBound.samePosition(in: utf16) ?? utf16.startIndex
                let upper = range.upperBound.samePosition(in: utf16) ?? utf16.endIndex
                out.append(FindInTaskHit(
                    id: id,
                    messageID: summary.userMessageID,
                    matchOffset: utf16.distance(from: utf16.startIndex, to: lower),
                    matchLength: utf16.distance(from: lower, to: upper),
                    snippet: snippet(from: haystack, match: range)
                ))
            }
        }
        return out
    }

    static func haystack(for file: TurnChangeSummary.FileChange) -> String {
        "\(file.path) \(file.status.rawValue) +\(file.added) −\(file.removed)"
    }

    static func pathKey(fromHitID id: String) -> String? {
        guard isFileChangeHitID(id) else { return nil }
        return String(id.dropFirst(idPrefix.count))
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
        let prefix = start > content.startIndex ? "…" : ""
        let suffix = end < content.endIndex ? "…" : ""
        return prefix + piece + suffix
    }
}
