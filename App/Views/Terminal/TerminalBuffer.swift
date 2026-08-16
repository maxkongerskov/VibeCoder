//
//  TerminalBuffer.swift
//  Wave U3 — line buffer + SGR style for the dock NSTextView.
//

import AppKit
import Foundation
import SwiftUI

struct TerminalStyle: Equatable, Sendable {
    var bold = false
    /// ANSI 0–7, or `nil` for the default foreground.
    var foreground: UInt8?
}

struct TerminalCell: Equatable, Sendable {
    var character: Character
    var style: TerminalStyle
}

struct TerminalRun: Equatable, Sendable {
    var text: String
    var style: TerminalStyle
}

struct TerminalBuffer: Sendable {
    var completedLines: [[TerminalCell]] = []
    var currentLine: [TerminalCell] = []
    var cursor = 0
    var style = TerminalStyle()
    var maxCompletedLines = 2000

    var plainText: String {
        (completedLines + [currentLine])
            .map { String($0.map(\.character)) }
            .joined(separator: "\n")
    }

    var currentRuns: [TerminalRun] {
        Self.runs(from: currentLine)
    }

    var runs: [TerminalRun] {
        var all: [TerminalRun] = []
        let lines = completedLines + [currentLine]
        for (index, line) in lines.enumerated() {
            if index > 0 {
                if let last = all.indices.last, all[last].style == TerminalStyle() {
                    all[last].text.append("\n")
                } else {
                    all.append(TerminalRun(text: "\n", style: TerminalStyle()))
                }
            }
            all.append(contentsOf: Self.runs(from: line))
        }
        return all
    }

    mutating func apply(_ tokens: [ANSIToken]) {
        for token in tokens {
            switch token {
            case .text(let text):
                write(text)
            case .sgr(let params):
                applySGR(params)
            case .eraseLine(let mode):
                eraseLine(mode)
            case .carriageReturn:
                cursor = 0
            case .lineFeed:
                completedLines.append(currentLine)
                currentLine = []
                cursor = 0
                trim()
            case .backspace:
                backspace()
            }
        }
    }

    mutating func ingest(_ text: String, parser: inout ANSIParser) {
        apply(parser.push(text))
    }

    func attributedString(appearance: NSAppearance, fontSize: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let defaultFG = NSColor(Theme.Palette.primary)
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        for run in runs {
            if run.text.isEmpty { continue }
            let color: NSColor
            if let fg = run.style.foreground {
                color = TerminalANSIColor.foreground(fg, appearance: appearance)
            } else {
                color = defaultFG
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: run.style.bold ? boldFont : font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            output.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        return output
    }

    private mutating func write(_ text: String) {
        for ch in text {
            if cursor < currentLine.count {
                currentLine[cursor] = TerminalCell(character: ch, style: style)
            } else {
                while currentLine.count < cursor {
                    currentLine.append(TerminalCell(character: " ", style: TerminalStyle()))
                }
                currentLine.append(TerminalCell(character: ch, style: style))
            }
            cursor += 1
        }
    }

    private mutating func backspace() {
        guard cursor > 0 else { return }
        cursor -= 1
        if cursor < currentLine.count {
            currentLine.remove(at: cursor)
        }
    }

    private mutating func eraseLine(_ mode: Int) {
        switch mode {
        case 1:
            let limit = min(cursor, currentLine.count)
            if limit > 0 {
                for i in 0..<limit {
                    currentLine[i] = TerminalCell(character: " ", style: TerminalStyle())
                }
            }
        case 2:
            currentLine = []
            cursor = 0
        default:
            if cursor < currentLine.count {
                currentLine.removeSubrange(cursor...)
            }
        }
    }

    private mutating func applySGR(_ params: [Int]) {
        let list = params.isEmpty ? [0] : params
        var i = 0
        while i < list.count {
            let p = list[i]
            switch p {
            case 0:
                style = TerminalStyle()
            case 1:
                style.bold = true
            case 22:
                style.bold = false
            case 30...37:
                style.foreground = UInt8(p - 30)
            case 39:
                style.foreground = nil
            case 90...97:
                style.foreground = UInt8(p - 90)
            case 38:
                if i + 1 < list.count, list[i + 1] == 5 {
                    i += 2
                } else if i + 1 < list.count, list[i + 1] == 2 {
                    i += 4
                }
            default:
                break
            }
            i += 1
        }
    }

    private mutating func trim() {
        let overflow = completedLines.count - maxCompletedLines
        if overflow > 0 {
            completedLines.removeFirst(overflow)
        }
    }

    static func runs(from cells: [TerminalCell]) -> [TerminalRun] {
        var result: [TerminalRun] = []
        for cell in cells {
            if let last = result.indices.last, result[last].style == cell.style {
                result[last].text.append(cell.character)
            } else {
                result.append(TerminalRun(text: String(cell.character), style: cell.style))
            }
        }
        return result
    }
}

/// Decode complete UTF-8 prefixes; keep a short remainder across PTY reads.
enum TerminalUTF8 {
    static func split(_ bytes: [UInt8]) -> (String, [UInt8]) {
        let end = completePrefixLength(bytes)
        if end <= 0 {
            return ("", bytes)
        }
        let prefix = Array(bytes.prefix(end))
        let rest = Array(bytes.dropFirst(end))
        return (String(decoding: prefix, as: UTF8.self), rest)
    }

    static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        var i = bytes.count
        var walked = 0
        while i > 0 && walked < 4 {
            i -= 1
            walked += 1
            let b = bytes[i]
            if b & 0x80 == 0 {
                return bytes.count
            }
            if b & 0xC0 == 0xC0 {
                let need: Int
                if b & 0xE0 == 0xC0 {
                    need = 2
                } else if b & 0xF0 == 0xE0 {
                    need = 3
                } else if b & 0xF8 == 0xF0 {
                    need = 4
                } else {
                    return bytes.count
                }
                if bytes.count - i < need { return i }
                return bytes.count
            }
        }
        return bytes.count
    }
}

struct TerminalEmulator: Sendable {
    var parser = ANSIParser()
    var buffer = TerminalBuffer()
    private var utf8Remainder: [UInt8] = []

    mutating func ingest(_ data: Data) {
        var bytes = utf8Remainder
        bytes.append(contentsOf: data)
        let (text, rest) = TerminalUTF8.split(bytes)
        utf8Remainder = rest
        if !text.isEmpty {
            buffer.apply(parser.push(text))
        }
    }

    mutating func ingest(_ text: String) {
        buffer.apply(parser.push(text))
    }

    mutating func note(_ text: String) {
        buffer.apply([.text(text), .lineFeed])
    }
}

enum TerminalANSIColor {
    static func foreground(_ index: UInt8, appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        switch index {
        case 0:
            return dark ? NSColor(white: 0.28, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        case 1:
            return NSColor(Theme.Palette.error)
        case 2:
            return NSColor(Theme.Palette.success)
        case 3:
            return NSColor(Theme.Palette.warning)
        case 4:
            return NSColor(Theme.Palette.info)
        case 5:
            return NSColor(Theme.Palette.violet)
        case 6:
            return NSColor(srgbRed: 0.40, green: 0.68, blue: 0.70, alpha: 1)
        default:
            return dark ? NSColor(white: 0.86, alpha: 1) : NSColor(white: 0.14, alpha: 1)
        }
    }
}
