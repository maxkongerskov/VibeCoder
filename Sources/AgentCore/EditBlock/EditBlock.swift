//
//  EditBlock.swift
//
//  v1.1 Tools-Week (#308): SEARCH/REPLACE edit-block parser + applier,
//  ported from Aider's `editblock_coder.py` (Apache 2.0).
//
//  Why we ported this from a Python tool: every code edit the agent has
//  ever made in AgentOS has gone through `apply_patch`, which carries
//  Anthropic's unified-diff-inside-JSON format. That format has a
//  fatal interaction with small open-source models — they cannot escape
//  backslashes, quotes, and Swift/Python keypath syntax inside a JSON
//  string reliably. The dashboard showed apply_patch failing at 0-17%
//  across hundreds of calls. The fundamental fix isn't a fault-tolerant
//  JSON parser, it's a different wire format. Aider hit this same wall
//  five years ago and moved to plain-text SEARCH/REPLACE blocks. Their
//  EditBlockCoder has been ground against millions of real edits since.
//
//  Format (one or more blocks per request):
//
//      path/to/file.swift
//      <<<<<<< SEARCH
//      old code, MUST match byte-for-byte (or with whitespace tolerance)
//      =======
//      new code that replaces the search section
//      >>>>>>> REPLACE
//
//  Marker tolerance: 5-9 `<`, `=`, `>` characters per marker line, with
//  optional `>` after SEARCH and trailing whitespace. Models routinely
//  emit 7 or 8 characters; refusing to parse 8 was a bad customer call.
//
//  Three-tier match cascade (Aider's order, ported verbatim):
//
//    1. Perfect line-equality match — fastest path, most common case.
//    2. Whitespace-flexible match — strip uniform leading whitespace from
//       both SEARCH and REPLACE before retrying. Models often drop or
//       reduce indentation; this catches >90% of those misses.
//    3. Dotdotdots elision — `...` on its own line means "unchanged
//       region." Splits SEARCH and REPLACE on `...`, applies each
//       paired segment via literal string replacement. Allows partial
//       edits without dumping 200 lines of context.
//
//  We DELIBERATELY do not port Aider's fuzzy edit-distance fallback
//  (`replace_closest_edit_distance`). It exists in Aider's source but is
//  commented out — the `return` before it bails early. Per their issue
//  tracker the fuzzy match misfired more than it helped; we honour that
//  call.
//
//  Threading: all functions here are pure (input → output) with no
//  shared mutable state, so they're trivially `Sendable`. The tool
//  wrapper at the call site reads/writes the file.
//

import Foundation

// MARK: - Public types

/// One parsed SEARCH/REPLACE block. `filename` is whatever the parser
/// recovered from the 3 lines preceding the SEARCH marker — see
/// `EditBlockParser.findFilename` for the precedence rules.
public struct EditBlock: Sendable, Hashable {
    public let filename: String
    public let original: String   // SEARCH section text, trailing newline included if present
    public let updated: String    // REPLACE section text, trailing newline included if present

    public init(filename: String, original: String, updated: String) {
        self.filename = filename
        self.original = original
        self.updated = updated
    }
}

/// Outcome of applying one edit to file content. `.applied` carries the
/// new file contents. `.failed` carries an Aider-style diagnostic the
/// model can act on directly — "did you mean these actual lines" plus
/// the "already applied" hint when REPLACE text is already in the file.
public enum EditApplyOutcome: Sendable {
    case applied(newContent: String)
    case failed(reason: String)
}

/// Errors thrown by the parser. `.malformed` carries a human-readable
/// position so the model knows where it went wrong. Aider's parser
/// passes the processed prefix + a `^^^` caret into the error message;
/// we keep that pattern.
public enum EditBlockParseError: Error, LocalizedError, Sendable {
    case missingFilename(context: String)
    case missingDivider(context: String)
    case missingReplaceMarker(context: String)
    case unpairedDotdotdots
    case unmatchedDotdotdots

