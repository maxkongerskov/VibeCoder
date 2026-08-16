//
//  ANSIParser.swift
//  Wave U3 — minimal CSI subset; unknown sequences are dropped.
//

import Foundation

enum ANSIToken: Equatable, Sendable {
    case text(String)
    case sgr([Int])
    case eraseLine(Int)
    case carriageReturn
    case lineFeed
    case backspace
}

/// Incremental parser. Incomplete ESC sequences stay in `pending` across chunks.
struct ANSIParser: Sendable {
    private var pending = ""

    mutating func push(_ input: String) -> [ANSIToken] {
        let source = pending + input
        pending = ""
        var tokens: [ANSIToken] = []
        var textStart = source.startIndex
        var i = source.startIndex

        func flushText(upTo end: String.Index) {
            if textStart < end {
                tokens.append(.text(String(source[textStart..<end])))
            }
        }

        while i < source.endIndex {
            let ch = source[i]
            if ch == "\u{1b}" {
                flushText(upTo: i)
                switch consumeEscape(source, from: i) {
                case .incomplete:
                    pending = String(source[i...])
                    return tokens
                case .consumed(let next, let token):
                    if let token { tokens.append(token) }
                    i = next
                    textStart = next
                }
                continue
            }
            if ch == "\r" {
                flushText(upTo: i)
                tokens.append(.carriageReturn)
                i = source.index(after: i)
                textStart = i
                continue
            }
            if ch == "\n" {
                flushText(upTo: i)
                tokens.append(.lineFeed)
                i = source.index(after: i)
                textStart = i
                continue
            }
            if ch == "\u{8}" || ch == "\u{7f}" {
                flushText(upTo: i)
                tokens.append(.backspace)
                i = source.index(after: i)
                textStart = i
                continue
            }
            if ch == "\u{7}" || ch == "\u{0}" {
                flushText(upTo: i)
                i = source.index(after: i)
                textStart = i
                continue
            }
            i = source.index(after: i)
        }
        flushText(upTo: source.endIndex)
        return tokens
    }

    private enum EscapeResult {
        case incomplete
        case consumed(next: String.Index, token: ANSIToken?)
    }

    private func consumeEscape(_ s: String, from esc: String.Index) -> EscapeResult {
        let afterEsc = s.index(after: esc)
        guard afterEsc < s.endIndex else { return .incomplete }
        let intro = s[afterEsc]
        if intro == "[" {
            return consumeCSI(s, bodyStart: s.index(after: afterEsc))
        }
        if intro == "]" {
            return consumeTerminated(s, from: s.index(after: afterEsc))
        }
        if intro == "P" || intro == "^" || intro == "_" {
            return consumeTerminated(s, from: s.index(after: afterEsc))
        }
        if intro == "(" || intro == ")" || intro == "*" || intro == "+" {
            let third = s.index(after: afterEsc)
            guard third < s.endIndex else { return .incomplete }
            return .consumed(next: s.index(after: third), token: nil)
        }
        return .consumed(next: s.index(after: afterEsc), token: nil)
    }

    private func consumeCSI(_ s: String, bodyStart: String.Index) -> EscapeResult {
        var i = bodyStart
        var raw = ""
        while i < s.endIndex {
            let ch = s[i]
            let value = ch.unicodeScalars.first?.value ?? 0
            if value >= 0x40 && value <= 0x7E {
                return .consumed(next: s.index(after: i), token: decodeCSI(raw: raw, final: ch))
            }
            if value >= 0x20 && value <= 0x3F {
                raw.append(ch)
                if raw.count > 96 {
                    return .consumed(next: s.index(after: i), token: nil)
                }
                i = s.index(after: i)
                continue
            }
            return .consumed(next: i, token: nil)
        }
        return .incomplete
    }

    private func consumeTerminated(_ s: String, from start: String.Index) -> EscapeResult {
        var i = start
        var count = 0
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\u{7}" {
                return .consumed(next: s.index(after: i), token: nil)
            }
            if ch == "\u{1b}" {
                let next = s.index(after: i)
                guard next < s.endIndex else { return .incomplete }
                if s[next] == "\\" {
                    return .consumed(next: s.index(after: next), token: nil)
                }
            }
            count += 1
            if count > 8192 {
                return .consumed(next: s.index(after: i), token: nil)
            }
            i = s.index(after: i)
        }
        return .incomplete
    }

    private func decodeCSI(raw: String, final: Character) -> ANSIToken? {
        switch final {
        case "m":
            return .sgr(parseParams(raw))
        case "K":
            return .eraseLine(parseParams(raw).first ?? 0)
        default:
            return nil
        }
    }

    private func parseParams(_ raw: String) -> [Int] {
        let filtered = raw.filter { $0.isNumber || $0 == ";" }
        if filtered.isEmpty { return [] }
        return filtered.split(separator: ";", omittingEmptySubsequences: false).map { part in
            if part.isEmpty { return 0 }
            return Int(part) ?? 0
        }
    }
}
