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
        emu.ingest("pre\u{1b}[2Jmid\u{1b}[?25lpost")
        XCTAssertEqual(emu.buffer.plainText, "premidpost")
        XCTAssertFalse(emu.buffer.plainText.contains("["))
        XCTAssertFalse(emu.buffer.plainText.contains("\u{1b}"))
    }

    func testBackspaceDeletesPreviousCharacter() {
        var bs = TerminalEmulator()
        bs.ingest("abc\u{8}")
        XCTAssertEqual(bs.buffer.plainText, "ab")

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
}
