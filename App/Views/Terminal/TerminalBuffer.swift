//
//  TerminalBuffer.swift
//  2D VT/xterm screen + scrollback. Alternate buffer, CUP, ED, SGR.
//

import AppKit
import Foundation
import SwiftUI

struct RGBColor: Equatable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

struct TerminalStyle: Equatable, Sendable {
    var bold = false
    var dim = false
    var underline = false
    var inverse = false
    /// ANSI indexed color 0–255, or `nil` for the default foreground.
    var foreground: UInt8?
    var background: UInt8?
    var foregroundRGB: RGBColor?
    var backgroundRGB: RGBColor?
}

struct TerminalCell: Equatable, Sendable {
    var character: Character
    var style: TerminalStyle

    static let blank = TerminalCell(character: " ", style: TerminalStyle())

    static func erased(style: TerminalStyle) -> TerminalCell {
        var fill = TerminalStyle()
        fill.background = style.background
        fill.backgroundRGB = style.backgroundRGB
        return TerminalCell(character: " ", style: fill)
    }
}

struct TerminalRun: Equatable, Sendable {
    var text: String
    var style: TerminalStyle
}

enum TerminalMetrics {
    static let fontSize: CGFloat = 12
    static let inset = NSSize(width: 8, height: 6)

    static func font(bold: Bool) -> NSFont {
        .monospacedSystemFont(ofSize: fontSize, weight: bold ? .semibold : .regular)
    }

    static var cellSize: CGSize {
        let font = font(bold: false)
        let width = max(("M" as NSString).size(withAttributes: [.font: font]).width, 1)
        let height = max(ceil(font.ascender - font.descender + font.leading), 1)
        return CGSize(width: width, height: height)
    }

    static func grid(for pixelSize: CGSize) -> (cols: Int, rows: Int) {
        let usableW = max(pixelSize.width - inset.width * 2, 1)
        let usableH = max(pixelSize.height - inset.height * 2, 1)
        let cell = cellSize
        return (
            max(20, Int(floor(usableW / cell.width))),
            max(4, Int(floor(usableH / cell.height)))
        )
    }
}

private struct TerminalScreen: Sendable {
    var cols: Int
    var rows: Int
    var cells: [TerminalCell]
    var cursorX = 0
    var cursorY = 0
    var wrapPending = false
    var scrollTop = 0
    var scrollBottom: Int
    var savedX = 0
    var savedY = 0
    var savedStyle = TerminalStyle()

    init(cols: Int, rows: Int) {
        self.cols = max(2, cols)
        self.rows = max(1, rows)
        self.cells = [TerminalCell](repeating: .blank, count: self.cols * self.rows)
        self.scrollBottom = self.rows - 1
    }

    mutating func resetGrid() {
        cells = [TerminalCell](repeating: .blank, count: cols * rows)
        cursorX = 0
        cursorY = 0
        wrapPending = false
        scrollTop = 0
        scrollBottom = rows - 1
    }

    func cell(_ x: Int, _ y: Int) -> TerminalCell {
        cells[y * cols + x]
    }

    mutating func setCell(_ x: Int, _ y: Int, _ cell: TerminalCell) {
        cells[y * cols + x] = cell
    }

    func row(_ y: Int) -> ArraySlice<TerminalCell> {
        cells[y * cols ..< (y + 1) * cols]
    }

    mutating func replaceRow(_ y: Int, with row: [TerminalCell]) {
        let start = y * cols
        for x in 0..<cols {
            cells[start + x] = x < row.count ? row[x] : .blank
        }
    }

    mutating func clampCursor() {
        cursorX = min(max(cursorX, 0), cols - 1)
        cursorY = min(max(cursorY, 0), rows - 1)
    }

    var isFullScrollRegion: Bool {
        scrollTop == 0 && scrollBottom == rows - 1
    }

    /// Caller must resolve `wrapPending` first so evicted scrollback is recorded.
    mutating func put(_ ch: Character, style: TerminalStyle, autoWrap: Bool, insertMode: Bool) {
        if insertMode {
            insertChars(1, style: style)
        }
        let x = min(cursorX, cols - 1)
        let y = min(cursorY, rows - 1)
        setCell(x, y, TerminalCell(character: ch, style: style))
        if x >= cols - 1 {
            wrapPending = autoWrap
        } else {
            cursorX = x + 1
        }
    }

