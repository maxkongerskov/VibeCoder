//
//  TerminalSessionUITests.swift
//  Wave U3 — ANSI / buffer / dock settings. No live PTY.
//

import XCTest
@testable import VibeCoderApp

final class TerminalSessionUITests: XCTestCase {

    func testSGRRedBoldAndReset() {
        var emu = TerminalEmulator()
        emu.ingest("\u{1b}[31mred\u{1b}[0mplain")
        XCTAssertEqual(emu.buffer.currentRuns.map(\.text), ["red", "plain"])
        XCTAssertEqual(emu.buffer.currentRuns[0].style.foreground, 1)
        XCTAssertFalse(emu.buffer.currentRuns[0].style.bold)
        XCTAssertNil(emu.buffer.currentRuns[1].style.foreground)
        XCTAssertFalse(emu.buffer.currentRuns[1].style.bold)

        var bold = TerminalEmulator()
        bold.ingest("\u{1b}[1;31mboldred\u{1b}[0m")
        XCTAssertEqual(bold.buffer.currentRuns.count, 1)
        XCTAssertEqual(bold.buffer.currentRuns[0].text, "boldred")
        XCTAssertEqual(bold.buffer.currentRuns[0].style.foreground, 1)
        XCTAssertTrue(bold.buffer.currentRuns[0].style.bold)
    }

    func testCRLFPairMovesCursorLikeCRThenLF() {
        var emu = TerminalEmulator(columns: 8, rows: 3)
        emu.ingest("AAAA\r\nBB")
        XCTAssertEqual(emu.buffer.lineString(0), "AAAA")
        XCTAssertEqual(emu.buffer.lineString(1), "BB")
        XCTAssertFalse(emu.buffer.lineString(0).contains("\r"))
        XCTAssertFalse(emu.buffer.lineString(0).contains("\n"))
    }

    func testCarriageReturnOverwritesCurrentLine() {
        var emu = TerminalEmulator()
        emu.ingest("hello")
        emu.ingest("\rWORLD")
        XCTAssertEqual(emu.buffer.plainText, "WORLD")

        var partial = TerminalEmulator()
        partial.ingest("hello\rOK")
        XCTAssertEqual(partial.buffer.plainText, "OKllo")
    }

    func testUnknownCSIIsDropped() {
        var emu = TerminalEmulator()
        emu.ingest("pre\u{1b}[99zmid\u{1b}]0;title\u{7}post")
        XCTAssertEqual(emu.buffer.plainText, "premidpost")
        XCTAssertFalse(emu.buffer.plainText.contains("["))
        XCTAssertFalse(emu.buffer.plainText.contains("\u{1b}"))
    }

    func testBackspaceMovesCursorThenOverwrite() {
        var bs = TerminalEmulator()
        bs.ingest("abc\u{8}X")
        XCTAssertEqual(bs.buffer.plainText, "abX")

        var del = TerminalEmulator()
        del.ingest("xy\u{7f}z")
        XCTAssertEqual(del.buffer.plainText, "xz")
    }

    func testVisibilityDefaultIsFalse() {
        XCTAssertFalse(TerminalDockStorage.visibilityDefault)
        XCTAssertEqual(TerminalDockStorage.visibilityKey, "vc.terminalDockVisible")
        XCTAssertEqual(TerminalDockStorage.defaultHeight, 200)
        XCTAssertEqual(TerminalDockStorage.clampHeight(80), 120)
        XCTAssertEqual(TerminalDockStorage.clampHeight(500), 420)
    }

    func testToggleNotificationNameString() {
        XCTAssertEqual(
            Notification.Name.toggleTerminalRequested.rawValue,
            "agentos.toggleTerminal"
        )
    }

