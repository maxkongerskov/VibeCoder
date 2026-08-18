//
//  ANSIParser.swift
//  VT/xterm CSI subset for full-screen TUI apps (Grok Build, vim, etc.).
//

import Foundation

enum ANSIToken: Equatable, Sendable {
    case text(String)
    case sgr([Int])
    case eraseLine(Int)
    case eraseDisplay(Int)
    case eraseChars(Int)
    case carriageReturn
    case lineFeed
    case backspace
    case tab
    case cursorPosition(row: Int, col: Int)
    case cursorUp(Int)
    case cursorDown(Int)
    case cursorForward(Int)
    case cursorBack(Int)
    case cursorColumn(Int)
    case cursorRow(Int)
    case saveCursor
    case restoreCursor
    case index
    case reverseIndex
    case nextLine
    case scrollRegion(top: Int, bottom: Int)
    case scrollUp(Int)
    case scrollDown(Int)
    case insertLines(Int)
    case deleteLines(Int)
    case insertChars(Int)
    case deleteChars(Int)
    case decset([Int])
    case decrst([Int])
    case setMode([Int])
    case resetMode([Int])
    case deviceStatus(Int)
    case deviceAttributes
    case reset
}

/// Incremental parser. Incomplete ESC sequences stay in `pending` across chunks.
struct ANSIParser: Sendable {
    private var pending = ""

    mutating func push(_ input: String) -> [ANSIToken] {
        let source = pending + input
        pending = ""
        var tokens: [ANSIToken] = []
        let scalars = source.unicodeScalars
        var textStart = scalars.startIndex
        var i = scalars.startIndex

        func flushText(upTo end: String.Index) {
            if textStart < end {
                tokens.append(.text(String(scalars[textStart..<end])))
            }
        }

        while i < scalars.endIndex {
            switch scalars[i].value {
            case 0x1B:
                flushText(upTo: i)
                switch consumeEscape(source, from: i) {
                case .incomplete:
                    pending = String(scalars[i...])
                    return tokens
                case .consumed(let next, let token):
                    if let token { tokens.append(token) }
                    i = next
                    textStart = next
                }
            case 0x0D:
                flushText(upTo: i)
                tokens.append(.carriageReturn)
                var next = scalars.index(after: i)
                if next < scalars.endIndex, scalars[next].value == 0x0A {
                    tokens.append(.lineFeed)
                    next = scalars.index(after: next)
                }
                i = next
                textStart = i
            case 0x0A, 0x0B, 0x0C:
                flushText(upTo: i)
                tokens.append(.lineFeed)
                i = scalars.index(after: i)
                textStart = i
            case 0x09:
                flushText(upTo: i)
                tokens.append(.tab)
                i = scalars.index(after: i)
                textStart = i
            case 0x08, 0x7F:
                flushText(upTo: i)
                tokens.append(.backspace)
                i = scalars.index(after: i)
                textStart = i
            case 0x00, 0x07, 0x0E, 0x0F:
                flushText(upTo: i)
                i = scalars.index(after: i)
                textStart = i
            default:
                i = scalars.index(after: i)
            }
        }
        flushText(upTo: scalars.endIndex)
        return tokens
    }

    private enum EscapeResult {
        case incomplete
        case consumed(next: String.Index, token: ANSIToken?)
    }

    private func consumeEscape(_ s: String, from esc: String.Index) -> EscapeResult {
        let scalars = s.unicodeScalars
        let afterEsc = scalars.index(after: esc)
        guard afterEsc < scalars.endIndex else { return .incomplete }
        let intro = scalars[afterEsc].value
        if intro == 0x5B {
            return consumeCSI(s, bodyStart: scalars.index(after: afterEsc))
        }
        if intro == 0x5D {
            return consumeTerminated(s, from: scalars.index(after: afterEsc))
        }
        if intro == 0x50 || intro == 0x5E || intro == 0x5F {
            return consumeTerminated(s, from: scalars.index(after: afterEsc))
        }
        if intro == 0x28 || intro == 0x29 || intro == 0x2A || intro == 0x2B {
            let third = scalars.index(after: afterEsc)
            guard third < scalars.endIndex else { return .incomplete }
            return .consumed(next: scalars.index(after: third), token: nil)
        }
        let next = scalars.index(after: afterEsc)
        switch intro {
        case 0x37:
            return .consumed(next: next, token: .saveCursor)
        case 0x38:
            return .consumed(next: next, token: .restoreCursor)
        case 0x44:
            return .consumed(next: next, token: .index)
        case 0x4D:
            return .consumed(next: next, token: .reverseIndex)
        case 0x45:
            return .consumed(next: next, token: .nextLine)
        case 0x63:
            return .consumed(next: next, token: .reset)
        default:
            return .consumed(next: next, token: nil)
        }
    }

