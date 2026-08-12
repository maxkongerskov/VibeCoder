//
//  ArtifactCard.swift
//
//  Projection of a single tool invocation for the right-side artifact rail.
//  Not persisted separately — rebuilt from tool UI state on load.

import Foundation

struct ArtifactCard: Identifiable, Equatable {
    enum Kind: Equatable {
        case filePreview(path: String)
        case diff(path: String)
        case terminal(command: String)
        case searchResults(query: String)
        case webResult(title: String)
        case toolOutput

        /// True when this card represents a file diff (for panel filtering).
        var isDiff: Bool {
            if case .diff = self { return true }
            return false
        }
    }

    var id: String
    var toolName: String
    var kind: Kind
    var title: String
    var subtitle: String?
    var body: String
    var input: String
    var status: ToolCallStatus
    var createdAt: Date
}