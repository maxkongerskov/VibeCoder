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

        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var minusPath: String?
        var i = 0
        while i < rawLines.count {
            let s = rawLines[i]
            // File headers are `--- ` / `+++ ` (dash/plus ×3 + space). Inside a
            // hunk, `-- comment` / `++i;` and even `--- keep` / `+++ i;` are
            // body lines — only a ---/+++ *pair* starts a new file there.
            let isHeaderPair = s.hasPrefix("--- ")
                && i + 1 < rawLines.count
                && rawLines[i + 1].hasPrefix("+++ ")
            if isHeaderPair || (hunkHeader == nil && s.hasPrefix("--- ")) {
                flushFile()
                minusPath = cleanDiffPath(String(s.dropFirst(4)))
                i += 1
                continue
            }
            if s.hasPrefix("+++ "), hunkHeader == nil {
                let plusPath = cleanDiffPath(String(s.dropFirst(4)))
                currentPath = resolvedPatchPath(minus: minusPath, plus: plusPath)
                minusPath = nil
                i += 1
                continue
            }
            if s.hasPrefix("@@") {
                flushHunk()
                if let parsed = parseHunkHeader(s) {
                    hunkHeader = parsed
                }
                i += 1
                continue
            }
            if hunkHeader == nil {
                i += 1
                continue
            }
            if s.hasPrefix("+") { hunkLines.append(.added(String(s.dropFirst()))) }
            else if s.hasPrefix("-") { hunkLines.append(.removed(String(s.dropFirst()))) }
            else if s.hasPrefix(" ") { hunkLines.append(.context(String(s.dropFirst()))) }
            else if s.isEmpty { hunkLines.append(.context("")) }
            // ignore other diagnostics lines
            i += 1
        }
        flushFile()
        return patches
    }

    /// Strip `a/`/`b/` prefixes and a `diff -u` tab+timestamp suffix.
    private static func cleanDiffPath(_ raw: String) -> String {
        var s = raw
        if let tab = s.firstIndex(of: "\t") {
            s = String(s[..<tab])
        }
        s = s.trimmingCharacters(in: .whitespaces)
        if s == "/dev/null" { return s }
        if s.hasPrefix("a/") || s.hasPrefix("b/") {
            s = String(s.dropFirst(2))
        }
        return s
    }

    /// Deletion (`+++ /dev/null`) keeps the `---` source path; otherwise
    /// the `+++` destination (new file, rename, edit).
    private static func resolvedPatchPath(minus: String?, plus: String) -> String {
        if plus == "/dev/null", let minus, minus != "/dev/null", !minus.isEmpty {
            return minus
        }
        return plus
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

    // MARK: - Review preview (ZCode Review card)

    /// Default cap for Review-card unified-diff text. Huge patches get a
    /// truncation footer instead of dumping thousands of lines into chat.
    public static let reviewPreviewMaxLines = 400

    /// Rebuild unified `--- a/ +++ b/ @@` text from already-parsed hunks.
    /// Per-hunk accept/reject is not a ZCode behavior — this is display only.
    public static func reviewPreview(
        path: String,
        hunks: [Hunk],
        maxLines: Int = reviewPreviewMaxLines
    ) -> String {
        var lines: [String] = [
            "--- a/\(path)",
            "+++ b/\(path)",
        ]
        for hunk in hunks {
            lines.append(hunkHeader(hunk))
            for line in hunk.lines {
                switch line {
                case .context(let s): lines.append(" \(s)")
                case .removed(let s): lines.append("-\(s)")
                case .added(let s): lines.append("+\(s)")
                }
            }
        }
        return truncatePreview(lines, maxLines: maxLines)
    }

    /// Same preview for a parsed file patch.
    public static func reviewPreview(
        filePatch: FilePatch,
        maxLines: Int = reviewPreviewMaxLines
    ) -> String {
        reviewPreview(path: filePatch.path, hunks: filePatch.hunks, maxLines: maxLines)
    }

    private static func hunkHeader(_ hunk: Hunk) -> String {
        "@@ -\(hunk.oldStart),\(hunk.oldLen) +\(hunk.newStart),\(hunk.newLen) @@"
    }

    private static func truncatePreview(_ lines: [String], maxLines: Int) -> String {
        let cap = max(0, maxLines)
        if lines.count <= cap {
            return lines.joined(separator: "\n")
        }
        let omitted = lines.count - cap
        var kept = Array(lines.prefix(cap))
        kept.append("Diff preview truncated: \(omitted) lines omitted…")
        return kept.joined(separator: "\n")
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
                // Context-free insert: oldStart 0 means beginning of file.
                // oldStart past EOF must fail closed — never clamp-and-append.
                let insertPos = hunk.oldStart <= 0 ? 0 : start
                guard insertPos >= 0, insertPos <= lines.count else {
                    return .failure("hunk @ line \(hunk.oldStart) extends past end of \(lines.count)-line file")
                }
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
