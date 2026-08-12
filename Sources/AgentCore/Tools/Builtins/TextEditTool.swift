//
//  TextEditTool.swift
//
//  Bundle of pure-text utilities exposed as a single tool with an `action`
//  discriminator. All operations are Foundation-only — no UI, no system
//  frameworks beyond NSRegularExpression.
//
//  Actions:
//    • bulk_find_replace — regex or literal replace across one or more files.
//    • text_stats        — word/char/sentence/paragraph counts, F-K grade, top words.
//    • generate_toc      — build (and optionally insert) a markdown TOC.
//    • extract_citations — pull DOIs, URLs, footnotes, and md links from a doc.
//    • fill_template     — mustache-light {{key}} substitution.
//

import Foundation

public struct TextEditTool: Tool {
    public static let name = "text_edit"
    public static let category: ToolCategory = .filesystem
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Pure-text utilities. Pick one via `action`:
          • bulk_find_replace — regex/literal replace across files. Args: paths[], pattern, replacement, useRegex?, dryRun?
          • text_stats        — counts + reading time + F-K grade. Args: path OR text
          • generate_toc      — markdown table-of-contents. Args: path, maxDepth?, write?
          • extract_citations — DOIs / URLs / footnotes / md links. Args: path
          • fill_template     — substitute {{key}} placeholders. Args: templatePath, outputPath?, values{}
        """,
        parameters: .init(
            properties: [
                "action": .init(
                    type: "string",
                    description: "One of: bulk_find_replace, text_stats, generate_toc, extract_citations, fill_template.",
                    enum: ["bulk_find_replace", "text_stats", "generate_toc", "extract_citations", "fill_template"]
                ),
                "paths":        .init(type: "array", description: "bulk_find_replace: target file paths.",
                                      items: .init(type: "string")),
                "pattern":      .init(type: "string", description: "bulk_find_replace: regex or literal pattern."),
                "replacement":  .init(type: "string", description: "bulk_find_replace: replacement (supports $1 with useRegex)."),
                "useRegex":     .init(type: "boolean", description: "bulk_find_replace: treat pattern as NSRegularExpression. Default false."),
                "dryRun":       .init(type: "boolean", description: "bulk_find_replace: report changes but don't write. Default false."),
                "path":         .init(type: "string", description: "Target file path for stats, toc, extract, etc."),
                "text":         .init(type: "string", description: "text_stats: inline text body (use instead of path)."),
                "maxDepth":     .init(type: "integer", description: "generate_toc: max header depth (1-6). Default 3."),
                "write":        .init(type: "boolean", description: "generate_toc: write the TOC back into the file. Default false."),
                "templatePath": .init(type: "string", description: "fill_template: source template file."),
                "outputPath":   .init(type: "string", description: "fill_template: where to write the rendered file. Omit for inline."),
                "values":       .init(type: "object", description: "fill_template: {key: string} placeholder map.")
            ],
            required: ["action"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let action = try arguments.string("action").lowercased()
        let base = context.workingDirectory

        switch action {
        case "bulk_find_replace":
            return bulkFindReplace(arguments: arguments, base: base)
        case "text_stats":
            return textStats(arguments: arguments, base: base)
        case "generate_toc":
            return generateTOC(arguments: arguments, base: base)
        case "extract_citations":
            return extractCitations(arguments: arguments, base: base)
        case "fill_template":
            return fillTemplate(arguments: arguments, base: base)
        default:
            return ToolResult(content: "Unknown action '\(action)'.", isError: true)
        }
    }

    // MARK: - bulk_find_replace

    private func bulkFindReplace(arguments: ToolArguments, base: URL) -> ToolResult {
        let rawPaths = arguments.stringArray("paths")
        let pattern = arguments.stringOptional("pattern") ?? ""
        let replacement = arguments.stringOptional("replacement") ?? ""
        let useRegex = arguments.bool("useRegex")
        let dryRun = arguments.bool("dryRun")

        guard !rawPaths.isEmpty else {
            return ToolResult(content: "Error: no paths provided.", isError: true)
        }
        guard !pattern.isEmpty else {
            return ToolResult(content: "Error: empty pattern.", isError: true)
        }

        let regex: NSRegularExpression?
        if useRegex {
            do {
                regex = try NSRegularExpression(pattern: pattern, options: [])
            } catch {
                return ToolResult(content: "Error: invalid regex — \(error.localizedDescription)", isError: true)
            }
        } else {
            regex = nil
        }

        var changedFiles = 0
        var totalReplacements = 0
        var perFile: [String] = []
        var mutated: [String] = []

        for raw in rawPaths {
            let url = resolvePath(raw, base: base)
            guard let original = try? String(contentsOf: url, encoding: .utf8) else {
                perFile.append("  skip (unreadable): \(raw)")
                continue
            }
            let (next, count): (String, Int)
            if let re = regex {
                let range = NSRange(original.startIndex..., in: original)
                let n = re.numberOfMatches(in: original, options: [], range: range)
                let out = re.stringByReplacingMatches(in: original, options: [],
                                                     range: range, withTemplate: replacement)
                next = out
                count = n
            } else {
                var n = 0
                var search = original.startIndex..<original.endIndex
                while let r = original.range(of: pattern, options: [], range: search) {
                    n += 1
                    search = r.upperBound..<original.endIndex
                }
                next = original.replacingOccurrences(of: pattern, with: replacement)
                count = n
            }

            if count == 0 {
                perFile.append("  · no matches: \(raw)")
                continue
            }
            changedFiles += 1
            totalReplacements += count
            perFile.append("  ✓ \(count) replacement(s): \(raw)")
            if !dryRun {
                do {
                    try next.write(to: url, atomically: true, encoding: .utf8)
                    mutated.append(raw)
                } catch {
                    return ToolResult(content: "Error writing \(raw): \(error.localizedDescription)",
                                      isError: true)
                }
            }
        }

        var out = dryRun ? "[DRY RUN] " : ""
        out += "\(totalReplacements) replacement(s) across \(changedFiles) file(s)."
        if !perFile.isEmpty { out += "\n" + perFile.joined(separator: "\n") }
        return ToolResult(content: out, mutatedPaths: mutated)
    }

    // MARK: - text_stats

    private func textStats(arguments: ToolArguments, base: URL) -> ToolResult {
        let body: String
        if let t = arguments.stringOptional("text"), !t.isEmpty {
            body = t
        } else if let p = arguments.stringOptional("path"), !p.isEmpty,
                  let data = try? String(contentsOf: resolvePath(p, base: base), encoding: .utf8) {
            body = data
        } else {
            return ToolResult(content: "Error: provide either `path` or `text`.", isError: true)
        }

        let charCount     = body.count
        let charCountNoWS = body.filter { !$0.isWhitespace }.count
        let words         = body.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let wordCount     = words.count
        let paragraphs    = body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sentenceTokens = body.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sentenceCount = max(sentenceTokens.count, 1)

        let syllables = words.reduce(0) { $0 + Self.syllableCount(String($1)) }
        let grade: Double
        if wordCount > 0 {
            let asl = Double(wordCount) / Double(sentenceCount)
            let asw = Double(syllables) / Double(wordCount)
            grade = (0.39 * asl) + (11.8 * asw) - 15.59
        } else {
            grade = 0
        }

        let readingMin = max(1, Int((Double(wordCount) / 220.0).rounded()))

        let stop: Set<String> = ["the","a","an","and","or","but","of","to","in","on","for","with","by",
                                 "is","are","was","were","be","been","being","that","this","these","those",
                                 "it","its","as","at","from","i","you","he","she","we","they","me","him",
                                 "her","us","them","my","your","his","their","our","not","no","do","does",
                                 "did","have","has","had","will","would","can","could","should","may","might"]
        var freq: [String: Int] = [:]
        for w in words {
            let s = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard s.count > 2, !stop.contains(s) else { continue }
            freq[s, default: 0] += 1
        }
        let top = freq.sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key) (\($0.value))" }
            .joined(separator: ", ")

        let avgSentence = wordCount > 0
            ? String(format: "%.1f", Double(wordCount) / Double(sentenceCount))
            : "0"
        let report = """
        Words:         \(wordCount)
        Characters:    \(charCount) (\(charCountNoWS) excl. whitespace)
        Sentences:     \(sentenceCount)
        Paragraphs:    \(paragraphs.count)
        Reading time:  ~\(readingMin) min @ 220 wpm
        Avg sentence:  \(avgSentence) words
        F-K grade:     \(String(format: "%.1f", grade))
        Top words:     \(top.isEmpty ? "—" : top)
        """
        return ToolResult(content: report)
    }

    private static func syllableCount(_ word: String) -> Int {
        let w = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard !w.isEmpty else { return 0 }
        let vowels: Set<Character> = ["a","e","i","o","u","y"]
        var count = 0
        var prevIsVowel = false
        for ch in w {
            let isVowel = vowels.contains(ch)
            if isVowel && !prevIsVowel { count += 1 }
            prevIsVowel = isVowel
        }
        if w.hasSuffix("e"), count > 1 { count -= 1 }
        return max(count, 1)
    }

    // MARK: - generate_toc

    private func generateTOC(arguments: ToolArguments, base: URL) -> ToolResult {
        guard let path = arguments.stringOptional("path"), !path.isEmpty else {
            return ToolResult(content: "Error: `path` is required for generate_toc.", isError: true)
        }
        let url = resolvePath(path, base: base)
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            return ToolResult(content: "Error: could not read \(path).", isError: true)
        }
        let maxDepth = arguments.intOptional("maxDepth") ?? 3
        let depthCap = max(1, min(maxDepth, 6))
        let write = arguments.bool("write")

        var toc: [String] = []
        var inFence = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            guard s.hasPrefix("#") else { continue }
            let hashRun = s.prefix(while: { $0 == "#" }).count
            guard hashRun >= 1, hashRun <= depthCap else { continue }
            let title = s.drop(while: { $0 == "#" })
                         .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let indent = String(repeating: "  ", count: hashRun - 1)
            toc.append("\(indent)- [\(title)](#\(Self.slugify(title)))")
        }

        if toc.isEmpty {
            return ToolResult(content: "No headers found (max depth \(depthCap)).")
        }

        let block = "<!-- TOC -->\n## Table of Contents\n\n" + toc.joined(separator: "\n") + "\n<!-- /TOC -->"
        if write {
            let pattern = "<!-- TOC -->[\\s\\S]*?<!-- /TOC -->"
            let newBody: String
            if let re = try? NSRegularExpression(pattern: pattern, options: []),
               re.firstMatch(in: body, options: [], range: NSRange(body.startIndex..., in: body)) != nil {
                newBody = re.stringByReplacingMatches(
                    in: body, options: [],
                    range: NSRange(body.startIndex..., in: body),
                    withTemplate: block.replacingOccurrences(of: "$", with: "\\$")
                )
            } else {
                newBody = block + "\n\n" + body
            }
            do {
                try newBody.write(to: url, atomically: true, encoding: .utf8)
                return ToolResult(
                    content: "Wrote TOC (\(toc.count) entries) to \(path).",
                    mutatedPaths: [path]
                )
            } catch {
                return ToolResult(content: "Error writing TOC: \(error.localizedDescription)",
                                  isError: true)
            }
        }
        return ToolResult(content: block)
    }

    private static func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch.isWhitespace || ch == "-" || ch == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - extract_citations

    private func extractCitations(arguments: ToolArguments, base: URL) -> ToolResult {
        guard let path = arguments.stringOptional("path"), !path.isEmpty else {
            return ToolResult(content: "Error: `path` is required.", isError: true)
        }
        let url = resolvePath(path, base: base)
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            return ToolResult(content: "Error: could not read \(path).", isError: true)
        }
        let dois     = Self.matches(in: body, pattern: #"10\.\d{4,9}/[-._;()/:A-Z0-9]+"#, opts: [.caseInsensitive])
        let urls     = Self.matches(in: body, pattern: #"https?://[^\s<>\"\)\]]+"#,        opts: [])
        let foot     = Self.matches(in: body, pattern: #"\[\^[^\]]+\]"#,                    opts: [])
        let refLinks = Self.matches(in: body, pattern: #"\[[^\]]+\]\([^\)]+\)"#,            opts: [])

        func section(_ title: String, _ items: [String]) -> String {
            if items.isEmpty { return "" }
            let uniq = Array(Set(items)).sorted()
            return "## \(title) (\(uniq.count))\n\n" + uniq.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }

        var out = "# Citations extracted from \(url.lastPathComponent)\n\n"
        out += section("DOIs", dois)
        out += section("URLs", urls)
        out += section("Markdown links", refLinks)
        out += section("Footnote markers", foot)
        if dois.isEmpty && urls.isEmpty && foot.isEmpty && refLinks.isEmpty {
            out += "_No citations found._"
        }
        return ToolResult(content: out)
    }

    private static func matches(in s: String,
                                pattern: String,
                                opts: NSRegularExpression.Options) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, options: [], range: range).compactMap { m in
            Range(m.range, in: s).map { String(s[$0]) }
        }
    }

    // MARK: - fill_template

    private func fillTemplate(arguments: ToolArguments, base: URL) -> ToolResult {
        guard let templatePath = arguments.stringOptional("templatePath"), !templatePath.isEmpty else {
            return ToolResult(content: "Error: `templatePath` is required.", isError: true)
        }
        let url = resolvePath(templatePath, base: base)
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            return ToolResult(content: "Error: could not read template at \(templatePath).",
                              isError: true)
        }

        // values is an [String: String]-ish object; we coerce values to String.
        var values: [String: String] = [:]
        if let dict = arguments.raw["values"] as? [String: Any] {
            for (k, v) in dict {
                if let s = v as? String { values[k] = s }
                else { values[k] = String(describing: v) }
            }
        }

        guard let re = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_\.]+)\s*\}\}"#,
                                                options: []) else {
            return ToolResult(content: "Error: internal regex failure.", isError: true)
        }

        var unresolved: [String] = []
        var resolvedCount = 0
        let range = NSRange(body.startIndex..., in: body)
        let result = NSMutableString(string: body)
        let allMatches = re.matches(in: body, options: [], range: range).reversed()
        for m in allMatches {
            guard m.numberOfRanges >= 2,
                  let keyRange = Range(m.range(at: 1), in: body) else { continue }
            let key = String(body[keyRange])
            if let value = values[key] {
                result.replaceCharacters(in: m.range, with: value)
                resolvedCount += 1
            } else {
                unresolved.append(key)
            }
        }

        let rendered = result as String
        if let outputPath = arguments.stringOptional("outputPath"), !outputPath.isEmpty {
            let outURL = resolvePath(outputPath, base: base)
            do {
                try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try rendered.write(to: outURL, atomically: true, encoding: .utf8)
            } catch {
                return ToolResult(content: "Error writing output: \(error.localizedDescription)",
                                  isError: true)
            }
            var msg = "Wrote \(outputPath). Resolved \(resolvedCount) placeholder(s)."
            if !unresolved.isEmpty {
                let unique = Array(Set(unresolved)).sorted()
                msg += "\nUnresolved (\(unique.count)): \(unique.joined(separator: ", "))"
            }
            return ToolResult(content: msg, mutatedPaths: [outputPath])
        } else {
            var msg = rendered
            if !unresolved.isEmpty {
                let unique = Array(Set(unresolved)).sorted()
                msg += "\n\n_Unresolved placeholders: \(unique.joined(separator: ", "))_"
            }
            return ToolResult(content: msg)
        }
    }
}