    /// Move down one row, scrolling the region if needed. Returns the evicted top row when scrolled.
    mutating func moveIndex(blank: TerminalCell) -> [TerminalCell]? {
        if cursorY == scrollBottom {
            return scrollUp(blank: blank)
        }
        if cursorY < rows - 1 {
            cursorY += 1
        }
        return nil
    }

    mutating func moveReverseIndex(blank: TerminalCell) {
        if cursorY == scrollTop {
            scrollDown(blank: blank)
        } else if cursorY > 0 {
            cursorY -= 1
        }
    }

    @discardableResult
    mutating func scrollUp(blank: TerminalCell) -> [TerminalCell] {
        let evicted = Array(row(scrollTop))
        if scrollTop < scrollBottom {
            for y in scrollTop..<scrollBottom {
                replaceRow(y, with: Array(row(y + 1)))
            }
        }
        replaceRow(scrollBottom, with: [TerminalCell](repeating: blank, count: cols))
        return evicted
    }

    mutating func scrollDown(blank: TerminalCell) {
        if scrollTop < scrollBottom {
            for y in stride(from: scrollBottom, to: scrollTop, by: -1) {
                replaceRow(y, with: Array(row(y - 1)))
            }
        }
        replaceRow(scrollTop, with: [TerminalCell](repeating: blank, count: cols))
    }

    mutating func insertLines(_ count: Int, style: TerminalStyle) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        let blank = TerminalCell.erased(style: style)
        for _ in 0..<count {
            if cursorY < scrollBottom {
                for rowIndex in stride(from: scrollBottom, to: cursorY, by: -1) {
                    replaceRow(rowIndex, with: Array(row(rowIndex - 1)))
                }
            }
            replaceRow(cursorY, with: [TerminalCell](repeating: blank, count: cols))
        }
    }

    mutating func deleteLines(_ count: Int, style: TerminalStyle) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        let blank = TerminalCell.erased(style: style)
        for _ in 0..<count {
            if cursorY < scrollBottom {
                for rowIndex in cursorY..<scrollBottom {
                    replaceRow(rowIndex, with: Array(row(rowIndex + 1)))
                }
            }
            replaceRow(scrollBottom, with: [TerminalCell](repeating: blank, count: cols))
        }
    }

    mutating func insertChars(_ count: Int, style: TerminalStyle) {
        let y = cursorY
        let start = cursorX
        guard start < cols else { return }
        let blank = TerminalCell.erased(style: style)
        let shift = min(count, cols - start)
        for x in stride(from: cols - 1, through: start + shift, by: -1) {
            setCell(x, y, cell(x - shift, y))
        }
        for x in start..<(start + shift) {
            setCell(x, y, blank)
        }
    }

    mutating func deleteChars(_ count: Int, style: TerminalStyle) {
        let y = cursorY
        let start = cursorX
        guard start < cols else { return }
        let blank = TerminalCell.erased(style: style)
        let shift = min(count, cols - start)
        for x in start..<(cols - shift) {
            setCell(x, y, cell(x + shift, y))
        }
        for x in (cols - shift)..<cols {
            setCell(x, y, blank)
        }
    }

    mutating func eraseDisplay(_ mode: Int, style: TerminalStyle) {
        let blank = TerminalCell.erased(style: style)
        switch mode {
        case 1:
            for y in 0..<cursorY {
                for x in 0..<cols { setCell(x, y, blank) }
            }
            for x in 0...cursorX where x < cols {
                setCell(x, cursorY, blank)
            }
        case 2, 3:
            for i in cells.indices { cells[i] = blank }
        default:
            for x in cursorX..<cols {
                setCell(x, cursorY, blank)
            }
            if cursorY + 1 < rows {
                for y in (cursorY + 1)..<rows {
                    for x in 0..<cols { setCell(x, y, blank) }
                }
            }
        }
    }

    mutating func eraseLine(_ mode: Int, style: TerminalStyle) {
        let blank = TerminalCell.erased(style: style)
        switch mode {
        case 1:
            for x in 0...cursorX where x < cols {
                setCell(x, cursorY, blank)
            }
        case 2:
            for x in 0..<cols {
                setCell(x, cursorY, blank)
            }
        default:
            for x in cursorX..<cols {
                setCell(x, cursorY, blank)
            }
        }
    }

    mutating func eraseChars(_ count: Int, style: TerminalStyle) {
        let blank = TerminalCell.erased(style: style)
        let end = min(cursorX + count, cols)
        for x in cursorX..<end {
            setCell(x, cursorY, blank)
        }
    }

    mutating func resized(columns newCols: Int, rows newRows: Int) -> TerminalScreen {
        if cols == newCols && rows == newRows { return self }
        var next = TerminalScreen(cols: newCols, rows: newRows)
        let copyRows = min(rows, newRows)
        let copyCols = min(cols, newCols)
        for y in 0..<copyRows {
            for x in 0..<copyCols {
                next.setCell(x, y, cell(x, y))
            }
        }
        next.cursorX = min(cursorX, newCols - 1)
        next.cursorY = min(cursorY, newRows - 1)
        next.savedX = min(savedX, newCols - 1)
        next.savedY = min(savedY, newRows - 1)
        next.savedStyle = savedStyle
        next.wrapPending = wrapPending && newCols == cols && next.cursorX == newCols - 1
        next.scrollTop = min(scrollTop, newRows - 1)
        if scrollBottom >= rows - 1 {
            next.scrollBottom = newRows - 1
        } else {
            next.scrollBottom = min(scrollBottom, newRows - 1)
        }
        if next.scrollTop > next.scrollBottom {
            next.scrollTop = 0
            next.scrollBottom = newRows - 1
        }
        return next
    }
}

