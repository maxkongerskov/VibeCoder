//
//  TerminalCSIGapTests.swift
//  Remaining CSI / style / UTF-8 ingest not covered by TerminalSessionUITests.
//  Emulator only — no live PTY.
//

import XCTest
@testable import VibeCoderApp

final class TerminalCSIGapTests: XCTestCase {

    func testRelativeCursorMovesAndColumnRowAddressing() {
        var emu = TerminalEmulator(columns: 20, rows: 8)
        emu.ingest("abcd")
        XCTAssertEqual(emu.buffer.cursorX, 4)
        emu.ingest("\u{1b}[2D")
        XCTAssertEqual(emu.buffer.cursorX, 2)
        emu.ingest("X")
        XCTAssertEqual(emu.buffer.lineString(0), "abXd")

        emu.ingest("\u{1b}[2;5H")
        XCTAssertEqual(emu.buffer.cursorY, 1)
        XCTAssertEqual(emu.buffer.cursorX, 4)
        emu.ingest("\u{1b}[A")
        XCTAssertEqual(emu.buffer.cursorY, 0)
        emu.ingest("\u{1b}[B")
        XCTAssertEqual(emu.buffer.cursorY, 1)
        emu.ingest("\u{1b}[C")
        XCTAssertEqual(emu.buffer.cursorX, 5)
        emu.ingest("\u{1b}[G")
        XCTAssertEqual(emu.buffer.cursorX, 0)
        emu.ingest("\u{1b}[3d")
        XCTAssertEqual(emu.buffer.cursorY, 2)
    }

    func testSaveAndRestoreCursor() {
        var emu = TerminalEmulator(columns: 20, rows: 6)
        emu.ingest("hi")
        emu.ingest("\u{1b}[s")
        emu.ingest("\u{1b}[4;8H")
        XCTAssertEqual(emu.buffer.cursorY, 3)
        XCTAssertEqual(emu.buffer.cursorX, 7)
        emu.ingest("\u{1b}[u")
        XCTAssertEqual(emu.buffer.cursorY, 0)
        XCTAssertEqual(emu.buffer.cursorX, 2)
    }

    func testTabStopsEveryEightColumns() {
        var emu = TerminalEmulator(columns: 24, rows: 3)
        emu.ingest("A\tB")
        XCTAssertEqual(emu.buffer.cursorX, 9)
        XCTAssertEqual(emu.buffer.cell(x: 0, y: 0)?.character, "A")
        XCTAssertEqual(emu.buffer.cell(x: 8, y: 0)?.character, "B")
    }

    func testEraseCharsClearsWithoutMovingCursor() {
        var emu = TerminalEmulator(columns: 16, rows: 3)
        emu.ingest("HELLO")
        emu.ingest("\u{1b}[1;2H\u{1b}[2X")
        XCTAssertEqual(emu.buffer.lineString(0).prefix(5), "H  LO")
        XCTAssertEqual(emu.buffer.cursorX, 1)
        XCTAssertEqual(emu.buffer.cursorY, 0)
    }

    func testIndexed256ColorAndDimUnderlineInverse() {
        var indexed = TerminalEmulator()
        indexed.ingest("\u{1b}[38;5;196mRED\u{1b}[0m")
        XCTAssertEqual(indexed.buffer.plainText, "RED")
        XCTAssertEqual(indexed.buffer.currentRuns.first?.style.foreground, 196)
        XCTAssertNil(indexed.buffer.currentRuns.first?.style.foregroundRGB)

        var styled = TerminalEmulator()
        styled.ingest("\u{1b}[2;4;7mdim\u{1b}[0m")
        XCTAssertEqual(styled.buffer.currentRuns.count, 1)
        XCTAssertTrue(styled.buffer.currentRuns[0].style.dim)
        XCTAssertTrue(styled.buffer.currentRuns[0].style.underline)
        XCTAssertTrue(styled.buffer.currentRuns[0].style.inverse)
        XCTAssertFalse(styled.buffer.currentRuns[0].style.bold)
    }

    func testInsertAndDeleteCharacters() {
        var ins = TerminalEmulator(columns: 16, rows: 3)
        ins.ingest("ABCD")
        ins.ingest("\u{1b}[1;2H\u{1b}[2@")
        XCTAssertEqual(ins.buffer.lineString(0).prefix(6), "A  BCD")

        var del = TerminalEmulator(columns: 16, rows: 3)
        del.ingest("ABCD")
        del.ingest("\u{1b}[1;2H\u{1b}[2P")
        XCTAssertEqual(del.buffer.lineString(0).prefix(2), "AD")
    }

    func testScrollRegionThenScrollUpMovesTopLine() {
        var emu = TerminalEmulator(columns: 8, rows: 4)
        emu.ingest("\u{1b}[1;3r")
        emu.ingest("\u{1b}[1;1Haaa\r\nbbb\r\nccc")
        emu.ingest("\u{1b}[S")
        XCTAssertTrue(emu.buffer.lineString(0).contains("bbb") || emu.buffer.plainText.contains("bbb"))
        XCTAssertFalse(emu.buffer.lineString(0).hasPrefix("aaa"))
    }

    func testDeviceAttributesAndDSR5Reply() {
        var emu = TerminalEmulator()
        emu.ingest("\u{1b}[c")
        var replies = emu.takeReplies()
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(String(data: replies[0], encoding: .utf8), "\u{1b}[?1;2c")

        emu.ingest("\u{1b}[5n")
        replies = emu.takeReplies()
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(String(data: replies[0], encoding: .utf8), "\u{1b}[0n")
    }

    func testIngestDataSplitsIncompleteUTF8() {
        var emu = TerminalEmulator()
        // U+00E9 LATIN SMALL LETTER E WITH ACUTE = C3 A9
        emu.ingest(Data([0xC3]))
        XCTAssertEqual(emu.buffer.plainText, "")
        emu.ingest(Data([0xA9]))
        XCTAssertEqual(emu.buffer.plainText, "é")
    }

    func testAutoWrapOffAndBracketedPasteMode() {
        var wrap = TerminalEmulator(columns: 4, rows: 3)
        wrap.ingest("\u{1b}[?7l")
        wrap.ingest("ABCDE")
        // DECSET 7 off: extra glyphs overwrite the last column, no wrap to row 1.
        XCTAssertEqual(wrap.buffer.lineString(0), "ABCE")
        XCTAssertEqual(wrap.buffer.lineString(1), "")

        var paste = TerminalEmulator()
        XCTAssertFalse(paste.buffer.bracketedPaste)
        paste.ingest("\u{1b}[?2004h")
        XCTAssertTrue(paste.buffer.bracketedPaste)
        paste.ingest("\u{1b}[?2004l")
        XCTAssertFalse(paste.buffer.bracketedPaste)
    }

    func testNoteAndForceLeaveAlternateScreen() {
        var emu = TerminalEmulator()
        emu.ingest("shell")
        emu.ingest("\u{1b}[?1049h\u{1b}[2J\u{1b}[Halt")
        XCTAssertTrue(emu.buffer.usesAlternateScreen)
        emu.forceLeaveAlternateScreen()
        XCTAssertFalse(emu.buffer.usesAlternateScreen)
        XCTAssertTrue(emu.buffer.plainText.contains("shell"))

        var noted = TerminalEmulator()
        noted.note("hello-note")
        XCTAssertTrue(noted.buffer.plainText.contains("hello-note"))
    }
}
