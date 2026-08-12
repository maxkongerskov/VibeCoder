//
//  UnifiedDiff.swift
//
//  Minimal unified-diff parser + applier. Sufficient for the patches the
//  agent generates; we don't try to be GNU patch.
//
//  Format (per file):
//    --- a/path/to/file
//    +++ b/path/to/file
//    @@ -oldStart,oldLen +newStart,newLen @@
//     context line
//    -removed line
//    +added line
//     context line
//

import Foundation

public enum UnifiedDiff {

    public struct FilePatch: Sendable {
        public let path: String
        public let hunks: [Hunk]
    }

    public struct Hunk: Sendable {
        public let oldStart: Int
        public let oldLen: Int
        public let newStart: Int
        public let newLen: Int
        public let lines: [Line]
    }

    public enum Line: Sendable {
        case context(String)
        case removed(String)
        case added(String)
    }

    public enum ApplyError: Error, CustomStringConvertible {
        case contextMismatch(hunkOldStart: Int, expected: String, got: String)
        case beyondFileEnd(hunkOldStart: Int)
        public var description: String {
            switch self {
            case let .contextMismatch(line, expected, got):
                return "context mismatch at original line \(line): expected '\(expected.prefix(80))', got '\(got.prefix(80))'"
            case .beyondFileEnd(let line):
                return "hunk references line \(line), past end of file"
            }
        }
    }

    public enum ApplyResult: Sendable {
        case success(String)
        case failure(String)
    }

    // MARK: - Parsing

    public static func parse(_ text: String) -> [FilePatch] {
        var patches: [FilePatch] = []
        var currentPath: String?
        var currentHunks: [Hunk] = []
        var hunkHeader: (Int, Int, Int, Int)?
        var hunkLines: [Line] = []

        func flushHunk() {
            if let h = hunkHeader {
                currentHunks.append(Hunk(oldStart: h.0, oldLen: h.1, newStart: h.2, newLen: h.3, lines: hunkLines))
            }
            hunkHeader = nil
            hunkLines = []
        }
        func flushFile() {
            flushHunk()
            if let path = currentPath, !currentHunks.isEmpty {
                patches.append(FilePatch(path: path, hunks: currentHunks))
            }
            currentPath = nil
            currentHunks = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("--- ") {
                flushFile()
                continue
            }
            if s.hasPrefix("+++ ") {
                let rest = String(s.dropFirst(4))
                let cleaned = rest.hasPrefix("b/") ? String(rest.dropFirst(2)) : rest
                currentPath = cleaned.trimmingCharacters(in: .whitespaces)
                continue
            }
            if s.hasPrefix("@@") {
                flushHunk()
                if let parsed = parseHunkHeader(s) {
                    hunkHeader = parsed
                }
                continue
            }
            if hunkHeader == nil { continue }
            if s.hasPrefix("+") { hunkLines.append(.added(String(s.dropFirst()))) }
            else if s.hasPrefix("-") { hunkLines.append(.removed(String(s.dropFirst()))) }
            else if s.hasPrefix(" ") { hunkLines.append(.context(String(s.dropFirst()))) }
            else if s.isEmpty { hunkLines.append(.context("")) }
            // ignore other diagnostics lines
        }
        flushFile()
        return patches
    }

    private static func parseHunkHeader(_ s: String) -> (Int, Int, Int, Int)? {
        // @@ -oldStart,oldLen +newStart,newLen @@
        let scanner = Scanner(string: s)
        scanner.charactersToBeSkipped = nil
        guard scanner.scanString("@@ -") != nil else { return nil }
        guard let oldStart = scanner.scanInt() else { return nil }
        let oldLen: Int
        if scanner.scanString(",") != nil, let l = scanner.scanInt() { oldLen = l } else { oldLen = 1 }
        guard scanner.scanString(" +") != nil else { return nil }
        guard let newStart = scanner.scanInt() else { return nil }
        let newLen: Int
        if scanner.scanString(",") != nil, let l = scanner.scanInt() { newLen = l } else { newLen = 1 }
        return (oldStart, oldLen, newStart, newLen)
    }

    // MARK: - Applying

    public static func apply(filePatch: FilePatch, to original: String) -> ApplyResult {
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Apply hunks in reverse so prior hunks' index offsets don't
        // shift later hunks.
        for hunk in filePatch.hunks.reversed() {
            // Build the expected slice (context + removed) and the
            // replacement (context + added).
            var expected: [String] = []
            var replacement: [String] = []
            for line in hunk.lines {
                switch line {
                case .context(let s): expected.append(s); replacement.append(s)
                case .removed(let s): expected.append(s)
                case .added(let s): replacement.append(s)
                }
            }
            // 1-indexed → 0-indexed; hunk applies if expected slice
            // matches at oldStart-1.
            let start = hunk.oldStart - 1
            // Pure insertion edge case: oldStart=0, oldLen=0 means no
            // search content (all additions). Insert replacement lines at
            // position 0 (or end if newStart > 1, but convention is pos 0).
            if expected.isEmpty {
                // Insert all replacement lines before index `start` (0-based).
                // If oldStart == 1, start = 0 → insert at beginning.
                // Clamp to [0, lines.count].
                let insertPos = max(0, min(start, lines.count))
                lines.insert(contentsOf: replacement, at: insertPos)
                continue
            }
            let end = start + expected.count
            guard start >= 0 && end <= lines.count else {
                return .failure("hunk @ line \(hunk.oldStart) extends past end of \(lines.count)-line file")
            }
            let actual = Array(lines[start..<end])
            if actual != expected {
                // Soft match at this hunk position only: trailing whitespace
                // (and CR) ignored. Never relocates the hunk — fail-closed
                // if non-space content differs.
                let softOK = actual.count == expected.count
                    && zip(actual, expected).allSatisfy { a, e in
                        Self.rstripTrailingWS(a) == Self.rstripTrailingWS(e)
                    }
                if !softOK {
                    var firstBad = 0
                    for (i, (a, e)) in zip(actual, expected).enumerated() where a != e {
                        firstBad = i; break
                    }
                    let aLine = actual[firstBad]
                    let eLine = expected[firstBad]
                    return .failure("context mismatch at line \(start + firstBad + 1): expected '\(eLine)', got '\(aLine)'")
                }
            }
            lines.replaceSubrange(start..<end, with: replacement)
        }
        return .success(lines.joined(separator: "\n"))
    }

    /// Strip CR and trailing space/tab for soft hunk matching.
    private static func rstripTrailingWS(_ line: String) -> String {
        var s = line.replacingOccurrences(of: "\r", with: "")
        while s.last == " " || s.last == "\t" {
            s.removeLast()
        }
        return s
    }
}