struct TerminalBuffer: Sendable {
    private var primary: TerminalScreen
    private var alternate: TerminalScreen
    private var useAlternate = false
    private(set) var scrollback: [[TerminalCell]] = []
    var style = TerminalStyle()
    var maxCompletedLines = 2000
    var cursorVisible = true
    var bracketedPaste = false
    var autoWrap = true
    var insertMode = false
    var applicationCursorKeys = false
    var replies: [Data] = []
    private var savedPrimaryX = 0
    private var savedPrimaryY = 0
    private var savedPrimaryStyle = TerminalStyle()

    init(columns: Int = 80, rows: Int = 24) {
        let cols = max(2, columns)
        let rws = max(1, rows)
        primary = TerminalScreen(cols: cols, rows: rws)
        alternate = TerminalScreen(cols: cols, rows: rws)
    }

    var columns: Int { active.cols }
    var rows: Int { active.rows }
    var usesAlternateScreen: Bool { useAlternate }
    var cursorX: Int { active.cursorX }
    var cursorY: Int { active.cursorY }

    var currentLine: [TerminalCell] {
        Array(active.row(active.cursorY))
    }

    var currentRuns: [TerminalRun] {
        Self.runs(from: trimmed(Array(active.row(active.cursorY))))
    }

    var plainText: String {
        displayRows(trimTrailing: true)
            .map { line in
                String(line.map(\.character)).replacingOccurrences(
                    of: "\\s+$",
                    with: "",
                    options: .regularExpression
                )
            }
            .joined(separator: "\n")
    }