    private func consumeCSI(_ s: String, bodyStart: String.Index) -> EscapeResult {
        let scalars = s.unicodeScalars
        var i = bodyStart
        var raw = ""
        while i < scalars.endIndex {
            let value = scalars[i].value
            if value >= 0x40 && value <= 0x7E {
                return .consumed(
                    next: scalars.index(after: i),
                    token: decodeCSI(raw: raw, final: Character(scalars[i]))
                )
            }
            if value >= 0x20 && value <= 0x3F {
                raw.unicodeScalars.append(scalars[i])
                if raw.unicodeScalars.count > 96 {
                    return .consumed(next: scalars.index(after: i), token: nil)
                }
                i = scalars.index(after: i)
                continue
            }
            return .consumed(next: i, token: nil)
        }
        return .incomplete
    }

    private func consumeTerminated(_ s: String, from start: String.Index) -> EscapeResult {
        let scalars = s.unicodeScalars
        var i = start
        var count = 0
        while i < scalars.endIndex {
            let value = scalars[i].value
            if value == 0x07 {
                return .consumed(next: scalars.index(after: i), token: nil)
            }
            if value == 0x1B {
                let next = scalars.index(after: i)
                guard next < scalars.endIndex else { return .incomplete }
                if scalars[next].value == 0x5C {
                    return .consumed(next: scalars.index(after: next), token: nil)
                }
            }
            count += 1
            if count > 8192 {
                return .consumed(next: scalars.index(after: i), token: nil)
            }
            i = scalars.index(after: i)
        }
        return .incomplete
    }

    private func decodeCSI(raw: String, final: Character) -> ANSIToken? {
        let prefix = raw.first
        if prefix == "?" {
            let params = parseParams(raw)
            switch final {
            case "h": return .decset(params)
            case "l": return .decrst(params)
            default: return nil
            }
        }
        if prefix == ">" {
            return nil
        }
        let params = parseParams(raw)
        switch final {
        case "m":
            return .sgr(params)
        case "K":
            return .eraseLine(params.first ?? 0)
        case "J":
            return .eraseDisplay(params.first ?? 0)
        case "X":
            return .eraseChars(max(params.first ?? 1, 1))
        case "H", "f":
            return .cursorPosition(row: oneBased(params, 0), col: oneBased(params, 1))
        case "A":
            return .cursorUp(atLeastOne(params))
        case "B":
            return .cursorDown(atLeastOne(params))
        case "C":
            return .cursorForward(atLeastOne(params))
        case "D":
            return .cursorBack(atLeastOne(params))
        case "G":
            return .cursorColumn(oneBased(params, 0))
        case "d":
            return .cursorRow(oneBased(params, 0))
        case "s":
            return .saveCursor
        case "u":
            return .restoreCursor
        case "r":
            let top = oneBased(params, 0)
            let bottom = params.count > 1 ? max(params[1], 1) : 0
            return .scrollRegion(top: top, bottom: bottom)
        case "S":
            return .scrollUp(atLeastOne(params))
        case "T":
            return .scrollDown(atLeastOne(params))
        case "L":
            return .insertLines(atLeastOne(params))
        case "M":
            return .deleteLines(atLeastOne(params))
        case "@":
            return .insertChars(atLeastOne(params))
        case "P":
            return .deleteChars(atLeastOne(params))
        case "h":
            return .setMode(params)
        case "l":
            return .resetMode(params)
        case "n":
            return .deviceStatus(params.first ?? 0)
        case "c":
            return .deviceAttributes
        default:
            return nil
        }
    }

    private func atLeastOne(_ params: [Int]) -> Int {
        max(params.first ?? 1, 1)
    }

    private func oneBased(_ params: [Int], _ index: Int) -> Int {
        guard index < params.count else { return 1 }
        return max(params[index], 1)
    }

    private func parseParams(_ raw: String) -> [Int] {
        let filtered = raw.filter { $0.isNumber || $0 == ";" || $0 == ":" }
        if filtered.isEmpty { return [] }
        return filtered.split(whereSeparator: { $0 == ";" || $0 == ":" }).map { part in
            if part.isEmpty { return 0 }
            return Int(part) ?? 0
        }
    }
}
