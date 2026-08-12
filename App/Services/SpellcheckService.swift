//
//  SpellcheckService.swift
//
//  Combines `NSSpellChecker` (typos) with a few simple heuristics (passive
//  voice, hedging words, sentence-length variance). Reports findings as
//  markdown — does NOT auto-edit; that's the model's job after reviewing.
//
//  `NSSpellChecker` is main-thread-only, so the whole service is pinned to
//  `@MainActor`. The check is synchronous; callers awaiting from a
//  background actor should `await` the main hop.
//

import Foundation
import AppKit

@MainActor
public enum SpellcheckService {

    public static func check(path: String?,
                             text: String?,
                             language: String?) -> String {
        let body: String
        let label: String
        if let t = text, !t.isEmpty {
            body = t
            label = "inline text (\(t.count) chars)"
        } else if let p = path, !p.isEmpty,
                  let data = try? String(contentsOfFile: (p as NSString).expandingTildeInPath,
                                         encoding: .utf8) {
            body = data
            label = (p as NSString).lastPathComponent
        } else {
            return "Error: provide either `path` or `text`."
        }

        let checker = NSSpellChecker.shared
        let lang = language.flatMap { $0.isEmpty ? nil : $0 } ?? checker.language()

        let typos = scanTypos(body, language: lang, checker: checker)
        let passive = scanPassive(body)
        let hedges = scanHedges(body)
        let longSentences = scanLongSentences(body)

        var out = "# Spell & style report — \(label)\n_Language: \(lang)_\n\n"
        out += section("Possible typos", typos)
        out += section("Passive voice candidates", passive)
        out += section("Hedging language", hedges)
        out += section("Long sentences (>30 words)", longSentences)

        if typos.isEmpty && passive.isEmpty && hedges.isEmpty && longSentences.isEmpty {
            out += "_No issues found._"
        }
        return out
    }

    // MARK: - Scans

    private static func scanTypos(_ body: String,
                                  language: String,
                                  checker: NSSpellChecker) -> [String] {
        var results: [String] = []
        var location = 0
        let ns = body as NSString
        let total = ns.length

        var wordCount: Int = 0
        let docTag = NSSpellChecker.uniqueSpellDocumentTag()
        while location < total {
            let range = checker.checkSpelling(of: body,
                                              startingAt: location,
                                              language: language,
                                              wrap: false,
                                              inSpellDocumentWithTag: docTag,
                                              wordCount: &wordCount)
            if range.location == NSNotFound || range.length == 0 || range.location < location { break }
            let word = ns.substring(with: range)
            let line = lineNumber(in: body, at: range.location)
            let suggestions = checker.guesses(forWordRange: range,
                                              in: body,
                                              language: language,
                                              inSpellDocumentWithTag: docTag)?.prefix(3) ?? []
            let sugList = suggestions.isEmpty ? "" : " → \(suggestions.joined(separator: ", "))"
            results.append("L\(line): `\(word)`\(sugList)")
            location = range.location + range.length
            if results.count >= 100 { break } // Cap noise on huge docs.
        }
        return results
    }

    private static func scanPassive(_ body: String) -> [String] {
        // Naïve passive: be-verb + past participle (-ed / common irregulars).
        let beVerbs = "(?:is|are|was|were|be|been|being|am)"
        let participle = "[A-Za-z]+(?:ed|en)\\b"
        let pattern = "\\b\(beVerbs)\\s+(?:[a-z]+\\s+)?\(participle)"
        return matchSnippets(body, pattern: pattern, opts: [.caseInsensitive], cap: 50)
    }

    private static func scanHedges(_ body: String) -> [String] {
        let hedges = ["perhaps", "maybe", "somewhat", "rather", "fairly",
                      "quite", "probably", "possibly", "arguably", "kind of",
                      "sort of", "i think", "i believe", "it seems"]
        let pattern = "\\b(?:" + hedges.joined(separator: "|") + ")\\b"
        return matchSnippets(body, pattern: pattern, opts: [.caseInsensitive], cap: 50)
    }

    private static func scanLongSentences(_ body: String) -> [String] {
        // Split on sentence terminators; flag any sentence > 30 words.
        // Build an array of (startOffset, trimmedText) by walking the body forward
        // past each terminator — no drift because we consume exactly what we expect.
        var results: [String] = []
        let chars = Array(body)
        var i = 0
        let len = chars.count

        while i < len && results.count < 30 {
            // Skip leading whitespace.
            while i < len && chars[i].isWhitespace { i += 1 }
            guard i < len else { break }

            // Collect one sentence: stop at `.`, `!`, or `?`.
            let start = i
            while i < len && !".!?".contains(chars[i]) { i += 1 }
            let sentence = String(chars[start..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = sentence.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count

            if wordCount > 30 {
                // Count newlines before `start` to determine line number.
                let newlines = String(chars[..<start]).components(separatedBy: "\n").count - 1
                let line = newlines + 1
                results.append("L\(line) (\(wordCount) words): \(sentence.prefix(80))…")
            }

            // Skip the terminator itself.
            if i < len && ".!?".contains(chars[i]) { i += 1 }
        }
        return results
    }
    // MARK: - Helpers

    private static func matchSnippets(_ body: String,
                                      pattern: String,
                                      opts: NSRegularExpression.Options,
                                      cap: Int) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return [] }
        let range = NSRange(body.startIndex..., in: body)
        let matches = re.matches(in: body, options: [], range: range).prefix(cap)
        return matches.compactMap { m in
            guard let r = Range(m.range, in: body) else { return nil }
            let snippet = String(body[r])
            let line = lineNumber(in: body, at: m.range.location)
            return "L\(line): `\(snippet)`"
        }
    }

    private static func lineNumber(in body: String, at offset: Int) -> Int {
        let prefix = (body as NSString).substring(with: NSRange(location: 0, length: min(offset, (body as NSString).length)))
        return prefix.components(separatedBy: "\n").count
    }

    private static func section(_ title: String, _ items: [String]) -> String {
        if items.isEmpty { return "" }
        return "## \(title) (\(items.count))\n\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
    }
}