    func testCwdPrefersWorktreeThenProjectThenHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        let project = URL(fileURLWithPath: "/tmp/proj")
        let work = URL(fileURLWithPath: "/tmp/proj-agentcore-x")
        XCTAssertEqual(
            TerminalCwd.resolve(worktreeRoot: work, projectRoot: project, fallback: home).path,
            work.path
        )
        XCTAssertEqual(
            TerminalCwd.resolve(worktreeRoot: nil, projectRoot: project, fallback: home).path,
            project.path
        )
        XCTAssertEqual(
            TerminalCwd.resolve(worktreeRoot: nil, projectRoot: nil, fallback: home).path,
            home.path
        )
        XCTAssertEqual(
            TerminalCwd.identity(of: URL(fileURLWithPath: "/tmp/proj/")),
            URL(fileURLWithPath: "/tmp/proj").standardizedFileURL.path
        )
    }

    func testEraseLineAfterCRClearsRemainder() {
        var emu = TerminalEmulator()
        emu.ingest("hello\r\u{1b}[KOK")
        XCTAssertEqual(emu.buffer.plainText, "OK")
    }

    func testIncompleteCSIDoesNotPrintGarbage() {
        var parser = ANSIParser()
        let first = parser.push("hi\u{1b}[")
        XCTAssertEqual(first, [.text("hi")])
        let second = parser.push("31mred")
        XCTAssertEqual(second, [.sgr([31]), .text("red")])
    }

    func testClearScreenKeepsCursorAndErases() {
        var emu = TerminalEmulator()
        emu.ingest("pre\u{1b}[2Jmid")
        XCTAssertEqual(emu.buffer.lineString(0), "   mid")
        XCTAssertFalse(emu.buffer.plainText.contains("pre"))
    }

    func testCursorAddressingDoesNotStackFrames() {
        var emu = TerminalEmulator()
        emu.ingest("\u{1b}[2J\u{1b}[HFrame1")
        emu.ingest("\u{1b}[2J\u{1b}[HFrame2")
        XCTAssertEqual(emu.buffer.lineString(0), "Frame2")
        XCTAssertFalse(emu.buffer.plainText.contains("Frame1"))
    }

    func testAlternateScreenIsolatesPrimaryAndWelcomeLayout() {
        var emu = TerminalEmulator()
        emu.ingest("shell prompt")
        emu.ingest("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?2026h\u{1b}[2J\u{1b}[H")
        emu.ingest("\u{1b}[1;1HGrok Build  1.0.5 [alpha]")
        emu.ingest("\u{1b}[3;3HResume session")
        emu.ingest("\u{1b}[3;40HNew worktree")
        emu.ingest("\u{1b}[?2026l")

        XCTAssertTrue(emu.buffer.usesAlternateScreen)
        XCTAssertEqual(emu.buffer.lineString(0), "Grok Build  1.0.5 [alpha]")
        XCTAssertTrue(emu.buffer.lineString(2).contains("Resume session"))
        XCTAssertTrue(emu.buffer.lineString(2).contains("New worktree"))
        XCTAssertEqual(emu.buffer.cell(x: 2, y: 2)?.character, "R")
        XCTAssertEqual(emu.buffer.cell(x: 39, y: 2)?.character, "N")
        XCTAssertFalse(emu.buffer.plainText.contains("shell prompt"))

        emu.ingest("\u{1b}[?1049l")
        XCTAssertFalse(emu.buffer.usesAlternateScreen)
        XCTAssertEqual(emu.buffer.plainText, "shell prompt")
    }

    func testDeviceStatusReportRepliesWithOneBasedCursor() {
        var emu = TerminalEmulator()
        emu.ingest("\u{1b}[5;12H\u{1b}[6n")
        let replies = emu.takeReplies()
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(String(data: replies[0], encoding: .utf8), "\u{1b}[5;12R")
    }

    func testColonSeparatedTrueColorDoesNotPrintGarbage() {
        var emu = TerminalEmulator()
        emu.ingest("\u{1b}[38:2:255:128:0mORANGE\u{1b}[0m")
        XCTAssertEqual(emu.buffer.plainText, "ORANGE")
        XCTAssertEqual(emu.buffer.currentRuns.first?.style.foregroundRGB?.r, 255)
        XCTAssertEqual(emu.buffer.currentRuns.first?.style.foregroundRGB?.g, 128)
    }

    func testResizePreservesOverlappingCells() {
        var emu = TerminalEmulator(columns: 40, rows: 10)
        emu.ingest("\u{1b}[2;4Hhi")
        emu.resize(columns: 20, rows: 6)
        XCTAssertEqual(emu.buffer.columns, 20)
        XCTAssertEqual(emu.buffer.rows, 6)
        XCTAssertEqual(emu.buffer.lineString(1), "   hi")
    }

    func testPendingWrapThenCUPDoesNotSkipALine() {
        var wrap = TerminalEmulator(columns: 4, rows: 3)
        wrap.ingest("abcdX")
        XCTAssertEqual(wrap.buffer.lineString(0), "abcd")
        XCTAssertEqual(wrap.buffer.lineString(1), "X")

        var cup = TerminalEmulator(columns: 4, rows: 3)
        cup.ingest("abcd\u{1b}[2;1HY")
        XCTAssertEqual(cup.buffer.lineString(0), "abcd")
        XCTAssertEqual(cup.buffer.lineString(1), "Y")
    }

    func testCursorVisibilityDecset25StillWrites() {
        var emu = TerminalEmulator()
        XCTAssertTrue(emu.buffer.cursorVisible)
        emu.ingest("\u{1b}[?25lABC")
        XCTAssertFalse(emu.buffer.cursorVisible)
        XCTAssertEqual(emu.buffer.plainText, "ABC")
        emu.ingest("\u{1b}[?25h")
        XCTAssertTrue(emu.buffer.cursorVisible)
    }

    func testAlternateScreen1049RestoresPrimaryCursor() {
        var emu = TerminalEmulator()
        emu.ingest("hello")
        XCTAssertEqual(emu.buffer.cursorX, 5)
        XCTAssertEqual(emu.buffer.cursorY, 0)
        emu.ingest("\u{1b}[?1049h\u{1b}[10;20H")
        XCTAssertTrue(emu.buffer.usesAlternateScreen)
        XCTAssertEqual(emu.buffer.cursorY, 9)
        XCTAssertEqual(emu.buffer.cursorX, 19)
        emu.ingest("\u{1b}[?1049l")
        XCTAssertFalse(emu.buffer.usesAlternateScreen)
        XCTAssertEqual(emu.buffer.plainText, "hello")
        XCTAssertEqual(emu.buffer.cursorX, 5)
        XCTAssertEqual(emu.buffer.cursorY, 0)
    }

    func testApplicationCursorKeysMode() {
        var emu = TerminalEmulator()
        XCTAssertFalse(emu.buffer.applicationCursorKeys)
        emu.ingest("\u{1b}[?1h")
        XCTAssertTrue(emu.buffer.applicationCursorKeys)
        emu.ingest("\u{1b}[?1l")
        XCTAssertFalse(emu.buffer.applicationCursorKeys)
    }

    func testAttributedStringExposesPlainTextForVoiceOver() {
        var emu = TerminalEmulator()
        emu.ingest("hello")
        let attributed = emu.buffer.attributedString(
            appearance: NSAppearance(named: .darkAqua)!,
            fontSize: TerminalMetrics.fontSize
        )
        XCTAssertTrue(attributed.string.contains("hello"))
        XCTAssertFalse(attributed.string.contains("\u{1b}"))
    }

    func testKeyEncoderSendsApplicationCursorKeys() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 126
        ) else {
            XCTFail("could not synthesize key event")
            return
        }
        XCTAssertEqual(
            TerminalKeyEncoder.data(for: event, applicationCursorKeys: false),
            Data([0x1b, 0x5b, 0x41])
        )
        XCTAssertEqual(
            TerminalKeyEncoder.data(for: event, applicationCursorKeys: true),
            Data([0x1b, 0x4f, 0x41])
        )
    }

    func testScrollbackCapsAt2000() {
        XCTAssertEqual(TerminalBuffer().maxCompletedLines, 2000)

        var emu = TerminalEmulator(columns: 16, rows: 2)
        emu.ingest("KEEP0\r\n")
        for i in 1...2010 {
            emu.ingest(String(format: "L%04d\r\n", i))
        }

        XCTAssertEqual(emu.buffer.scrollback.count, 2000)
        XCTAssertFalse(emu.buffer.plainText.contains("KEEP0"))
        XCTAssertFalse(emu.buffer.plainText.contains("L0009"))
        XCTAssertTrue(emu.buffer.plainText.contains("L0010"))
        XCTAssertTrue(emu.buffer.plainText.contains("L2010"))
    }

    func testResizeDuringAlternateScreen() {
        var emu = TerminalEmulator(columns: 40, rows: 10)
        emu.ingest("shell prompt")
        emu.ingest("\u{1b}[?1049h")
        emu.ingest("\u{1b}[1;1HTOPLEFT")
        emu.ingest("\u{1b}[5;10HMID")
        emu.ingest("\u{1b}[10;38HBR")
        XCTAssertEqual(emu.buffer.cursorY, 9)
        XCTAssertEqual(emu.buffer.cursorX, 39)

        emu.resize(columns: 20, rows: 6)

        XCTAssertTrue(emu.buffer.usesAlternateScreen)
        XCTAssertEqual(emu.buffer.columns, 20)
        XCTAssertEqual(emu.buffer.rows, 6)
        XCTAssertEqual(emu.buffer.cursorX, 19)
        XCTAssertEqual(emu.buffer.cursorY, 5)
        XCTAssertEqual(emu.buffer.lineString(0), "TOPLEFT")
        XCTAssertTrue(emu.buffer.lineString(4).contains("MID"))
        XCTAssertFalse(emu.buffer.lineString(5).contains("BR"))

        emu.resize(columns: 40, rows: 10)
        XCTAssertEqual(emu.buffer.columns, 40)
        XCTAssertEqual(emu.buffer.rows, 10)
        XCTAssertEqual(emu.buffer.lineString(0), "TOPLEFT")
        XCTAssertTrue(emu.buffer.lineString(4).contains("MID"))
        XCTAssertFalse(emu.buffer.plainText.contains("BR"))

        emu.ingest("\u{1b}[?1049l")
        XCTAssertFalse(emu.buffer.usesAlternateScreen)
        XCTAssertEqual(emu.buffer.plainText, "shell prompt")

        var region = TerminalEmulator(columns: 20, rows: 10)
        region.ingest("\u{1b}[?1049h\u{1b}[3;8r")
        region.ingest("\u{1b}[3;1HAAA")
        region.resize(columns: 20, rows: 6)
        region.ingest("\u{1b}[1;1H\u{1b}[L")
        XCTAssertEqual(region.buffer.lineString(2), "AAA")
        region.ingest("\u{1b}[3;1H\u{1b}[L")
        XCTAssertEqual(region.buffer.lineString(2), "")
        XCTAssertEqual(region.buffer.lineString(3), "AAA")
    }

    func testInsertDeleteLines() {
        var insert = TerminalEmulator(columns: 8, rows: 4)
        insert.ingest("AAAA\r\nBBBB\r\nCCCC\r\nDDDD")
        insert.ingest("\u{1b}[2;1H\u{1b}[L")
        XCTAssertEqual(insert.buffer.lineString(0), "AAAA")
        XCTAssertEqual(insert.buffer.lineString(1), "")
        XCTAssertEqual(insert.buffer.lineString(2), "BBBB")
        XCTAssertEqual(insert.buffer.lineString(3), "CCCC")

        var delete = TerminalEmulator(columns: 8, rows: 4)
        delete.ingest("AAAA\r\nBBBB\r\nCCCC\r\nDDDD")
        delete.ingest("\u{1b}[2;1H\u{1b}[M")
        XCTAssertEqual(delete.buffer.lineString(0), "AAAA")
        XCTAssertEqual(delete.buffer.lineString(1), "CCCC")
        XCTAssertEqual(delete.buffer.lineString(2), "DDDD")
        XCTAssertEqual(delete.buffer.lineString(3), "")
    }

    func testInsertDeleteChars() {
        var insert = TerminalEmulator(columns: 16, rows: 2)
        insert.ingest("ABCD")
        insert.ingest("\u{1b}[1;2H\u{1b}[2@")
        XCTAssertEqual(insert.buffer.lineString(0), "A  BCD")

        var delete = TerminalEmulator(columns: 16, rows: 2)
        delete.ingest("ABCD")
        delete.ingest("\u{1b}[1;2H\u{1b}[2P")
        XCTAssertEqual(delete.buffer.lineString(0), "AD")
    }

    func testInsertModeIRM() {
        var emu = TerminalEmulator(columns: 16, rows: 2)
        emu.ingest("ABCD")
        XCTAssertFalse(emu.buffer.insertMode)
        emu.ingest("\u{1b}[4h")
        XCTAssertTrue(emu.buffer.insertMode)
        emu.ingest("\u{1b}[1;2HX")
        XCTAssertEqual(emu.buffer.lineString(0), "AXBCD")
        emu.ingest("\u{1b}[4l")
        XCTAssertFalse(emu.buffer.insertMode)
        emu.ingest("Y")
        XCTAssertEqual(emu.buffer.lineString(0), "AXYCD")
    }

    func testEraseDisplay3ClearsScrollback() {
        var emu = TerminalEmulator(columns: 16, rows: 2)
        emu.ingest("KEEP0\r\n")
        for i in 1...8 {
            emu.ingest(String(format: "L%04d\r\n", i))
        }
        XCTAssertFalse(emu.buffer.scrollback.isEmpty)

        emu.ingest("\u{1b}[3J")
        XCTAssertEqual(emu.buffer.scrollback.count, 0)
        XCTAssertFalse(emu.buffer.plainText.contains("KEEP0"))
        XCTAssertFalse(emu.buffer.plainText.contains("L0008"))
    }

    func testDeviceAttributesReply() {
        var emu = TerminalEmulator()
        emu.ingest("\u{1b}[c")
        let replies = emu.takeReplies()
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(String(data: replies[0], encoding: .utf8), "\u{1b}[?1;2c")
    }

    func testBracketedPasteMode() {
        var emu = TerminalEmulator()
        XCTAssertFalse(emu.buffer.bracketedPaste)
        emu.ingest("\u{1b}[?2004h")
        XCTAssertTrue(emu.buffer.bracketedPaste)
        emu.ingest("\u{1b}[?2004l")
        XCTAssertFalse(emu.buffer.bracketedPaste)
    }

    func testBracketedPasteEncodingWithoutPty() {
        XCTAssertEqual(
            TerminalPasteEncoding.payload(for: "hi", bracketedPaste: false),
            Data("hi".utf8)
        )
        XCTAssertEqual(
            TerminalPasteEncoding.payload(for: "hi", bracketedPaste: true),
            Data("\u{1b}[200~hi\u{1b}[201~".utf8)
        )
        XCTAssertTrue(TerminalPasteEncoding.payload(for: "", bracketedPaste: true).isEmpty)

        var emu = TerminalEmulator()
        emu.ingest("\u{1b}[?2004h")
        XCTAssertEqual(
            TerminalPasteEncoding.payload(for: "x\r\n", bracketedPaste: emu.buffer.bracketedPaste),
            Data("\u{1b}[200~x\r\n\u{1b}[201~".utf8)
        )
    }

    /// End-to-end Grok Build-shaped session on the emulator (no forkpty):
    /// alt screen, ignored 2026, welcome CUP, 2004 paste wrap, DSR, shrink
    /// (xterm overlapping copy), then 1049 restore of the primary prompt.
    func testGrokBuildAltScreenBracketedPasteSmoke() {
        var emu = TerminalEmulator(columns: 80, rows: 24)
        emu.ingest("shell prompt")
        emu.ingest("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?2026h\u{1b}[2J\u{1b}[H")
        emu.ingest("\u{1b}[1;1HGrok Build  1.0.5 [alpha]")
        emu.ingest("\u{1b}[3;3HResume session")
        emu.ingest("\u{1b}[3;40HNew worktree")
        emu.ingest("\u{1b}[?2004h\u{1b}[?2026l")

        XCTAssertTrue(emu.buffer.usesAlternateScreen)
        XCTAssertFalse(emu.buffer.cursorVisible)
        XCTAssertTrue(emu.buffer.bracketedPaste)
        XCTAssertEqual(emu.buffer.lineString(0), "Grok Build  1.0.5 [alpha]")
        XCTAssertTrue(emu.buffer.lineString(2).contains("Resume session"))
        XCTAssertTrue(emu.buffer.lineString(2).contains("New worktree"))
        XCTAssertFalse(emu.buffer.plainText.contains("shell prompt"))

        let clip = "resume last\r\n"
        let payload = TerminalPasteEncoding.payload(
            for: clip,
            bracketedPaste: emu.buffer.bracketedPaste
        )
        XCTAssertEqual(payload, Data("\u{1b}[200~resume last\r\n\u{1b}[201~".utf8))
        XCTAssertFalse(String(data: payload, encoding: .utf8)!.contains("\u{1b}[?1049"))

        emu.ingest("\u{1b}[10;1Hresume last")
        emu.ingest("\u{1b}[6n")
        let replies = emu.takeReplies()
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(String(data: replies[0], encoding: .utf8), "\u{1b}[10;12R")

        emu.resize(columns: 40, rows: 12)
        XCTAssertTrue(emu.buffer.usesAlternateScreen)
        XCTAssertEqual(emu.buffer.columns, 40)
        XCTAssertEqual(emu.buffer.rows, 12)
        XCTAssertEqual(emu.buffer.lineString(0), "Grok Build  1.0.5 [alpha]")
        XCTAssertTrue(emu.buffer.lineString(2).contains("Resume session"))
        XCTAssertTrue(emu.buffer.lineString(9).contains("resume last"))

        emu.resize(columns: 80, rows: 24)
        emu.ingest("\u{1b}[?2004l\u{1b}[?25h\u{1b}[?1049l")
        XCTAssertFalse(emu.buffer.usesAlternateScreen)
        XCTAssertFalse(emu.buffer.bracketedPaste)
        XCTAssertTrue(emu.buffer.cursorVisible)
        XCTAssertEqual(emu.buffer.plainText, "shell prompt")
        XCTAssertEqual(emu.buffer.cursorX, 12)
        XCTAssertEqual(emu.buffer.cursorY, 0)

        let attributed = emu.buffer.attributedString(
            appearance: NSAppearance(named: .darkAqua)!,
            fontSize: TerminalMetrics.fontSize
        )
        XCTAssertTrue(attributed.string.contains("shell prompt"))
        XCTAssertFalse(attributed.string.contains("\u{1b}"))
        XCTAssertFalse(attributed.string.contains("Grok Build"))
    }

    func testC0ScalarsAreNotHiddenInGraphemeClusters() {
        var parser = ANSIParser()
        XCTAssertEqual(
            parser.push("A\r\nB"),
            [.text("A"), .carriageReturn, .lineFeed, .text("B")]
        )

        var scalars = ANSIParser()
        let crlf = String(String.UnicodeScalarView([
            Unicode.Scalar(UInt8(13)),
            Unicode.Scalar(UInt8(10)),
        ]))
        XCTAssertEqual(
            scalars.push("X" + crlf + "Y"),
            [.text("X"), .carriageReturn, .lineFeed, .text("Y")]
        )

        var emu = TerminalEmulator(columns: 8, rows: 3)
        emu.ingest("A\u{0301}\r\nB")
        XCTAssertEqual(emu.buffer.lineString(0), "A\u{0301}")
        XCTAssertEqual(emu.buffer.lineString(1), "B")
        XCTAssertFalse(emu.buffer.lineString(0).contains("\r"))
        XCTAssertFalse(emu.buffer.lineString(0).contains("\n"))
    }
}