    public var errorDescription: String? {
        switch self {
        case .missingFilename(let ctx):
            return "Bad/missing filename. The filename must be alone on the line before the opening `<<<<<<< SEARCH` marker.\n\(ctx)\n^^^ no filename found in the preceding 3 lines"
        case .missingDivider(let ctx):
            return "Expected `=======` divider between SEARCH and REPLACE.\n\(ctx)\n^^^ divider missing"
        case .missingReplaceMarker(let ctx):
            return "Expected `>>>>>>> REPLACE` marker to close the block.\n\(ctx)\n^^^ end marker missing"
        case .unpairedDotdotdots:
            return "Unpaired `...` in SEARCH/REPLACE block — every `...` in SEARCH must match a `...` in REPLACE."
        case .unmatchedDotdotdots:
            return "Unmatched `...` in SEARCH/REPLACE block — the text around each `...` must be identical in SEARCH and REPLACE."
        }
    }
}

// MARK: - Parser

public enum EditBlockParser {

    // Marker patterns. Aider allows 5-9 of each character; the agent
    // sometimes emits 6, 7, 8. The trailing `?` on SEARCH and the
    // `\s*$` permit a trailing `>` or whitespace some models add.
    static let headRegex = try! NSRegularExpression(
        pattern: #"^<{5,9} SEARCH>?\s*$"#,
        options: []
    )
    static let dividerRegex = try! NSRegularExpression(
        pattern: #"^={5,9}\s*$"#,
        options: []
    )
    static let replaceRegex = try! NSRegularExpression(
        pattern: #"^>{5,9} REPLACE\s*$"#,
        options: []
    )

    /// Parse `content` (typically the assistant's tool-call argument or
    /// raw response text) into zero or more edit blocks. Throws on the
    /// first malformed block — partial parses aren't returned, by
    /// design: a half-parsed block is more dangerous than a clean error.
    public static func findBlocks(in content: String) throws -> [EditBlock] {
        let lines = content.linesWithEndings()
        var blocks: [EditBlock] = []
        var currentFilename: String? = nil
        var i = 0

        while i < lines.count {
            let stripped = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)

            if matches(headRegex, stripped) {
                // 1. Find filename in the up-to-3 lines preceding this HEAD.
                let lookback = Array(lines[max(0, i - 3)..<i])
                let filename = findFilename(in: lookback) ?? currentFilename
                guard let filename else {
                    let ctx = lines[..<min(i + 1, lines.count)].joined()
                    throw EditBlockParseError.missingFilename(context: ctx)
                }
                currentFilename = filename

                // 2. Collect SEARCH lines until DIVIDER.
                var originalLines: [String] = []
                i += 1
                while i < lines.count,
                      !matches(dividerRegex, lines[i].trimmingCharacters(in: .whitespacesAndNewlines)) {
                    originalLines.append(lines[i])
                    i += 1
                }
                guard i < lines.count else {
                    let ctx = lines[..<min(i + 1, lines.count)].joined()
                    throw EditBlockParseError.missingDivider(context: ctx)
                }

                // 3. Collect REPLACE lines until REPLACE marker (or
                //    another DIVIDER, which Aider treats as a soft end —
                //    same block continuing with another SEARCH).
                var updatedLines: [String] = []
                i += 1
                while i < lines.count {
                    let s = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if matches(replaceRegex, s) || matches(dividerRegex, s) {
                        break
                    }
                    updatedLines.append(lines[i])
                    i += 1
                }
                guard i < lines.count else {
                    let ctx = lines[..<min(i + 1, lines.count)].joined()
                    throw EditBlockParseError.missingReplaceMarker(context: ctx)
                }

                blocks.append(EditBlock(
                    filename: filename,
                    original: originalLines.joined(),
                    updated: updatedLines.joined()
                ))
            }
            i += 1
        }

