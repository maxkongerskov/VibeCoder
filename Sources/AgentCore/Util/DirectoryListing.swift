//
//  DirectoryListing.swift
//
//  Pure parse of list_directory tool output into File / Size / Modified rows
//  for ZCode-style activity expansion. Format (tab-separated):
//
//    VC_LIST\t<path>
//    dir\t0\tName\t<unix-epoch>
//    file\t<bytes>\tName\t<unix-epoch>
//    empty
//    more\t0\t… and N more\t0
//

import Foundation

public struct DirectoryListing: Equatable, Sendable {
    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: String { name }
        public var name: String
        public var isDirectory: Bool
        public var size: Int
        public var modified: Date?

        public init(name: String, isDirectory: Bool, size: Int, modified: Date?) {
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
            self.modified = modified
        }
    }

    public var path: String
    public var entries: [Entry]

    public init(path: String, entries: [Entry]) {
        self.path = path
        self.entries = entries
    }

    public var files: [Entry] { entries.filter { !$0.isDirectory && !$0.name.hasPrefix("…") } }
    public var directories: [Entry] { entries.filter(\.isDirectory) }

    /// Parse shipped list_directory output (VC_LIST / BC_LIST headers).
    public static func parse(_ raw: String) -> DirectoryListing? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return nil }
        let path: String
        if first.hasPrefix("VC_LIST\t") {
            path = String(first.dropFirst("VC_LIST\t".count))
        } else if first.hasPrefix("BC_LIST\t") {
            path = String(first.dropFirst("BC_LIST\t".count))
        } else {
            // Legacy: "d  name" / "f  name" lines — still produce a table.
            return parseLegacy(raw)
        }
        var entries: [Entry] = []
        for line in lines.dropFirst() {
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let kind = parts[0]
            if kind == "empty" { continue }
            let size = Int(parts[1]) ?? 0
            let name = parts[2]
            let mod: Date? = {
                guard parts.count >= 4, let t = TimeInterval(parts[3]), t > 0 else { return nil }
                return Date(timeIntervalSince1970: t)
            }()
            if kind == "more" {
                entries.append(Entry(name: name, isDirectory: false, size: 0, modified: nil))
                continue
            }
            entries.append(Entry(
                name: name,
                isDirectory: kind == "dir" || kind == "d",
                size: size,
                modified: mod
            ))
        }
        return DirectoryListing(path: path, entries: entries)
    }

    /// Legacy tool output: `d  name` / `f  name` per line (no size/date).
    private static func parseLegacy(_ raw: String) -> DirectoryListing? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "(empty)" else {
            return DirectoryListing(path: ".", entries: [])
        }
        var entries: [Entry] = []
        for line in trimmed.split(separator: "\n").map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("d  ") || t.hasPrefix("d\t") {
                let name = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                entries.append(Entry(name: name, isDirectory: true, size: 0, modified: nil))
            } else if t.hasPrefix("f  ") || t.hasPrefix("f\t") {
                let name = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                entries.append(Entry(name: name, isDirectory: false, size: 0, modified: nil))
            } else {
                // Unrecognized line — treat whole line as a file name so we still render something.
                entries.append(Entry(name: t, isDirectory: false, size: 0, modified: nil))
            }
        }
        guard !entries.isEmpty else { return nil }
        return DirectoryListing(path: ".", entries: entries)
    }

    public static func formatByteSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024.0)
    }
}