    func lineString(_ y: Int) -> String {
        guard y >= 0, y < active.rows else { return "" }
        return String(active.row(y).map(\.character))
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    func cell(x: Int, y: Int) -> TerminalCell? {
        guard y >= 0, y < active.rows, x >= 0, x < active.cols else { return nil }
        return active.cell(x, y)
    }

    mutating func resize(columns newCols: Int, rows newRows: Int) {
        let cols = max(2, newCols)
        let rws = max(1, newRows)
        primary = primary.resized(columns: cols, rows: rws)
        alternate = alternate.resized(columns: cols, rows: rws)
    }

    mutating func apply(_ tokens: [ANSIToken]) {
        for token in tokens {
            apply(token)
        }
    }

    mutating func ingest(_ text: String, parser: inout ANSIParser) {
        apply(parser.push(text))
    }

    mutating func forceLeaveAlternateScreen() {
        if useAlternate {
            useAlternate = false
            cursorVisible = true
        }
    }

    func attributedString(appearance: NSAppearance, fontSize: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let defaultFG = NSColor(Theme.Palette.primary)
        let defaultBG = NSColor(Theme.Palette.subtle)
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let cellH = TerminalMetrics.cellSize.height
        paragraph.minimumLineHeight = cellH
        paragraph.maximumLineHeight = cellH
        paragraph.paragraphSpacing = 0

        let rowsToDraw = displayRows(trimTrailing: !useAlternate)
        let cursorDisplayIndex = cursorVisible
            ? (useAlternate ? cursorY : scrollback.count + cursorY)
            : -1
        for (index, row) in rowsToDraw.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: [
                    .font: font,
                    .foregroundColor: defaultFG,
                    .paragraphStyle: paragraph,
                ]))
            }
            var cells = useAlternate ? Array(row) : trimmed(Array(row))
            if index == cursorDisplayIndex {
                let x = min(max(cursorX, 0), columns - 1)
                if cells.count <= x {
                    cells.append(contentsOf: repeatElement(.blank, count: x - cells.count + 1))
                }
                if x < cells.count {
                    cells[x].style.inverse.toggle()
                }
            }
            let runs = Self.runs(from: cells)
            if runs.isEmpty {
                output.append(NSAttributedString(string: " ", attributes: [
                    .font: font,
                    .foregroundColor: defaultFG,
                    .paragraphStyle: paragraph,
                ]))
                continue
            }
            for run in runs {
                if run.text.isEmpty { continue }
                let (fg, bg) = resolvedColors(
                    run.style,
                    appearance: appearance,
                    defaultFG: defaultFG,
                    defaultBG: defaultBG
                )
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: run.style.bold ? boldFont : font,
                    .foregroundColor: fg,
                    .paragraphStyle: paragraph,
                ]
                if let bg {
                    attrs[.backgroundColor] = bg
                }
                if run.style.underline {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                output.append(NSAttributedString(string: run.text, attributes: attrs))
            }
        }
        return output
    }

    private var active: TerminalScreen {
        useAlternate ? alternate : primary
    }

    private mutating func apply(_ token: ANSIToken) {
        let currentStyle = style
        switch token {
        case .text(let text):
            write(text)
        case .sgr(let params):
            applySGR(params)
        case .eraseLine(let mode):
            mutateActive { $0.eraseLine(mode, style: currentStyle) }
        case .eraseDisplay(let mode):
            mutateActive { $0.eraseDisplay(mode, style: currentStyle) }
            if mode == 3 { scrollback.removeAll() }
        case .eraseChars(let count):
            mutateActive { $0.eraseChars(count, style: currentStyle) }
        case .carriageReturn:
            mutateActive {
                $0.wrapPending = false
                $0.cursorX = 0
            }
        case .lineFeed, .index:
            indexDown()
        case .reverseIndex:
            mutateActive { $0.moveReverseIndex(blank: TerminalCell.erased(style: currentStyle)) }
        case .nextLine:
            mutateActive {
                $0.wrapPending = false
                $0.cursorX = 0
            }
            indexDown()
        case .backspace:
            mutateActive {
                $0.wrapPending = false
                if $0.cursorX > 0 { $0.cursorX -= 1 }
            }
        case .tab:
            mutateActive {
                $0.wrapPending = false
                let next = (($0.cursorX / 8) + 1) * 8
                $0.cursorX = min(next, $0.cols - 1)
            }
        case .cursorPosition(let row, let col):
            mutateActive {
                $0.wrapPending = false
                $0.cursorY = min(max(row - 1, 0), $0.rows - 1)
                $0.cursorX = min(max(col - 1, 0), $0.cols - 1)
            }
        case .cursorUp(let n):
            mutateActive {
                $0.wrapPending = false
                $0.cursorY = max($0.cursorY - n, 0)
            }
        case .cursorDown(let n):
            mutateActive {
                $0.wrapPending = false
                $0.cursorY = min($0.cursorY + n, $0.rows - 1)
            }
        case .cursorForward(let n):
            mutateActive {
                $0.wrapPending = false
                $0.cursorX = min($0.cursorX + n, $0.cols - 1)
            }
        case .cursorBack(let n):
            mutateActive {
                $0.wrapPending = false
                $0.cursorX = max($0.cursorX - n, 0)
            }
        case .cursorColumn(let col):
            mutateActive {
                $0.wrapPending = false
                $0.cursorX = min(max(col - 1, 0), $0.cols - 1)
            }
        case .cursorRow(let row):
            mutateActive {
                $0.wrapPending = false
                $0.cursorY = min(max(row - 1, 0), $0.rows - 1)
            }
        case .saveCursor:
            mutateActive {
                $0.savedX = $0.cursorX
                $0.savedY = $0.cursorY
                $0.savedStyle = currentStyle
            }
        case .restoreCursor:
            var restored = style
            mutateActive {
                $0.wrapPending = false
                $0.cursorX = $0.savedX
                $0.cursorY = $0.savedY
                $0.clampCursor()
                restored = $0.savedStyle
            }
            style = restored
        case .scrollRegion(let top, let bottom):
            mutateActive {
                let t = min(max(top - 1, 0), $0.rows - 1)
                let b = bottom <= 0 ? $0.rows - 1 : min(max(bottom - 1, 0), $0.rows - 1)
                $0.scrollTop = min(t, b)
                $0.scrollBottom = max(t, b)
                $0.cursorX = 0
                $0.cursorY = $0.scrollTop
                $0.wrapPending = false
            }
        case .scrollUp(let n):
            for _ in 0..<n { recordScrollUp() }
        case .scrollDown(let n):
            mutateActive { screen in
                for _ in 0..<n {
                    screen.scrollDown(blank: TerminalCell.erased(style: currentStyle))
                }
            }
        case .insertLines(let n):
            mutateActive { $0.insertLines(n, style: currentStyle) }
        case .deleteLines(let n):
            mutateActive { $0.deleteLines(n, style: currentStyle) }
        case .insertChars(let n):
            mutateActive { $0.insertChars(n, style: currentStyle) }
        case .deleteChars(let n):
            mutateActive { $0.deleteChars(n, style: currentStyle) }
        case .decset(let modes):
            applyDEC(modes, enabled: true)
        case .decrst(let modes):
            applyDEC(modes, enabled: false)
        case .setMode(let modes):
            if modes.contains(4) { insertMode = true }
        case .resetMode(let modes):
            if modes.contains(4) { insertMode = false }
        case .deviceStatus(let n):
            if n == 6 {
                replies.append(Data("\u{1b}[\(active.cursorY + 1);\(active.cursorX + 1)R".utf8))
            } else if n == 5 {
                replies.append(Data("\u{1b}[0n".utf8))
            }
        case .deviceAttributes:
            replies.append(Data("\u{1b}[?1;2c".utf8))
        case .reset:
            resetAll()
        }
    }

    private mutating func write(_ text: String) {
        let paint = style
        let wrap = autoWrap
        let insert = insertMode
        let alt = useAlternate
        for ch in text {
            var evicted: [TerminalCell]?
            var fullRegion = false
            if alt {
                evicted = Self.writeChar(&alternate, ch, style: paint, autoWrap: wrap, insertMode: insert)
            } else {
                fullRegion = primary.isFullScrollRegion
                evicted = Self.writeChar(&primary, ch, style: paint, autoWrap: wrap, insertMode: insert)
            }
            if let evicted, !alt, fullRegion {
                pushScrollback(evicted)
            }
        }
    }

    private static func writeChar(
        _ screen: inout TerminalScreen,
        _ ch: Character,
        style: TerminalStyle,
        autoWrap: Bool,
        insertMode: Bool
    ) -> [TerminalCell]? {
        var evicted: [TerminalCell]?
        if screen.wrapPending {
            screen.wrapPending = false
            screen.cursorX = 0
            evicted = screen.moveIndex(blank: TerminalCell.erased(style: style))
        }
        screen.put(ch, style: style, autoWrap: autoWrap, insertMode: insertMode)
        return evicted
    }

    private mutating func indexDown() {
        let blank = TerminalCell.erased(style: style)
        let alt = useAlternate
        var evicted: [TerminalCell]?
        var fullRegion = false
        if alt {
            alternate.wrapPending = false
            evicted = alternate.moveIndex(blank: blank)
        } else {
            primary.wrapPending = false
            fullRegion = primary.isFullScrollRegion
            evicted = primary.moveIndex(blank: blank)
        }
        if let evicted, !alt, fullRegion {
            pushScrollback(evicted)
        }
    }

    private mutating func recordScrollUp() {
        let blank = TerminalCell.erased(style: style)
        if useAlternate {
            _ = alternate.scrollUp(blank: blank)
        } else {
            let fullRegion = primary.isFullScrollRegion
            let evicted = primary.scrollUp(blank: blank)
            if fullRegion {
                pushScrollback(evicted)
            }
        }
    }

    private mutating func pushScrollback(_ row: [TerminalCell]) {
        scrollback.append(row)
        let overflow = scrollback.count - maxCompletedLines
        if overflow > 0 {
            scrollback.removeFirst(overflow)
        }
    }

    private mutating func mutateActive(_ body: (inout TerminalScreen) -> Void) {
        if useAlternate {
            body(&alternate)
        } else {
            body(&primary)
        }
    }

    private mutating func applyDEC(_ modes: [Int], enabled: Bool) {
        for mode in modes {
            switch mode {
            case 1:
                applicationCursorKeys = enabled
            case 25:
                cursorVisible = enabled
            case 7:
                autoWrap = enabled
            case 2004:
                bracketedPaste = enabled
            case 47, 1047, 1049:
                setAlternateScreen(enabled, mode: mode)
            default:
                break
            }
        }
    }

    private mutating func setAlternateScreen(_ enabled: Bool, mode: Int) {
        if enabled {
            if !useAlternate {
                if mode == 1049 {
                    savedPrimaryX = primary.cursorX
                    savedPrimaryY = primary.cursorY
                    savedPrimaryStyle = style
                }
                useAlternate = true
                if mode == 1049 || mode == 1047 {
                    alternate.resetGrid()
                }
            }
        } else if useAlternate {
            useAlternate = false
            if mode == 1049 {
                primary.cursorX = savedPrimaryX
                primary.cursorY = savedPrimaryY
                primary.wrapPending = false
                primary.clampCursor()
                style = savedPrimaryStyle
            }
        }
    }

    private mutating func resetAll() {
        style = TerminalStyle()
        useAlternate = false
        cursorVisible = true
        bracketedPaste = false
        autoWrap = true
        insertMode = false
        applicationCursorKeys = false
        savedPrimaryX = 0
        savedPrimaryY = 0
        savedPrimaryStyle = TerminalStyle()
        scrollback.removeAll()
        primary = TerminalScreen(cols: primary.cols, rows: primary.rows)
        alternate = TerminalScreen(cols: alternate.cols, rows: alternate.rows)
    }

    private func displayRows(trimTrailing: Bool) -> [[TerminalCell]] {
        var rows: [[TerminalCell]] = []
        if !useAlternate {
            rows.append(contentsOf: scrollback)
        }
        if useAlternate || !trimTrailing {
            for y in 0..<active.rows {
                rows.append(Array(active.row(y)))
            }
            return rows
        }
        var last = -1
        for y in 0..<active.rows {
            if !isBlank(active.row(y)) {
                last = y
            }
        }
        last = max(last, active.cursorY)
        if last >= 0 {
            for y in 0...last {
                rows.append(Array(active.row(y)))
            }
        }
        return rows
    }

    private func isBlank(_ row: ArraySlice<TerminalCell>) -> Bool {
        row.allSatisfy { $0.character == " " && $0.style == TerminalStyle() }
    }

    private func trimmed(_ cells: [TerminalCell]) -> [TerminalCell] {
        var end = cells.count
        while end > 0 {
            let cell = cells[end - 1]
            if cell.character == " ",
               cell.style.background == nil,
               cell.style.backgroundRGB == nil,
               !cell.style.inverse {
                end -= 1
            } else {
                break
            }
        }
        return Array(cells.prefix(end))
    }

    private func resolvedColors(
        _ style: TerminalStyle,
        appearance: NSAppearance,
        defaultFG: NSColor,
        defaultBG: NSColor
    ) -> (NSColor, NSColor?) {
        var fg: NSColor
        if let rgb = style.foregroundRGB {
            fg = NSColor(
                srgbRed: CGFloat(rgb.r) / 255,
                green: CGFloat(rgb.g) / 255,
                blue: CGFloat(rgb.b) / 255,
                alpha: 1
            )
        } else if let index = style.foreground {
            fg = TerminalANSIColor.indexed(index, appearance: appearance)
        } else {
            fg = defaultFG
        }
        if style.dim {
            fg = fg.withAlphaComponent(0.65)
        }
        var bg: NSColor?
        if let rgb = style.backgroundRGB {
            bg = NSColor(
                srgbRed: CGFloat(rgb.r) / 255,
                green: CGFloat(rgb.g) / 255,
                blue: CGFloat(rgb.b) / 255,
                alpha: 1
            )
        } else if let index = style.background {
            bg = TerminalANSIColor.indexed(index, appearance: appearance)
        }
        if style.inverse {
            return (bg ?? defaultBG, fg)
        }
        return (fg, bg)
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
            case 2:
                style.dim = true
            case 4:
                style.underline = true
            case 7:
                style.inverse = true
            case 22:
                style.bold = false
                style.dim = false
            case 24:
                style.underline = false
            case 27:
                style.inverse = false
            case 30...37:
                style.foreground = UInt8(p - 30)
                style.foregroundRGB = nil
            case 39:
                style.foreground = nil
                style.foregroundRGB = nil
            case 40...47:
                style.background = UInt8(p - 40)
                style.backgroundRGB = nil
            case 49:
                style.background = nil
                style.backgroundRGB = nil
            case 90...97:
                style.foreground = UInt8(p - 90 + 8)
                style.foregroundRGB = nil
            case 100...107:
                style.background = UInt8(p - 100 + 8)
                style.backgroundRGB = nil
            case 38:
                i += consumeColor(list, start: i, foreground: true)
            case 48:
                i += consumeColor(list, start: i, foreground: false)
            default:
                break
            }
            i += 1
        }
    }

    /// Returns how many extra params were consumed (not including the 38/48 itself).
    private mutating func consumeColor(_ list: [Int], start: Int, foreground: Bool) -> Int {
        guard start + 1 < list.count else { return 0 }
        let kind = list[start + 1]
        if kind == 5, start + 2 < list.count {
            let value = UInt8(clamping: list[start + 2])
            if foreground {
                style.foreground = value
                style.foregroundRGB = nil
            } else {
                style.background = value
                style.backgroundRGB = nil
            }
            return 2
        }
        if kind == 2, start + 4 < list.count {
            let rgb = RGBColor(
                r: UInt8(clamping: list[start + 2]),
                g: UInt8(clamping: list[start + 3]),
                b: UInt8(clamping: list[start + 4])
            )
            if foreground {
                style.foregroundRGB = rgb
                style.foreground = nil
            } else {
                style.backgroundRGB = rgb
                style.background = nil
            }
            return 4
        }
        return 0
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
    var buffer: TerminalBuffer
    private var utf8Remainder: [UInt8] = []

    init(columns: Int = 80, rows: Int = 24) {
        buffer = TerminalBuffer(columns: columns, rows: rows)
    }

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

    mutating func resize(columns: Int, rows: Int) {
        buffer.resize(columns: columns, rows: rows)
    }

    mutating func takeReplies() -> [Data] {
        let replies = buffer.replies
        buffer.replies.removeAll(keepingCapacity: true)
        return replies
    }

    mutating func forceLeaveAlternateScreen() {
        buffer.forceLeaveAlternateScreen()
    }

    mutating func note(_ text: String) {
        buffer.apply([.text(text), .carriageReturn, .lineFeed])
    }
}

