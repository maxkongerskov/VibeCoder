//
//  StickyContextPin.swift
//
//  Session-scoped @-context pins that re-inject on every user turn until
//  the user removes them (S1). Distinct from one-shot `pendingAttachments`.
//

import Foundation
import AgentCore

/// A sticky context pin shown in the composer until dismissed.
struct StickyContextPin: Identifiable, Equatable, Sendable, Codable {
    enum Kind: String, Sendable, Equatable, Codable {
        case file
        case folder
        case symbol
    }

    let id: UUID
    let kind: Kind
    /// Absolute path (file or folder).
    let path: String
    let displayName: String
    /// For symbols: symbol name for the agent prefix.
    let symbolName: String?
    let byteSize: Int?

    init(id: UUID = UUID(),
         kind: Kind,
         path: String,
         displayName: String,
         symbolName: String? = nil,
         byteSize: Int? = nil) {
        self.id = id
        self.kind = kind
        self.path = path
        self.displayName = displayName
        self.symbolName = symbolName
        self.byteSize = byteSize
    }

    init(candidate: MentionCandidate) {
        let k: Kind
        switch candidate.kind {
        case .file: k = .file
        case .folder: k = .folder
        case .symbol: k = .symbol
        }
        self.init(
            kind: k,
            path: candidate.path,
            displayName: candidate.displayName,
            symbolName: candidate.symbolName,
            byteSize: candidate.byteSize
        )
    }

    init(record: StickyContextPinRecord) {
        let k = Kind(rawValue: record.kind) ?? .file
        self.init(
            id: record.id,
            kind: k,
            path: record.path,
            displayName: record.displayName,
            symbolName: record.symbolName,
            byteSize: record.byteSize
        )
    }

    var asRecord: StickyContextPinRecord {
        StickyContextPinRecord(
            id: id,
            kind: kind.rawValue,
            path: path,
            displayName: displayName,
            symbolName: symbolName,
            byteSize: byteSize
        )
    }

    var systemImage: String {
        switch kind {
        case .file: return "doc.text"
        case .folder: return "folder.fill"
        case .symbol: return "function"
        }
    }

    /// Dedup key (path + kind + symbol).
    var dedupeKey: String {
        "\(kind.rawValue)|\(path)|\(symbolName ?? "")"
    }
}

// MARK: - Compose helpers (pure — unit-tested)

enum StickyContextCompose {
    /// Merge sticky pins + one-shot attachments into formatter attachments
    /// (files/symbols only — folders expanded as text separately).
    static func fileAttachments(
        pins: [StickyContextPin],
        pending: [ContextAttachment]
    ) -> [ContextAttachment] {
        var out: [ContextAttachment] = []
        var seenPaths = Set<String>()
        for pin in pins where pin.kind == .file || pin.kind == .symbol {
            let p = pin.path
            guard !seenPaths.contains(p) else { continue }
            seenPaths.insert(p)
            out.append(ContextAttachment(
                path: p,
                displayName: pin.displayName,
                byteSize: pin.byteSize
            ))
        }
        for a in pending {
            guard !seenPaths.contains(a.path) else { continue }
            seenPaths.insert(a.path)
            out.append(a)
        }
        return out
    }

    /// Text prefix for folder pins + symbol labels (before file bodies).
    static func pinHeaderText(
        pins: [StickyContextPin],
        fileManager: FileManager = .default
    ) -> String {
        guard !pins.isEmpty else { return "" }
        var lines: [String] = ["[Sticky context pins — re-injected each turn]"]
        for pin in pins {
            switch pin.kind {
            case .file:
                lines.append("- @file \(pin.displayName) (\(pin.path))")
            case .folder:
                lines.append("- @folder \(pin.displayName) (\(pin.path))")
                lines.append(contentsOf: folderListing(path: pin.path, fileManager: fileManager))
            case .symbol:
                let sym = pin.symbolName ?? pin.displayName
                lines.append("- @symbol \(sym) in \(pin.path)")
            }
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    static func folderListing(path: String, fileManager: FileManager, maxEntries: Int = 40) -> [String] {
        let expanded = (path as NSString).expandingTildeInPath
        guard let items = try? fileManager.contentsOfDirectory(atPath: expanded) else {
            return ["  (folder missing or unreadable)"]
        }
        let sorted = items.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var out: [String] = ["  contents:"]
        for name in sorted.prefix(maxEntries) {
            out.append("  - \(name)")
        }
        if sorted.count > maxEntries {
            out.append("  … (\(sorted.count - maxEntries) more)")
        }
        return out
    }
}