        return blocks
    }

    /// Walk back through the preceding lines (already trimmed to a max
    /// of 3 by the caller) and recover a filename. Aider's heuristics,
    /// summarised: strip fence markers, strip trailing colons, strip
    /// leading `#`, strip wrapping backticks and asterisks. Skip `...`.
    /// Return the first match.
    static func findFilename(in lookback: [String]) -> String? {
        // Walk newest-to-oldest, but bail as soon as we hit a non-fence
        // non-filename line — keeps us from grabbing a filename five
        // lines up that belongs to an earlier block.
        let reversed = Array(lookback.reversed())
        for raw in reversed.prefix(3) {
            if let name = stripFilename(raw) {
                return name
            }
            // Aider continues only as long as we keep seeing fences.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.hasPrefix("```") {
                break
            }
        }
        return nil
    }

    static func stripFilename(_ line: String) -> String? {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "..." || s.isEmpty { return nil }

        // Fenced filename like ```swift path/to/file.swift — strip the
        // fence and take what's after.
        if s.hasPrefix("```") {
            let after = String(s.dropFirst(3))
            // Bare ``` (no language tag, no filename): not a filename line.
            if after.isEmpty { return nil }
            // ```swift on its own: not a filename either, unless it
            // also contains a path separator or extension.
            if after.contains(".") || after.contains("/") {
                return after
            }
            return nil
        }

        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "`*"))
        return s.isEmpty ? nil : s
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return regex.firstMatch(in: s, range: range) != nil
    }
}

// MARK: - Applier

public enum EditBlockApplier {

    /// Apply a single block to `content`. Returns the new content on
    /// success, or a diagnostic on failure. Caller is responsible for
    /// the file I/O — keep this pure for testability.
    public static func apply(_ block: EditBlock, to content: String) -> EditApplyOutcome {
        let beforeText = stripQuotedWrapping(block.original, fname: block.filename)
        let afterText = stripQuotedWrapping(block.updated, fname: block.filename)

        // Empty SEARCH means "append" (or "create"). Aider matches that
        // behaviour and so does Anthropic's patch format.
        if beforeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let needsNewline = !content.isEmpty && !content.hasSuffix("\n")
            return .applied(newContent: content + (needsNewline ? "\n" : "") + afterText)
        }

        // Three-tier cascade.
        if let result = replaceMostSimilarChunk(whole: content, part: beforeText, replace: afterText) {
            return .applied(newContent: result)
        }