enum TerminalANSIColor {
    static func foreground(_ index: UInt8, appearance: NSAppearance) -> NSColor {
        indexed(index, appearance: appearance)
    }

    static func indexed(_ index: UInt8, appearance: NSAppearance) -> NSColor {
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
        case 7:
            return dark ? NSColor(white: 0.86, alpha: 1) : NSColor(white: 0.14, alpha: 1)
        case 8:
            return dark ? NSColor(white: 0.40, alpha: 1) : NSColor(white: 0.35, alpha: 1)
        case 9:
            return NSColor(srgbRed: 1, green: 0.36, blue: 0.36, alpha: 1)
        case 10:
            return NSColor(srgbRed: 0.40, green: 0.86, blue: 0.50, alpha: 1)
        case 11:
            return NSColor(srgbRed: 0.95, green: 0.80, blue: 0.30, alpha: 1)
        case 12:
            return NSColor(srgbRed: 0.40, green: 0.65, blue: 1.0, alpha: 1)
        case 13:
            return NSColor(srgbRed: 0.78, green: 0.52, blue: 1.0, alpha: 1)
        case 14:
            return NSColor(srgbRed: 0.40, green: 0.85, blue: 0.85, alpha: 1)
        case 15:
            return dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.08, alpha: 1)
        case 16...231:
            let cube = Int(index) - 16
            let r = cube / 36
            let g = (cube % 36) / 6
            let b = cube % 6
            func level(_ v: Int) -> CGFloat {
                v == 0 ? 0 : CGFloat(55 + 40 * v) / 255.0
            }
            return NSColor(srgbRed: level(r), green: level(g), blue: level(b), alpha: 1)
        default:
            let gray = CGFloat(8 + 10 * (Int(index) - 232)) / 255.0
            return NSColor(white: min(max(gray, 0), 1), alpha: 1)
        }
    }
}