        let hint = buildFailureHint(content: content, search: beforeText, replace: afterText, path: block.filename)
        return .failed(reason: hint)
    }

    /// Apply many blocks in order. The first failure aborts and returns
    /// the partial results — caller decides whether to write any of
    /// them. This matches Aider's `apply_edits` semantics: per-block
    /// success, per-block diagnostics on failure.
    public static func applyAll(_ blocks: [EditBlock], to content: String) -> (newContent: String, failures: [(EditBlock, String)]) {
        var current = content
        var failures: [(EditBlock, String)] = []
        for block in blocks {
            switch apply(block, to: current) {
            case .applied(let next):
                current = next
            case .failed(let reason):
                failures.append((block, reason))
            }
        }
        return (current, failures)
    }

    // MARK: - Match cascade

    /// Tier 1 + Tier 2 + Tier 3 in Aider's order.
    static func replaceMostSimilarChunk(whole: String, part: String, replace: String) -> String? {
        let (wholeNorm, wholeLines) = prep(whole)
        let (_, partLines) = prep(part)
        let (_, replaceLines) = prep(replace)

        // Tier 1+2 directly on the full part.
        if let result = perfectOrWhitespace(whole: wholeLines, part: partLines, replace: replaceLines) {
            return result
        }

        // Some models prepend a spurious blank line to SEARCH. Aider
        // strips it and retries — same here.
        if partLines.count > 2,
           partLines[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmedPart = Array(partLines.dropFirst())
            if let result = perfectOrWhitespace(whole: wholeLines, part: trimmedPart, replace: replaceLines) {
                return result
            }
        }

        // Tier 3: dotdotdots elision.
        if let result = try? applyDotdotdots(whole: wholeNorm, part: part, replace: replace) {
            return result
        }

        return nil
    }

    /// Tier 1: exact line equality. Tier 2: leading-whitespace flexible.
    static func perfectOrWhitespace(whole: [String], part: [String], replace: [String]) -> String? {
        if let exact = perfectReplace(whole: whole, part: part, replace: replace) {
            return exact
        }
        return replaceWithMissingLeadingWhitespace(whole: whole, part: part, replace: replace)
    }

    /// Tier 1: literal line-tuple match.
    static func perfectReplace(whole: [String], part: [String], replace: [String]) -> String? {
        guard part.count <= whole.count else { return nil }
        let upper = whole.count - part.count
        if upper < 0 { return nil }
        for i in 0...upper {
            if Array(whole[i..<i + part.count]) == part {
                return (Array(whole[..<i]) + replace + Array(whole[(i + part.count)...])).joined()
            }
        }
        return nil
    }

    /// Count windows that match `part` with the same cascade as apply
    /// (exact lines, then leading-whitespace flex, then optional blank-first-line strip).
    /// Aligns unique-match gates with what `apply` would actually edit.
    /// Empty / whitespace-only SEARCH → 0 (create/append is not multi-match).
    public static func countMatchWindows(
        search: String,
        in content: String,
        filename: String = "",
        replace: String = ""
    ) -> Int {
        let beforeText = stripQuotedWrapping(search, fname: filename)
        if beforeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return 0
        }
        let (_, wholeLines) = prep(content)
        let (_, partLines) = prep(beforeText)
        // Same outdent basis as apply: min leading WS of SEARCH and REPLACE.
        // Omitted/empty REPLACE is treated as 0-indent so we do not outdent
        // SEARCH further than apply would for a typical unindented REPLACE.
        let replaceLines: [String]
        if replace.isEmpty {
            replaceLines = ["x"]
        } else {
            replaceLines = prep(stripQuotedWrapping(replace, fname: filename)).1
        }

        let exact = countPerfectWindows(whole: wholeLines, part: partLines)
        if exact > 0 { return exact }

        let ws = countWhitespaceWindows(whole: wholeLines, part: partLines, replace: replaceLines)
        if ws > 0 { return ws }

        // Same as apply: strip spurious leading blank line on SEARCH and retry.
        if partLines.count > 2,
           partLines[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = Array(partLines.dropFirst())
            let e2 = countPerfectWindows(whole: wholeLines, part: trimmed)
            if e2 > 0 { return e2 }
            let w2 = countWhitespaceWindows(whole: wholeLines, part: trimmed, replace: replaceLines)
            if w2 > 0 { return w2 }
        }
        return 0
    }

    static func countPerfectWindows(whole: [String], part: [String]) -> Int {
        guard !part.isEmpty, part.count <= whole.count else { return 0 }
        let upper = whole.count - part.count
        var count = 0
        for i in 0...upper {
            if Array(whole[i..<i + part.count]) == part {
                count += 1
            }
        }
        return count
    }

    static func countWhitespaceWindows(whole: [String], part: [String], replace: [String] = []) -> Int {
        guard !part.isEmpty, part.count <= whole.count else { return 0 }
        // Outdent by min leading whitespace of SEARCH+REPLACE (same as apply).
        var partAdj = part
        let allLeading: [Int] = (part + replace).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return line.prefix { $0 == " " || $0 == "\t" }.count
        }
        if let minLead = allLeading.min(), minLead > 0 {
            partAdj = part.map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? line
                    : String(line.dropFirst(minLead))
            }
        }
        guard partAdj.count <= whole.count else { return 0 }
        let upper = whole.count - partAdj.count
        var count = 0
        for i in 0...upper {
            let window = Array(whole[i..<i + partAdj.count])
            if matchModuloLeading(window: window, part: partAdj) != nil {
                count += 1
            }
        }
        return count
    }

    /// Tier 2: same as Tier 1 but allow a uniform leading-whitespace
    /// offset on both SEARCH and REPLACE. Handles the common case where
    /// the model emitted SEARCH outdented by 4 or 8 spaces because it
    /// doesn't see ambient indentation.
    static func replaceWithMissingLeadingWhitespace(whole: [String], part: [String], replace: [String]) -> String? {
        // Step 1 (Aider): outdent everything in part + replace by the
        // max-uniform leading-whitespace amount we can.
        var partAdj = part
        var replaceAdj = replace

        let allLeading: [Int] = (part + replace).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return line.prefix { $0 == " " || $0 == "\t" }.count
        }
        if let minLead = allLeading.min(), minLead > 0 {
            partAdj = part.map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? line
                    : String(line.dropFirst(minLead))
            }
            replaceAdj = replace.map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? line
                    : String(line.dropFirst(minLead))
            }
        }

        // Step 2: try each window. For each candidate position, check
        // whether the non-whitespace content matches AND whether the
        // ambient leading-whitespace offset is uniform across all lines
        // — if so, that offset is what REPLACE needs to be re-indented
        // by.
        guard partAdj.count <= whole.count else { return nil }
        let upper = whole.count - partAdj.count
        if upper < 0 { return nil }

        for i in 0...upper {
            let window = Array(whole[i..<i + partAdj.count])
            guard let addLead = matchModuloLeading(window: window, part: partAdj) else { continue }
            let reindented = replaceAdj.map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? line
                    : addLead + line
            }
            return (Array(whole[..<i]) + reindented + Array(whole[(i + partAdj.count)...])).joined()
        }
        return nil
    }

    /// For a candidate window, return the uniform leading-whitespace
    /// prefix the window has on top of `part` — or nil if the match
    /// doesn't survive whitespace normalisation. Mirrors Aider's
    /// `match_but_for_leading_whitespace`.
    static func matchModuloLeading(window: [String], part: [String]) -> String? {
        guard window.count == part.count else { return nil }
        for (a, b) in zip(window, part) {
            // Non-whitespace content must match exactly.
            let lstA = String(a.drop { $0 == " " || $0 == "\t" })
            let lstB = String(b.drop { $0 == " " || $0 == "\t" })
            if lstA != lstB { return nil }
        }
        // Are the offsets uniform across non-blank lines?
        var offsets: Set<String> = []
        for (a, b) in zip(window, part) {
            if a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let aLead = a.prefix { $0 == " " || $0 == "\t" }.count
            let bLead = b.prefix { $0 == " " || $0 == "\t" }.count
            if aLead < bLead { return nil }
            let extra = String(a.prefix(aLead - bLead))
            offsets.insert(extra)
        }
        if offsets.count == 1 { return offsets.first }
        if offsets.isEmpty { return "" }   // all-blank windows
        return nil
    }

    /// Tier 3: `...` elision. SEARCH and REPLACE are split on lines
    /// that contain ONLY `...` (with optional surrounding whitespace).
    /// Each non-`...` paired segment is applied as a single literal
    /// `whole.replace(part, replace, count=1)`. The dots themselves
    /// must match — i.e., SEARCH and REPLACE must have the same number
    /// of `...` markers in the same positions.
    static func applyDotdotdots(whole: String, part: String, replace: String) throws -> String? {
        let dotsRegex = try NSRegularExpression(
            pattern: #"(?m)^\s*\.\.\.\s*$\n?"#,
            options: []
        )

        let partPieces = splitKeepingDelimiters(part, regex: dotsRegex)
        let replacePieces = splitKeepingDelimiters(replace, regex: dotsRegex)

        // No dots → nil so the caller knows this tier doesn't apply
        // (caller will already have tried Tier 1+2).
        guard partPieces.count > 1 || replacePieces.count > 1 else { return nil }

        if partPieces.count != replacePieces.count {
            throw EditBlockParseError.unpairedDotdotdots
        }

        // The odd indices in the split arrays are the `...` matches
        // themselves — they must be identical in both halves.
        for i in stride(from: 1, to: partPieces.count, by: 2) {
            if partPieces[i] != replacePieces[i] {
                throw EditBlockParseError.unmatchedDotdotdots
            }
        }

        // The even indices are the text between dots. Apply each pair
        // by single-occurrence replacement.
        var current = whole
        for i in stride(from: 0, to: partPieces.count, by: 2) {
            let p = partPieces[i]
            let r = replacePieces[i]
            if p.isEmpty && r.isEmpty { continue }
            if p.isEmpty && !r.isEmpty {
                // Append at end. Aider's behaviour.
                if !current.hasSuffix("\n") { current += "\n" }
                current += r
                continue
            }
            // Must occur exactly once.
            let occurrences = current.components(separatedBy: p).count - 1
            if occurrences == 0 { return nil }   // back-off
            if occurrences > 1 { return nil }    // ambiguous, refuse
            if let range = current.range(of: p) {
                current.replaceSubrange(range, with: r)
            }
        }
        return current
    }

    // MARK: - Wrapping strip + helpers

    /// Remove an optional leading "filename" line and an optional
    /// surrounding triple-backtick fence from `res`. Aider strips both
    /// because models sometimes include the filename inside the block
    /// for clarity.
    static func stripQuotedWrapping(_ res: String, fname: String) -> String {
        if res.isEmpty { return res }
        var lines = res.linesWithEndings()
        let basename = (fname as NSString).lastPathComponent

        // Drop leading filename echo. Skip when basename is empty — in Swift
        // `hasSuffix("")` is always true and would wipe the first SEARCH line.
        if !basename.isEmpty,
           let first = lines.first,
           first.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(basename) {
            lines.removeFirst()
        }

        // Drop wrapping ``` fences.
        if let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```"),
           let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
            lines.removeFirst()
            lines.removeLast()
        }

        var result = lines.joined()
        if !result.isEmpty && !result.hasSuffix("\n") {
            result += "\n"
        }
        return result
    }

    /// Normalise: ensure trailing newline, split into lines-with-endings.
    static func prep(_ content: String) -> (String, [String]) {
        var s = content
        if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
        return (s, s.linesWithEndings())
    }

    /// Build Aider's "did you mean..." style failure message — the model
    /// can act on it directly instead of re-emitting the same broken
    /// block.
    static func buildFailureHint(content: String, search: String, replace: String, path: String) -> String {
        var msg = "## SearchReplaceNoExactMatch: SEARCH block failed to match lines in \(path)\n"
        msg += "<<<<<<< SEARCH\n\(search)=======\n\(replace)>>>>>>> REPLACE\n\n"

        if let nearest = findSimilarLines(search: search, content: content) {
            msg += "Did you mean to match one of these chunks from \(path)?\n```\n\(nearest)\n```\n\n"
        }
        if !replace.isEmpty, content.contains(replace) {
            msg += "Note: the REPLACE text is already in \(path). Are you sure this block is needed?\n\n"
        }
        msg += "The SEARCH section must match an existing block in the file — exactly, OR with uniform leading-whitespace offset, OR with `...` markers for elided unchanged regions.\n"
        return msg
    }

    /// Simple "find the most similar window" for the diagnostic. We use
    /// line-set Jaccard similarity over a sliding window — fast, no
    /// external deps, good enough to point the model at the right area.
    static func findSimilarLines(search: String, content: String, threshold: Double = 0.5, context: Int = 3) -> String? {
        let searchLines = search.linesWithEndings()
        let contentLines = content.linesWithEndings()
        guard !searchLines.isEmpty, !contentLines.isEmpty else { return nil }

        let searchSet = Set(searchLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var bestRatio = 0.0
        var bestStart = -1
        let windowSize = searchLines.count
        if windowSize == 0 || windowSize > contentLines.count { return nil }

        for i in 0...(contentLines.count - windowSize) {
            let window = contentLines[i..<i + windowSize]
            let windowSet = Set(window.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            let intersect = searchSet.intersection(windowSet).count
            let union = searchSet.union(windowSet).count
            if union == 0 { continue }
            let ratio = Double(intersect) / Double(union)
            if ratio > bestRatio {
                bestRatio = ratio
                bestStart = i
            }
        }
        if bestRatio < threshold || bestStart < 0 { return nil }

        let lo = max(0, bestStart - context)
        let hi = min(contentLines.count, bestStart + windowSize + context)
        return contentLines[lo..<hi].joined().trimmingCharacters(in: .newlines)
    }
}

// MARK: - String utilities

private extension String {
    /// Split into lines but keep the line terminators on each line — so
    /// `joined()` is the inverse of `splitlines(keepends=True)` in
    /// Python. Trailing line without a terminator is preserved.
    func linesWithEndings() -> [String] {
        var result: [String] = []
        var current = ""
        for ch in self {
            current.append(ch)
            if ch == "\n" {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Split a string on a regex, returning the alternating sequence of
/// non-match and match substrings — so `pieces[1::2]` are the
/// delimiters and `pieces[0::2]` are the text between them.
private func splitKeepingDelimiters(_ s: String, regex: NSRegularExpression) -> [String] {
    let ns = s as NSString
    let range = NSRange(location: 0, length: ns.length)
    var pieces: [String] = []
    var lastEnd = 0
    regex.enumerateMatches(in: s, range: range) { match, _, _ in
        guard let match else { return }
        let r = match.range
        pieces.append(ns.substring(with: NSRange(location: lastEnd, length: r.location - lastEnd)))
        pieces.append(ns.substring(with: r))
        lastEnd = r.location + r.length
    }
    pieces.append(ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd)))
    return pieces
}
